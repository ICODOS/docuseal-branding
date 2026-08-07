# frozen_string_literal: true

# Machine-facing half of the ICODOS MCP OAuth 2.1 authorization server:
# discovery metadata, JWKS, RFC 7591 dynamic client registration, and the token
# endpoint. Mounted read-only from the docuseal-branding overlay.
#
# Deliberately ActionController::API — no session, no CSRF, no CanCanCan. None
# of these actions authenticate a DocuSeal user; the user is authenticated once,
# in the browser, by Sso::OauthController (which delegates to the existing Entra
# SSO overlay), and that decision is carried forward inside the signed
# authorization code.
#
# All endpoints 404 when MCP_OAUTH_ENABLED is not "true", which is the
# one-line rollback for Phase D.
module Sso
  class OauthApiController < ActionController::API
    before_action :require_oauth_enabled!

    REGISTRATIONS_PER_HOUR = 20
    TOKENS_PER_MINUTE      = 60

    def protected_resource_metadata
      expires_in 5.minutes, public: true
      render json: McpOauth.protected_resource_metadata
    end

    def authorization_server_metadata
      expires_in 5.minutes, public: true
      render json: McpOauth.authorization_server_metadata
    end

    def jwks
      expires_in 5.minutes, public: true
      render json: { keys: McpOauth.public_jwks }
    end

    # RFC 7591 §3.1 — open registration, deliberately. Claude registers a fresh
    # public client on each new connection and there is no way to pre-share a
    # credential with it. What keeps this safe is that we mint no state and that
    # redirect_uris are constrained to MCP_OAUTH_ALLOWED_REDIRECT_HOSTS, so a
    # stranger cannot register a client that redirects authorization codes to a
    # host they control.
    def register
      return registration_error('too_many_requests', 'Too many registration attempts.', :too_many_requests) if
        rate_limited?("reg:#{request.remote_ip}", limit: REGISTRATIONS_PER_HOUR, period: 1.hour)

      body = parse_json_body
      return registration_error('invalid_client_metadata', 'Request body must be a JSON object.') if body.nil?

      redirect_uris = Array(body['redirect_uris']).map(&:to_s)

      if redirect_uris.empty? || redirect_uris.size > McpOauth::MAX_REDIRECT_URIS
        return registration_error('invalid_redirect_uri',
                                  "redirect_uris must contain 1..#{McpOauth::MAX_REDIRECT_URIS} entries.")
      end

      rejected = redirect_uris.reject { |uri| McpOauth.valid_redirect_uri?(uri) }
      if rejected.any?
        Rails.logger.warn("[mcp-oauth] registration rejected: #{rejected.size} disallowed redirect_uri(s)")
        return registration_error(
          'invalid_redirect_uri',
          'Every redirect_uri must be an absolute https URI with no fragment, no userinfo, and no ' \
          'code/state/iss query parameter, on one of these hosts: ' \
          "#{McpOauth.allowed_redirect_hosts.join(', ')}."
        )
      end

      # Defaulting to both rather than to RFC 7591's ["authorization_code"]:
      # Anthropic's docs say clients SHOULD advertise refresh_token, but we have
      # not verified that Claude actually does, and getting this wrong would cost
      # users a re-consent every hour. A client that explicitly narrows its
      # grant_types is still held to that (see grant_refresh_token).
      grant_types = Array(body['grant_types']).map(&:to_s).presence || McpOauth::GRANT_TYPES
      unless (grant_types - McpOauth::GRANT_TYPES).empty?
        return registration_error('invalid_client_metadata',
                                  "grant_types must be a subset of #{McpOauth::GRANT_TYPES.inspect}.")
      end

      response_types = Array(body['response_types']).map(&:to_s).presence || %w[code]
      unless (response_types - %w[code]).empty?
        return registration_error('invalid_client_metadata', 'response_types must be ["code"].')
      end

      auth_method = body['token_endpoint_auth_method'].to_s.presence || 'none'
      unless auth_method == 'none'
        return registration_error(
          'invalid_client_metadata',
          'This authorization server issues public clients only; token_endpoint_auth_method must be "none".'
        )
      end

      client_name = McpOauth.sanitize_client_name(body['client_name'])
      issued_at   = Time.now.to_i
      client_id   = McpOauth.register_client(redirect_uris: redirect_uris, name: client_name,
                                             grant_types: grant_types, now: issued_at)

      # The client_id embeds its redirect_uris, and /oauth/authorize round-trips
      # the whole authorize URL through Rails' 4 KB cookie session. Refuse a
      # registration that would produce an unusable client rather than handing
      # one out and failing with a 500 later.
      if client_id.length > McpOauth::MAX_CLIENT_ID_LENGTH
        return registration_error('invalid_redirect_uri',
                                  'The supplied redirect_uris are collectively too long.')
      end

      Rails.logger.info(
        "[mcp-oauth] registered client=#{client_id[0, 12]} name=#{client_name[0, 60].inspect} " \
        "uris=#{redirect_uris.join(' ')}"
      )

      response.headers['Cache-Control'] = 'no-store'
      render json: {
        client_id: client_id,
        client_id_issued_at: issued_at,
        client_name: client_name,
        redirect_uris: redirect_uris,
        grant_types: grant_types,
        response_types: response_types,
        token_endpoint_auth_method: 'none',
        scope: McpOauth::SUPPORTED_SCOPES.join(' ')
      }, status: :created
    end

    # RFC 6749 §3.2 / OAuth 2.1 §4.1.3. Content-Type is
    # application/x-www-form-urlencoded, which Rails parses into params.
    def token
      response.headers['Cache-Control'] = 'no-store'

      return oauth_error('too_many_requests', 'Too many token requests.', :too_many_requests) if
        rate_limited?("tok:#{request.remote_ip}", limit: TOKENS_PER_MINUTE, period: 1.minute)

      case params[:grant_type].to_s
      when 'authorization_code' then grant_authorization_code
      when 'refresh_token'      then grant_refresh_token
      else
        oauth_error('unsupported_grant_type',
                    'Supported grant_type values are authorization_code and refresh_token.')
      end
    end

    private

    def grant_authorization_code
      client = authenticated_client
      return unless client

      code = params[:code].to_s
      return oauth_error('invalid_request', 'code is required.') if code.empty?

      begin
        payload, = McpOauth.verify_token!(code, expected_use: McpOauth::TOKEN_USE_CODE,
                                               expected_aud: McpOauth.token_endpoint)
      rescue McpOauth::Error => e
        Rails.logger.warn("[mcp-oauth] authorization code refused: #{e.message}")
        return oauth_error('invalid_grant', 'The authorization code is invalid or expired.')
      end

      # Single use. Consume before anything else can go wrong so a replay of a
      # code whose exchange failed downstream still cannot be retried.
      unless McpOauth.consume_jti!(payload['jti'], ttl: McpOauth::CODE_TTL + 240)
        Rails.logger.warn('[mcp-oauth] authorization code replay refused')
        return oauth_error('invalid_grant', 'The authorization code has already been used.')
      end

      unless secure_equal?(payload['client_id'], client.client_id)
        Rails.logger.warn('[mcp-oauth] authorization code presented by a different client')
        return oauth_error('invalid_grant', 'The authorization code was not issued to this client.')
      end

      # OAuth 2.1 §4.1.3: redirect_uri is required here because it was present
      # in the authorization request, and must match exactly.
      unless params[:redirect_uri].to_s == payload['redirect_uri'].to_s
        Rails.logger.warn('[mcp-oauth] redirect_uri mismatch at token endpoint')
        return oauth_error('invalid_grant', 'redirect_uri does not match the authorization request.')
      end

      verifier = params[:code_verifier].to_s
      unless verifier.match?(McpOauth::PKCE_VERIFIER_RE)
        return oauth_error('invalid_grant', 'code_verifier is missing or malformed.')
      end

      computed = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      unless secure_equal?(computed, payload['code_challenge'])
        Rails.logger.warn('[mcp-oauth] PKCE verification failed')
        return oauth_error('invalid_grant', 'code_verifier does not match code_challenge.')
      end

      if params[:resource].present? && params[:resource].to_s != payload['resource'].to_s
        return oauth_error('invalid_target', 'resource does not match the authorization request.')
      end

      user = active_user(payload['sub'])
      return oauth_error('invalid_grant', 'The DocuSeal account is no longer active.') unless user

      scope = payload['scope'].to_s
      now   = Time.now.to_i

      Rails.logger.info("[mcp-oauth] issued tokens user_id=#{user.id} client=#{client.client_id[0, 12]}")

      render json: token_response(
        user: user, client: client, scope: scope, now: now,
        refresh_expires_at: (now + McpOauth.refresh_token_ttl if scope.split.include?(McpOauth::SCOPE_OFFLINE))
      )
    end

    def grant_refresh_token
      client = authenticated_client
      return unless client

      presented = params[:refresh_token].to_s
      return oauth_error('invalid_request', 'refresh_token is required.') if presented.empty?

      begin
        payload, = McpOauth.verify_token!(presented, expected_use: McpOauth::TOKEN_USE_REFRESH,
                                                    expected_aud: McpOauth.token_endpoint)
      rescue McpOauth::Error => e
        Rails.logger.warn("[mcp-oauth] refresh token refused: #{e.message}")
        return oauth_error('invalid_grant', 'The refresh token is invalid or expired.')
      end

      unless secure_equal?(payload['client_id'], client.client_id)
        return oauth_error('invalid_grant', 'The refresh token was not issued to this client.')
      end

      # The grant_types echoed back at registration are authoritative, not decorative.
      unless client.grant_types.include?('refresh_token')
        return oauth_error('unauthorized_client', 'This client is not registered for the refresh_token grant.')
      end

      # Rotation with best-effort reuse detection: the presented token is burned
      # here, so a replay after rotation fails. See McpOauth.consume_jti! for the
      # limits of "best-effort" on this deployment.
      # The burn entry must outlive the token's *verifiable* life, which runs to
      # exp + JWT_LEEWAY. Using bare `remaining` let a token rotated in its last
      # 60 seconds become replayable once the entry expired before it did.
      remaining = payload['exp'].to_i - Time.now.to_i + McpOauth::JWT_LEEWAY + 240
      unless McpOauth.consume_jti!(payload['jti'], ttl: remaining)
        Rails.logger.warn('[mcp-oauth] refresh token reuse refused')
        return oauth_error('invalid_grant', 'The refresh token has already been used.')
      end

      user = active_user(payload['sub'])
      return oauth_error('invalid_grant', 'The DocuSeal account is no longer active.') unless user

      granted = payload['scope'].to_s.split(/\s+/)

      if params[:scope].present?
        requested = params[:scope].to_s.split(/\s+/)
        return oauth_error('invalid_scope', 'Requested scope exceeds the original grant.') unless
          (requested - granted).empty?

        granted = requested
      end

      if params[:resource].present? && params[:resource].to_s != McpOauth.resource
        return oauth_error('invalid_target', "resource must be #{McpOauth.resource}.")
      end

      Rails.logger.info("[mcp-oauth] refreshed tokens user_id=#{user.id} client=#{client.client_id[0, 12]}")

      render json: token_response(
        user: user, client: client, scope: granted.join(' '), now: Time.now.to_i,
        # Absolute grant lifetime is preserved across rotations, never extended.
        refresh_expires_at: (payload['exp'].to_i if granted.include?(McpOauth::SCOPE_OFFLINE))
      )
    end

    def token_response(user:, client:, scope:, now:, refresh_expires_at:)
      body = {
        access_token: McpOauth.issue_access_token(user: user, client_id: client.client_id, scope: scope, now: now),
        token_type: 'Bearer',
        expires_in: McpOauth.access_token_ttl,
        scope: scope
      }

      if refresh_expires_at && refresh_expires_at > now
        body[:refresh_token] = McpOauth.issue_refresh_token(
          user: user, client_id: client.client_id, scope: scope, expires_at: refresh_expires_at, now: now
        )
      end

      body
    end

    # Public clients only: the client authenticates by presenting a client_id
    # whose MAC we can verify, and the grant is bound to it by PKCE plus the
    # client_id recorded inside the code. Renders the error and returns nil on
    # failure, so callers must `return unless client`.
    def authenticated_client
      client = McpOauth.parse_client(params[:client_id])
      return client if client

      Rails.logger.warn('[mcp-oauth] token request with unknown client_id')
      response.headers['WWW-Authenticate'] = 'Bearer realm="mcp"'
      oauth_error('invalid_client', 'Unknown client_id.', :unauthorized)
      nil
    end

    def active_user(uuid)
      user = User.find_by(uuid: uuid.to_s)
      return nil if user.nil?

      unless user.active_for_authentication?
        Rails.logger.warn("[mcp-oauth] user_id=#{user.id} not active_for_authentication at token endpoint")
        return nil
      end

      user
    end

    def secure_equal?(left, right)
      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end

    def parse_json_body
      raw = request.raw_post.to_s
      return nil if raw.bytesize > McpOauth::MAX_REGISTRATION_BYTES

      parsed = JSON.parse(raw.presence || '{}')
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # Fixed-window counter. Uses Rails.cache.increment, which is atomic and
    # auto-creates the key on this store — a read-then-write version would let
    # concurrent Puma threads all read the same value and advance the counter by
    # one, making the effective ceiling limit x thread-count.
    #
    # Keyed on request.remote_ip. Behind this deployment's Caddy that is the real
    # client address and is NOT spoofable: Caddy appends the peer address to
    # X-Forwarded-For, and ActionDispatch takes the rightmost non-private entry,
    # so an attacker-supplied prefix is ignored. (Verified against the running
    # stack.) That would stop being true if Caddy were replaced with a proxy that
    # overwrites the header instead of appending to it.
    def rate_limited?(bucket, limit:, period:)
      window = Time.now.to_i / period.to_i
      key    = "mcp_oauth:rl:#{bucket}:#{window}"
      count  = Rails.cache.increment(key, 1, expires_in: period.to_i * 2)

      # A store that cannot increment would return nil; treat that as not limited
      # rather than locking the endpoint out entirely.
      return false if count.nil?

      count > limit
    end

    def oauth_error(code, description, status = :bad_request)
      response.headers['Cache-Control'] = 'no-store'
      render json: { error: code, error_description: description }, status: status
    end

    def registration_error(code, description, status = :bad_request)
      response.headers['Cache-Control'] = 'no-store'
      render json: { error: code, error_description: description }, status: status
    end

    def require_oauth_enabled!
      head :not_found unless McpOauth.enabled?
    end
  end
end
