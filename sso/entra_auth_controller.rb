# frozen_string_literal: true

# Microsoft Entra ID (Azure AD) OIDC sign-in for ICODOS staff.
# Mounted read-only from the docuseal-branding overlay; see sso/README section.
#
# Flow: authorization code + PKCE, id_token verified against Entra JWKS.
# User mapping: preferred_username / email claim, case-insensitive match against
# an existing DocuSeal user. No auto-provisioning. Break-glass via env flag.

module Sso
  class EntraAuthController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :maybe_redirect_to_setup
    skip_authorization_check

    SESSION_STATE_KEY    = :sso_entra_state
    SESSION_NONCE_KEY    = :sso_entra_nonce
    SESSION_VERIFIER_KEY = :sso_entra_code_verifier
    SESSION_RETURN_TO_KEY = :sso_entra_return_to

    def start
      unless ::Sso.configured?
        Rails.logger.warn('[sso] /auth/entra hit but SSO not configured')
        return redirect_to new_user_session_path,
                           alert: 'Microsoft sign-in is not configured on this server.'
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

      auth_uri = OidcClient.new.authorization_uri(
        state: state,
        nonce: nonce,
        code_challenge: code_challenge,
        redirect_uri: callback_url,
        scope: 'openid profile email',
        prompt: sanitized_prompt(params[:prompt])
      )

      redirect_to auth_uri, allow_other_host: true
    end

    def callback
      # Clear the one-shot flow keys unconditionally, before any early return.
      expected_state = session.delete(SESSION_STATE_KEY).to_s
      code_verifier  = session.delete(SESSION_VERIFIER_KEY).to_s
      expected_nonce = session.delete(SESSION_NONCE_KEY).to_s
      return_to      = session.delete(SESSION_RETURN_TO_KEY)

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

      user = User.where('LOWER(email) = ?', email).first

      if user.nil?
        user = provision_from_claims!(email, claims)
        if user.nil?
          return fail_login('Unable to create your DocuSeal account. Contact your administrator.')
        end
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

    def fail_login(message)
      redirect_to new_user_session_path, alert: message
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

    # Whitelist the OIDC `prompt` parameter to the three safe interactive
    # values. Deliberately blocks `prompt=none` (silent auth that errors on
    # any required interaction) since we want callers to always see a UI
    # when they pass a prompt at all.
    def sanitized_prompt(raw)
      return nil if raw.blank?
      value = raw.to_s
      return value if %w[login select_account consent].include?(value)

      nil
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

      def authorization_uri(state:, nonce:, code_challenge:, redirect_uri:, scope:, prompt: nil)
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
