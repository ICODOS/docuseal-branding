# frozen_string_literal: true

# Browser-facing half of the ICODOS MCP OAuth 2.1 authorization server: the
# authorization endpoint and its consent screen.
#
# User authentication is NOT reimplemented here. If there is no DocuSeal session
# we hand off to the existing Entra SSO overlay with
# `/auth/entra?return_to=<this authorize URL>`. Sso::EntraAuthController then does
# the id_token verification, the preferred_username/email lookup, the
# provision_from_claims! auto-provisioning and the archived-user refusal exactly
# as it does for a normal web sign-in, and redirects back here. That is why MCP
# OAuth cannot auto-provision anyone the web SSO flow would not have
# auto-provisioned: it is the same code path, not a copy of it.
#
# Everything 404s when MCP_OAUTH_ENABLED is not "true".
module Sso
  class OauthController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :maybe_redirect_to_setup
    # ApplicationController signs an anonymous visitor in as a random real user
    # when DEMO=true. DEMO is not set on this instance, but a consent screen must
    # never be reachable that way, so the filter is removed outright.
    skip_before_action :sign_in_for_demo, raise: false
    skip_authorization_check

    layout false

    # Prepended so it runs BEFORE Rails' verify_authenticity_token. Without
    # `prepend: true` a POST to a disabled endpoint answers 422 (CSRF) instead of
    # 404, which would make the documented rollback behaviour — "every OAuth
    # endpoint returns 404" — untrue for this one route.
    before_action :require_oauth_enabled!, prepend: true
    before_action :set_consent_response_headers

    # GET /oauth/authorize
    def authorize
      # Client and redirect_uri are validated first and separately: OAuth 2.1
      # forbids redirecting anywhere until we know the redirect_uri is one this
      # client actually registered. Failures here render a page instead.
      client = McpOauth.parse_client(params[:client_id])
      if client.nil?
        Rails.logger.warn('[mcp-oauth] /oauth/authorize with unknown client_id')
        return fatal('Unknown OAuth client. Remove and re-add the connector in Claude so it registers again.')
      end

      redirect_uri = params[:redirect_uri].to_s
      unless McpOauth.redirect_uri_registered?(client, redirect_uri)
        Rails.logger.warn('[mcp-oauth] /oauth/authorize with unregistered redirect_uri')
        return fatal('The redirect URI in this request is not registered for this OAuth client.')
      end

      state = params[:state].to_s
      if state.length > McpOauth::MAX_STATE_LENGTH || state.match?(/[[:cntrl:]]/)
        return fatal('The state parameter in this request is malformed.')
      end

      # From here on, protocol errors are reported to the client by redirect.
      unless params[:response_type].to_s == 'code'
        return deny(redirect_uri, state, 'unsupported_response_type', 'Only response_type=code is supported.')
      end

      unless params[:code_challenge_method].to_s == 'S256'
        return deny(redirect_uri, state, 'invalid_request', 'PKCE with code_challenge_method=S256 is required.')
      end

      code_challenge = params[:code_challenge].to_s
      unless code_challenge.match?(McpOauth::PKCE_CHALLENGE_RE)
        return deny(redirect_uri, state, 'invalid_request', 'code_challenge is missing or malformed.')
      end

      # RFC 8707. Clients MUST send it; we default it rather than fail, but a
      # value naming any other resource is refused outright.
      resource_value = params[:resource].presence.to_s.presence || McpOauth.resource
      unless resource_value == McpOauth.resource
        return deny(redirect_uri, state, 'invalid_target', "resource must be #{McpOauth.resource}.")
      end

      scopes = McpOauth.normalize_scope(params[:scope])
      unless scopes.include?(McpOauth::SCOPE_MCP)
        return deny(redirect_uri, state, 'invalid_scope', "The #{McpOauth::SCOPE_MCP} scope is required.")
      end

      # The SSO handoff puts this whole URL in the session cookie (4 KB, signed).
      # Bounded registrations make this unreachable in practice; fail cleanly
      # rather than with a CookieOverflow 500 if it ever is reached.
      if request.fullpath.bytesize > McpOauth::MAX_AUTHORIZE_URL_BYTES
        Rails.logger.warn('[mcp-oauth] /oauth/authorize refused: request URL too long for the SSO handoff')
        return fatal('This authorization request is too large to process. Contact your administrator.')
      end

      return redirect_to(sign_in_target) unless current_user

      # Same rule and same wording as the SSO overlay: archived accounts are not
      # silently reactivated.
      return fatal(McpOauth::ARCHIVED_MESSAGE) unless current_user.active_for_authentication?

      if impersonating?
        Rails.logger.warn('[mcp-oauth] /oauth/authorize refused: impersonation session')
        return fatal('Authorization is not available while impersonating another user.')
      end

      unless mcp_permitted?
        return deny(redirect_uri, state, 'access_denied', 'This DocuSeal account may not use MCP.')
      end

      @client         = client
      @redirect_uri   = redirect_uri
      @redirect_host  = uri_host(redirect_uri)
      @loopback       = McpOauth.loopback_host?(@redirect_host)
      @scopes         = scopes
      @resource       = resource_value
      @switch_account = "/auth/entra?prompt=select_account&return_to=#{CGI.escape(request.fullpath)}"

      @authorization_request = McpOauth.issue_authz_request(
        user: current_user, client_id: client.client_id, redirect_uri: redirect_uri,
        code_challenge: code_challenge, resource_value: resource_value,
        scope: scopes.join(' '), state: state
      )

      render :consent
    end

    # POST /oauth/authorize — CSRF-protected by Rails' authenticity token.
    def decide
      begin
        pending, = McpOauth.verify_token!(params[:authorization_request],
                                          expected_use: McpOauth::TOKEN_USE_AUTHZ_REQUEST,
                                          expected_aud: McpOauth.authorization_endpoint)
      rescue McpOauth::Error => e
        Rails.logger.warn("[mcp-oauth] consent submission refused: #{e.message}")
        return fatal('This authorization request expired. Please start again from Claude.')
      end

      client = McpOauth.parse_client(pending['client_id'])
      return fatal('Unknown OAuth client.') if client.nil?

      redirect_uri = pending['redirect_uri'].to_s
      unless McpOauth.redirect_uri_registered?(client, redirect_uri)
        Rails.logger.warn('[mcp-oauth] consent submission carried an unregistered redirect_uri')
        return fatal('The redirect URI in this request is not registered for this OAuth client.')
      end

      state = pending['state'].to_s

      return fatal('Your DocuSeal session ended. Please start again from Claude.') unless current_user
      return fatal(McpOauth::ARCHIVED_MESSAGE) unless current_user.active_for_authentication?

      if impersonating?
        Rails.logger.warn('[mcp-oauth] consent refused: impersonation session')
        return fatal('Authorization is not available while impersonating another user.')
      end

      # The consent screen named a specific DocuSeal account. If the session
      # changed underneath it, do not grant on the strength of the old screen.
      unless ActiveSupport::SecurityUtils.secure_compare(pending['sub'].to_s, current_user.uuid.to_s)
        return fatal('Your sign-in changed while the consent screen was open. Please start again from Claude.')
      end

      unless mcp_permitted?
        return deny(redirect_uri, state, 'access_denied', 'This DocuSeal account may not use MCP.')
      end

      # Single use, whichever way the user decides. Without this the same signed
      # consent token could be POSTed repeatedly for its whole 600s life, minting
      # a fresh code each time — and a Deny would be undone by the back button.
      unless McpOauth.consume_jti!(pending['jti'],
                                   ttl: McpOauth::AUTHZ_REQUEST_TTL + McpOauth::JWT_LEEWAY + 240)
        Rails.logger.warn('[mcp-oauth] consent token reuse refused')
        return fatal('This authorization request has already been answered. Please start again from Claude.')
      end

      unless params[:decision].to_s == 'allow'
        Rails.logger.info("[mcp-oauth] user_id=#{current_user.id} denied consent")
        return deny(redirect_uri, state, 'access_denied', 'The user denied the request.')
      end

      code = McpOauth.issue_code(
        user: current_user,
        client_id: client.client_id,
        redirect_uri: redirect_uri,
        code_challenge: pending['code_challenge'].to_s,
        resource_value: pending['resource'].to_s,
        scope: pending['scope'].to_s
      )

      Rails.logger.info(
        "[mcp-oauth] user_id=#{current_user.id} granted consent to client=#{client.client_id[0, 12]} " \
        "scope=#{pending['scope']}"
      )

      redirect_to append_query(redirect_uri, code: code, state: state.presence, iss: McpOauth.issuer),
                  allow_other_host: true
    end

    private

    def require_oauth_enabled!
      head :not_found unless McpOauth.enabled?
    end

    # OAuth 2.1 §3.1: the authorization endpoint response must not be stored.
    # The consent page body carries a live consent token and the session CSRF
    # token. frame-ancestors is set explicitly rather than relying on Rails'
    # default X-Frame-Options, and it also covers the POST-rendered error card,
    # which ApplicationController's GET-only set_csp filter would skip.
    def set_consent_response_headers
      response.headers['Cache-Control'] = 'no-store'
      response.headers['X-Frame-Options'] = 'DENY'
      response.headers['Content-Security-Policy'] = consent_csp
    end

    # `form-action` MUST list the hosts we are allowed to redirect the
    # authorization response to, not just 'self'.
    #
    # The consent form posts to 'self', but that POST answers with a 302 to the
    # client's redirect_uri. Chrome and WebKit enforce form-action against the
    # redirect chain that follows a form submission, so `form-action 'self'`
    # silently blocks the navigation carrying the authorization code — the server
    # logs a successful grant, the browser never reaches the client, and no token
    # exchange ever happens. There is no server-side trace of the failure.
    #
    # Restricting it to the redirect-host allowlist keeps the directive
    # meaningful: the consent form still cannot be repointed at an arbitrary
    # origin, but the legitimate hand-back works.
    def consent_csp
      targets = McpOauth.allowed_redirect_hosts.map do |host|
        # CSP source expressions need IPv6 literals bracketed.
        bracketed = host.include?(':') ? "[#{host}]" : host

        McpOauth.loopback_host?(host) ? "http://#{bracketed}:*" : "https://#{bracketed}"
      end

      ["default-src 'self'",
       "style-src 'self' 'unsafe-inline'",
       "img-src 'self'",
       "form-action 'self' #{targets.join(' ')}".rstrip,
       "frame-ancestors 'none'",
       "base-uri 'none'",
       "object-src 'none'"].join('; ')
    end

    # Two gates, both required before we will mint a grant:
    #   * CanCanCan's :mcp permission (on the community build every user has it,
    #     but it is the documented hook and may not always be), and
    #   * the account-level MCP toggle that Mcp::McpBaseController#verify_mcp_enabled!
    #     actually enforces at request time. Checking it here stops us handing out
    #     a grant the resource server will refuse.
    def mcp_permitted?
      return false unless current_ability.can?(:manage, :mcp)
      return true if Docuseal.multitenant?

      AccountConfig.exists?(account_id: current_user.account_id,
                            key: AccountConfig::ENABLE_MCP_KEY,
                            value: true)
    end

    # Refuse to mint a grant from inside a Pretender impersonation session. The
    # token would be bound to the impersonated user's uuid and would outlive the
    # impersonation by up to the refresh lifetime.
    #
    # Reads the session key that both Pretender and ApplicationController#impersonate_user
    # write, rather than calling `true_user`. That helper goes through Warden and
    # raises if it is missing, and a raise here would take down the consent screen
    # for everyone — a much worse outcome than the narrow issue this guards.
    def impersonating?
      session[:impersonated_user_id].present?
    end

    # Hand off to the Entra SSO overlay, coming back to this exact authorize URL.
    # `safe_return_to` in Sso::EntraAuthController accepts it: it starts with a
    # single "/" and carries no control characters.
    def sign_in_target
      return "/auth/entra?return_to=#{CGI.escape(request.fullpath)}" if ::Sso.configured?

      store_location_for(:user, request.fullpath) if respond_to?(:store_location_for)

      new_user_session_path
    end

    def deny(redirect_uri, state, error, description)
      Rails.logger.warn("[mcp-oauth] authorization refused: #{error}")

      redirect_to append_query(redirect_uri, error: error, error_description: description,
                                             state: state.presence, iss: McpOauth.issuer),
                  allow_other_host: true
    end

    # Rendered only for failures we must not report by redirect (unknown client,
    # unregistered redirect_uri, expired consent) — reporting those by redirect
    # would turn this endpoint into an open redirector.
    def fatal(message)
      @fatal_message = message

      render :consent, status: :bad_request
    end

    # Safe because `uri` is always a redirect_uri already matched against the
    # client's signed registration.
    def append_query(uri, **extra)
      parsed = URI.parse(uri)
      pairs  = parsed.query.present? ? URI.decode_www_form(parsed.query) : []

      extra.each { |key, value| pairs << [key.to_s, value.to_s] unless value.nil? }

      parsed.query = URI.encode_www_form(pairs)
      parsed.to_s
    end

    def uri_host(uri)
      URI.parse(uri).host.to_s.downcase
    rescue URI::InvalidURIError
      ''
    end
  end
end
