# frozen_string_literal: true

# Microsoft Entra ID (Azure AD) OIDC sign-in for ICODOS staff.
# Mounted read-only from the docuseal-branding overlay; see sso/README section.
#
# Flow: authorization code + PKCE, id_token verified against Entra JWKS.
# User mapping: the token's tid/oid, bound to the DocuSeal user at the first
# sign-in (see Sso::Identity in zz_sso_entra.rb). A first sign-in matches an
# unbound user by email or provisions an admin, only for a member account with
# an address in SSO_ALLOWED_DOMAINS. Break-glass via env flag.

module Sso
  class EntraAuthController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :maybe_redirect_to_setup
    skip_authorization_check

    SESSION_STATE_KEY    = :sso_entra_state
    SESSION_NONCE_KEY    = :sso_entra_nonce
    SESSION_VERIFIER_KEY = :sso_entra_code_verifier
    SESSION_RETURN_TO_KEY = :sso_entra_return_to

    # Marks a round trip as an API-key re-authentication rather than a sign-in.
    # Carried in the session, not the URL, so the registered redirect URI in
    # Entra does not change and no app-registration edit is needed.
    SESSION_REVEAL_KEY = :icodos_reveal_intent

    # Where the grant is handed back to the reveal dialog.
    SESSION_REVEAL_GRANT_KEY = :icodos_reveal_grant_jti

    def start
      unless ::Sso.configured?
        Rails.logger.warn('[sso] /auth/entra hit but SSO not configured')
        return redirect_to new_user_session_path,
                           alert: 'Microsoft sign-in is not configured on this server.'
      end

      reveal = reveal_requested?

      # A reveal intent left over from an abandoned attempt would otherwise turn
      # the NEXT ordinary sign-in within its lifetime into a reveal, and nobody
      # would be signed in.
      session.delete(SESSION_REVEAL_KEY) unless reveal

      if reveal
        # Everything here fails closed and sends the user back to the settings
        # page still signed in — this is a re-authentication, never a sign-in.
        return redirect_to(new_user_session_path, alert: 'Please sign in first.') if current_user.nil?

        unless IcodosReveal.enabled?
          return redirect_to(settings_api_index_path,
                             alert: 'Re-authentication to reveal the API key is not enabled on this server.')
        end

        if IcodosReveal.rate_limited?(current_user.id)
          Rails.logger.warn("[icodos-reveal] rate limited user_id=#{current_user.id}")

          return redirect_to(settings_api_index_path, alert: 'Too many attempts. Please wait a minute and try again.')
        end
      end

      state         = SecureRandom.urlsafe_base64(32)
      nonce         = SecureRandom.urlsafe_base64(32)
      code_verifier = SecureRandom.urlsafe_base64(64)
      code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)

      session[SESSION_STATE_KEY]    = state
      session[SESSION_NONCE_KEY]    = nonce
      session[SESSION_VERIFIER_KEY] = code_verifier
      safe = safe_return_to(params[:return_to])
      session[SESSION_RETURN_TO_KEY] = safe if safe

      session[SESSION_REVEAL_KEY] = IcodosReveal.build_intent(current_user.id) if reveal

      auth_uri = OidcClient.new.authorization_uri(
        state: state,
        nonce: nonce,
        code_challenge: code_challenge,
        redirect_uri: callback_url,
        scope: 'openid profile email',
        # prompt=login asks Microsoft to re-authenticate; max_age=0 obliges it
        # to, and is what makes it return auth_time. The claim is verified in
        # the callback — the request alone proves nothing.
        prompt: reveal ? 'login' : sanitized_prompt(params[:prompt]),
        max_age: reveal ? 0 : nil
      )

      redirect_to auth_uri, allow_other_host: true
    end

    def callback
      # Clear the one-shot flow keys unconditionally, before any early return.
      expected_state = session.delete(SESSION_STATE_KEY).to_s
      code_verifier  = session.delete(SESSION_VERIFIER_KEY).to_s
      expected_nonce = session.delete(SESSION_NONCE_KEY).to_s
      return_to      = session.delete(SESSION_RETURN_TO_KEY)
      reveal_intent  = session.delete(SESSION_REVEAL_KEY)

      # Makes every early return below land the user back on the API settings
      # page rather than the sign-in page. During a reveal they are already
      # signed in and stay that way, so "please sign in" would be nonsense.
      @icodos_reveal_flow = reveal_intent.present?

      if params[:error].present?
        Rails.logger.warn("[sso] IdP error: #{params[:error].to_s.gsub(/[[:cntrl:]]/, '')[0, 60]}")
        return fail_login('Microsoft sign-in was cancelled or refused.')
      end

      given_state = params[:state].to_s
      given_code  = params[:code].to_s

      if expected_state.blank? ||
         !ActiveSupport::SecurityUtils.secure_compare(expected_state, given_state)
        Rails.logger.warn('[sso] callback state mismatch')
        return fail_login('Sign-in session expired or invalid. Please try again.')
      end

      if given_code.blank? || code_verifier.blank? || expected_nonce.blank?
        Rails.logger.warn('[sso] callback missing code / verifier / nonce')
        return fail_login('Sign-in session expired or invalid. Please try again.')
      end

      client = OidcClient.new

      begin
        token_resp = client.exchange_code!(code: given_code, code_verifier: code_verifier, redirect_uri: callback_url)
        id_token   = token_resp['id_token'].to_s
        raise OidcClient::Error, 'no id_token in token response' if id_token.blank?

        claims = client.verify_id_token!(id_token, expected_nonce: expected_nonce)
      rescue OidcClient::Error => e
        Rails.logger.warn("[sso] token verification failed (#{e.class})")
        return fail_login('Microsoft sign-in failed. Please try again or contact your administrator.')
      end

      email = (claims['preferred_username'].presence || claims['email'].presence).to_s.strip.downcase
      if email.blank? || !email.include?('@')
        Rails.logger.warn('[sso] token contained no usable email claim')
        return fail_login('Microsoft sign-in did not return an email address.')
      end

      # Tenant, member, and the immutable identity, before anything else uses
      # the token. See Sso::Identity for why the email alone is not enough.
      identity, refusal = ::Sso::Identity.from_claims(claims)
      if identity.nil?
        Rails.logger.warn("[sso] refused: #{refusal}")
        return fail_login('This Microsoft account cannot sign in here. Contact your administrator.')
      end

      # API-key re-authentication branches out here, BEFORE the sign-in logic
      # below. Critically before reset_session — this flow must leave the
      # existing session intact, not replace it.
      return complete_reveal!(reveal_intent, claims, identity) if reveal_intent.present?

      user = ::Sso::Identity.user_for(identity)

      if user.nil?
        user, message = bind_first_sign_in(identity, email, claims)
        return fail_login(message) if user.nil?
      elsif user.email.to_s.strip.downcase != email
        # Bound records follow the Microsoft account, not the address. Worth a
        # line, because it means one side renamed and the other did not.
        Rails.logger.info("[sso] user_id=#{user.id} signed in by its bound Entra account; " \
                          'the DocuSeal email differs from the Microsoft one')
      end

      unless user.active_for_authentication?
        # Archived users don't get silently unarchived — that requires an admin.
        Rails.logger.warn("[sso] user id=#{user.id} not active_for_authentication (archived?)")
        return fail_login('Your account has been archived. Contact your administrator to restore access.')
      end

      reset_session
      sign_in(user, event: :authentication)
      Rails.logger.info("[sso] user_id=#{user.id} email=#{user.email} signed in via Entra")

      redirect_to(return_to.presence || root_path, notice: 'Signed in via Microsoft.')
    end

    private

    # IcodosReveal lives in its own mount block in docker-compose.yml, and the
    # compose file says that deleting the block removes the feature. A bare
    # IcodosReveal::PURPOSE in `start` contradicted that: with the block gone it
    # raised NameError on EVERY /auth/entra, and under SSO_ENFORCE that is a
    # lockout for everyone until break-glass. No module means no reveal.
    def reveal_requested?
      params[:purpose].to_s == IcodosReveal::PURPOSE
    rescue NameError
      false
    end

    # The first sign-in of a Microsoft account that is not bound to any user.
    # Returns [user, nil] once bound, or [nil, message for the person].
    def bind_first_sign_in(identity, email, claims)
      unless ::Sso::Identity.domain_allowed?(email)
        Rails.logger.warn("[sso] refused: first sign-in with a domain outside SSO_ALLOWED_DOMAINS (#{email.split('@').last})")
        return [nil, 'This Microsoft account cannot sign in here. Contact your administrator.']
      end

      user = User.where('LOWER(email) = ?', email).first

      if user && ::Sso::Identity.identity_of(user)
        # The address is on a record that belongs to a different Microsoft
        # account: renamed, reissued after someone left, or edited in the
        # settings. Signing in would hand over that record and its API key.
        Rails.logger.warn("[sso] refused: user_id=#{user.id} has this email but is bound to a different " \
                          'Entra account')
        return [nil, 'This address belongs to a different Microsoft account here. Contact your administrator.']
      end

      user ||= provision_from_claims!(email, claims)
      return [nil, 'Unable to create your DocuSeal account. Contact your administrator.'] if user.nil?

      ::Sso::Identity.bind!(user, identity)
      Rails.logger.info("[sso] user_id=#{user.id} bound to its Entra account at first sign-in")
      [user, nil]
    rescue ActiveRecord::RecordNotUnique
      # A concurrent first sign-in bound this user a moment ago. Only the same
      # Microsoft account may continue.
      bound = ::Sso::Identity.user_for(identity)
      return [bound, nil] if bound && bound.id == user&.id

      Rails.logger.warn("[sso] refused: user_id=#{user&.id} was bound concurrently to a different Entra account")
      [nil, 'Sign-in could not be completed. Please try again.']
    end

    def fail_login(message)
      return redirect_to(settings_api_index_path, alert: message) if @icodos_reveal_flow

      redirect_to new_user_session_path, alert: message
    end

    # Completes an API-key re-authentication. Every path fails closed and
    # leaves the user signed in exactly as they were.
    #
    # The order of checks is deliberate: session first (cheapest, and a stale
    # intent is the common case), then freshness, then identity. The identity
    # check is the one that matters — without it, anyone able to reach a signed-in
    # session could authenticate as themselves at Microsoft and unlock the key
    # belonging to whoever left the browser open.
    def complete_reveal!(intent, claims, identity)
      user = current_user

      if user.nil?
        Rails.logger.warn('[icodos-reveal] callback with no signed-in session')

        return redirect_to(new_user_session_path, alert: 'Your session expired. Sign in and try again.')
      end

      unless IcodosReveal.intent_valid?(intent, user.id)
        Rails.logger.warn("[icodos-reveal] stale or mismatched intent for user_id=#{user.id}")

        return fail_login('That request expired. Please try again.')
      end

      unless IcodosReveal.fresh_auth?(claims['auth_time'])
        Rails.logger.warn("[icodos-reveal] auth_time missing or stale for user_id=#{user.id}")

        return fail_login('Microsoft did not confirm a fresh sign-in. Please try again.')
      end

      # Compared on the bound Entra identity, not the email. The email is
      # editable in the settings, so comparing it let an admin point their own
      # address at a colleague's record and be shown the colleague's key
      # (finding A5). A user who has not signed in since the binding existed
      # has none yet; that is a refusal, never a binding: binding here would be
      # exactly the email trust this replaces.
      bound = ::Sso::Identity.identity_of(user)
      if bound.nil?
        Rails.logger.warn("[icodos-reveal] user_id=#{user.id} has no Entra binding yet; refusing")

        return fail_login('Sign out, sign in with Microsoft once, then try again.')
      end

      unless ActiveSupport::SecurityUtils.secure_compare(identity, bound)
        # Deliberately does not name the account that did authenticate.
        Rails.logger.warn("[icodos-reveal] identity mismatch: session user_id=#{user.id} re-authenticated " \
                          'as a different Microsoft account; refusing')

        return fail_login('That is a different Microsoft account. Re-authenticate as the account this ' \
                          'DocuSeal user belongs to.')
      end

      session[SESSION_REVEAL_GRANT_KEY] = IcodosReveal.mint_grant!(user.id)

      Rails.logger.info("[icodos-reveal] fresh re-authentication accepted for user_id=#{user.id}")

      redirect_to settings_api_index_path,
                  notice: 'Identity confirmed. Select the API key field to reveal it — valid for two minutes.'
    rescue IcodosReveal::Error => e
      Rails.logger.error("[icodos-reveal] could not issue grant: #{e.message}")

      fail_login('Could not complete the check. Please try again.')
    end

    def callback_url
      url_for(action: :callback, only_path: false)
    end

    # Auto-provision a DocuSeal user for an Entra-authenticated caller that
    # doesn't yet have one. The Entra Enterprise Application "Assignment
    # required = Yes" gate is the effective ACL — reaching this point means
    # the tenant admin has explicitly permitted this user to sign in.
    #
    # Password is random (user never sees it); they can set their own via
    # the standard "Forgot password?" flow if password login is ever needed.
    def provision_from_claims!(email, claims)
      account = Account.active.first
      if account.nil?
        Rails.logger.error('[sso] auto-provision aborted: no active Account exists')
        return nil
      end

      first_name, last_name = extract_name_from_claims(claims, email)

      user = account.users.new(
        email: email.downcase,
        first_name: first_name,
        last_name: last_name,
        role: User::ADMIN_ROLE,
        password: SecureRandom.hex(16)
      )

      if user.save
        Rails.logger.info("[sso] auto-provisioned user id=#{user.id} email=#{user.email}")
        user
      else
        Rails.logger.error("[sso] auto-provision failed: #{user.errors.full_messages.join('; ')}")
        nil
      end
    rescue ActiveRecord::RecordNotUnique
      # A concurrent sign-in already created the user; return that winner.
      Rails.logger.info("[sso] provision race resolved for email=#{email}")
      User.where('LOWER(email) = ?', email).first
    end

    def extract_name_from_claims(claims, email)
      given  = claims['given_name'].to_s.strip.presence
      family = claims['family_name'].to_s.strip.presence
      return [given, family] if given || family

      full = claims['name'].to_s.strip
      if full.present?
        parts = full.split(/\s+/, 2)
        return [parts[0], parts[1]]
      end

      [email.split('@').first.presence, nil]
    end

    # OIDC `prompt` handling.
    # Default: `select_account` — Microsoft always shows the account picker
    # so a user can pick which Microsoft account to sign in with, even if
    # they already have an active session in the browser. The tradeoff is
    # one extra click per sign-in; the benefit is that account switching
    # never gets silently short-circuited by a stale browser session.
    # Explicit override via ?prompt= is honored against a small whitelist.
    # `prompt=none` (silent auth that errors on any required interaction)
    # is deliberately not accepted.
    DEFAULT_PROMPT   = 'select_account'
    ALLOWED_PROMPTS  = %w[login select_account consent].freeze

    def sanitized_prompt(raw)
      value = raw.to_s
      return value if ALLOWED_PROMPTS.include?(value)

      DEFAULT_PROMPT
    end

    def safe_return_to(param)
      s = param.to_s
      return nil if s.empty?
      return nil if s.match?(/[\r\n\t\\]/)
      return nil unless s.start_with?('/')
      return nil if s.start_with?('//')

      s
    end

    class OidcClient
      class Error < StandardError; end

      DISCOVERY_CACHE_KEY = 'sso:entra:discovery'
      JWKS_CACHE_KEY      = 'sso:entra:jwks'
      DISCOVERY_TTL       = 24.hours
      JWKS_TTL            = 1.hour
      HTTP_TIMEOUT        = 10
      HTTP_OPEN_TIMEOUT   = 5
      JWT_LEEWAY          = 60

      def initialize
        @tenant_id     = ENV.fetch('ENTRA_TENANT_ID')
        @client_id     = ENV.fetch('ENTRA_CLIENT_ID')
        @client_secret = ENV.fetch('ENTRA_CLIENT_SECRET')
      end

      def authorization_uri(state:, nonce:, code_challenge:, redirect_uri:, scope:, prompt: nil, max_age: nil)
        query = {
          client_id: @client_id,
          response_type: 'code',
          redirect_uri: redirect_uri,
          response_mode: 'query',
          scope: scope,
          state: state,
          nonce: nonce,
          code_challenge: code_challenge,
          code_challenge_method: 'S256'
        }
        query[:prompt] = prompt if prompt.present?
        # max_age=0 is meaningful and must survive a `.present?` test, hence the
        # explicit nil check. It obliges the IdP to re-authenticate and is what
        # makes it return the auth_time claim we verify.
        query[:max_age] = max_age unless max_age.nil?
        "#{discovery.fetch('authorization_endpoint')}?#{query.to_query}"
      end

      def exchange_code!(code:, code_verifier:, redirect_uri:)
        resp = http.post(discovery.fetch('token_endpoint')) do |req|
          req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
          req.headers['Accept']       = 'application/json'
          req.body = URI.encode_www_form(
            grant_type: 'authorization_code',
            client_id: @client_id,
            client_secret: @client_secret,
            code: code,
            redirect_uri: redirect_uri,
            code_verifier: code_verifier
          )
        end

        unless resp.status == 200
          # Extract only the OAuth "error" code from the JSON body — never the raw body.
          code = (JSON.parse(resp.body) rescue {})['error'].to_s[0, 60]
          raise Error, "token endpoint returned #{resp.status} #{code}"
        end

        JSON.parse(resp.body)
      rescue Faraday::Error => e
        raise Error, "token endpoint transport failure: #{e.class}"
      end

      def verify_id_token!(id_token, expected_nonce:)
        expected_iss = discovery.fetch('issuer')

        jwks_loader = lambda do |options|
          Rails.cache.delete(JWKS_CACHE_KEY) if options[:kid_not_found]
          { keys: jwks_keys }
        end

        payload, _header = JWT.decode(
          id_token,
          nil,
          true,
          algorithms: ['RS256'],
          iss: expected_iss,
          aud: @client_id,
          verify_iss: true,
          verify_aud: true,
          verify_expiration: true,
          verify_not_before: true,
          verify_iat: true,
          leeway: JWT_LEEWAY,
          jwks: jwks_loader
        )

        unless ActiveSupport::SecurityUtils.secure_compare(payload['nonce'].to_s, expected_nonce.to_s)
          raise Error, 'id_token nonce mismatch'
        end

        payload
      rescue JWT::DecodeError => e
        raise Error, "id_token invalid: #{e.class}"
      end

      private

      def discovery
        Rails.cache.fetch(DISCOVERY_CACHE_KEY, expires_in: DISCOVERY_TTL) do
          url = "https://login.microsoftonline.com/#{@tenant_id}/v2.0/.well-known/openid-configuration"
          resp = http.get(url)
          raise Error, "discovery returned #{resp.status}" unless resp.status == 200

          JSON.parse(resp.body)
        end
      rescue Faraday::Error => e
        raise Error, "discovery transport failure: #{e.class}"
      end

      def jwks_keys
        Rails.cache.fetch(JWKS_CACHE_KEY, expires_in: JWKS_TTL) do
          resp = http.get(discovery.fetch('jwks_uri'))
          raise Error, "jwks returned #{resp.status}" unless resp.status == 200

          JSON.parse(resp.body).fetch('keys', [])
        end
      rescue Faraday::Error => e
        raise Error, "jwks transport failure: #{e.class}"
      end

      def http
        @http ||= Faraday.new do |f|
          f.options.timeout = HTTP_TIMEOUT
          f.options.open_timeout = HTTP_OPEN_TIMEOUT
        end
      end
    end
  end
end
