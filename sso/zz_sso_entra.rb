# frozen_string_literal: true

# ICODOS Entra ID SSO — configuration, routes, and enforcement.
# Loaded late (zz_ prefix) so that Devise's SessionsController and
# PasswordsController subclasses exist by the time we patch them.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
#
# Env vars:
#   ENTRA_TENANT_ID       Microsoft tenant GUID
#   ENTRA_CLIENT_ID       App registration client id
#   ENTRA_CLIENT_SECRET   App registration client secret (never log)
#   SSO_ENFORCE           "true" blocks password login. Default: false.
#   SSO_BREAK_GLASS       "true" re-enables password login even when SSO_ENFORCE=true.
#   SSO_ALLOWED_DOMAINS   comma-separated email domains a Microsoft account must have to be
#                         bound or provisioned at its first sign-in. Empty: none can be.

module Sso
  module_function

  def configured?
    ENV['ENTRA_TENANT_ID'].to_s.strip.present? &&
      ENV['ENTRA_CLIENT_ID'].to_s.strip.present? &&
      ENV['ENTRA_CLIENT_SECRET'].to_s.strip.present?
  end

  # Tolerant on purpose. These were compared with == 'true', so "True", a
  # trailing space or a CRLF line ending in .env read as OFF, with nothing in
  # any log to say so. For a switch whose job is to keep people out, failing
  # open on a typo is the wrong way round. The boot line below states the
  # effective result either way.
  def flag?(name)
    ENV[name].to_s.strip.casecmp('true').zero?
  end

  def enforced?
    flag?('SSO_ENFORCE')
  end

  def break_glass?
    flag?('SSO_BREAK_GLASS')
  end

  # Password login stays available when SSO isn't enforced, when break-glass is
  # flipped, or when enforcement is misconfigured (implicit break-glass so that
  # a bad config never locks admins out of their own instance).
  def password_login_allowed?
    return true unless enforced?
    return true if break_glass?
    return true unless configured?

    false
  end

  # Prepended onto User's singleton class. THIS is what makes "password login is
  # blocked" true; the controller filter further down only words the refusal.
  #
  # WHY THE FILTER ALONE WAS NOT ENOUGH
  # Until 25 November 2026 enforcement was a before_action on the sessions
  # controller that rendered 403. It ran last. Before it, ApplicationController
  # had already called current_user (in `around_action :with_locale`, through
  # current_account) and signed_in? (in `maybe_redirect_to_setup`). Both ask
  # Warden to authenticate. On sessions#create Devise has, by then, set
  # `devise.allow_params_authentication`, so Warden ran the password strategy
  # against the posted email and password, and on a match wrote the user into
  # the session and set the 730-day remember cookie. Only afterwards did the
  # filter answer 403, and that 403 carried a working session. The body said
  # "Password login is disabled"; the Set-Cookie header said otherwise.
  # A wrong password on the same path still counted towards Devise's lockout,
  # so 15 anonymous requests locked any known address out of SSO for 23 hours.
  #
  # Devise asks the model, per request, whether a strategy may authenticate from
  # request parameters at all. Answering no here means the password is never
  # even compared while enforcement is on: no session, no remember cookie, no
  # failed-attempt counter, on this route or any other. It follows
  # password_login_allowed? live, so break-glass turns it back on with the
  # restart that flipping the variable already requires.
  #
  # Unaffected, because none of them authenticate from request parameters: the
  # Entra callback (sign_in is called directly), the remember cookie, API keys
  # and /mcp bearer tokens.
  module NoPasswordStrategy
    def params_authenticatable?(strategy)
      return false unless ::Sso.password_login_allowed?

      super
    end
  end

  # Every controller through which a password can be typed, set or reset.
  # InvitationsController was missing until 25 November 2026. It is a sibling of
  # PasswordsController (both inherit Devise's), not a subclass, so patching
  # PasswordsController never covered it: PUT /invitation accepted a reset
  # token, set a password and signed the user in while enforcement was on. Any
  # signed-in user can mint such a token from the user settings.
  ENFORCED_CONTROLLERS = %w[SessionsController PasswordsController InvitationsController].freeze

  # Who a Microsoft sign-in is, and which DocuSeal user that makes it.
  #
  # Until 26 November 2026 the callback joined on the email claim alone:
  # whichever DocuSeal user had that address was signed in, and if none had,
  # an ADMIN was created. Both sides of that join are editable. Any admin here
  # can change any user's email in the settings, and Entra addresses get
  # renamed and, after someone leaves, reissued. So a renamed or reissued
  # address inherited an existing record with its API key, and an admin who
  # swapped two addresses in the settings could sign in as a colleague. Nothing
  # in code checked tenant membership or domain either: the portal setting
  # "Assignment required" was the only gate, and a guest assigned to the app,
  # or the setting switched off, would have become an admin. Finding A4.
  #
  # Now the immutable pair tid/oid is bound to the user record at the first
  # sign-in and matched on afterwards:
  #
  #   - The token must carry tid and oid, tid must be ENTRA_TENANT_ID, and the
  #     account must be a member: a guest's token carries an idp claim naming
  #     its home identity provider. (This holds for a tenant whose domains are
  #     managed. With a federated domain a member's idp may name the federation
  #     server; revisit this rule before federating one.)
  #   - A bound pair signs in to its own record, whatever either email now says.
  #   - An unbound pair needs an address in SSO_ALLOWED_DOMAINS. It then takes
  #     the record with that address if the record is not bound yet, or gets a
  #     new one, and the pair is bound. A record already bound to another pair
  #     is refused: that is a renamed or reissued address.
  #
  # The binding lives in user_configs under KEY, an upstream table, so there is
  # no migration. UserConfigsController accepts only two other keys, so a user
  # cannot write it from the settings page.
  module Identity
    KEY = 'icodos_entra_identity'

    module_function

    def allowed_domains
      ENV['SSO_ALLOWED_DOMAINS'].to_s.split(',').map { |d| d.strip.downcase.delete_prefix('@') }
                                .reject(&:empty?).uniq
    end

    def domain_allowed?(email)
      allowed_domains.include?(email.to_s.split('@').last.to_s.downcase)
    end

    # Returns [identity, nil] for a usable member token, [nil, reason] otherwise.
    def from_claims(claims)
      tid = claims['tid'].to_s.strip.downcase
      oid = claims['oid'].to_s.strip.downcase
      return [nil, 'token carries no tid or oid'] if tid.empty? || oid.empty?
      return [nil, 'token is from another tenant'] unless tid == ENV['ENTRA_TENANT_ID'].to_s.strip.downcase

      idp = claims['idp'].to_s.strip
      if !idp.empty? && ![claims['iss'].to_s, "https://sts.windows.net/#{tid}/"].include?(idp)
        return [nil, 'guest account (authenticated by another identity provider)']
      end

      ["#{tid}/#{oid}", nil]
    end

    def user_for(identity)
      UserConfig.where(key: KEY).includes(:user).to_a
                .find { |c| c.value.is_a?(Hash) && c.value['id'] == identity }&.user
    end

    def identity_of(user)
      value = UserConfig.find_by(user_id: user.id, key: KEY)&.value
      value.is_a?(Hash) ? value['id'] : nil
    end

    def bind!(user, identity)
      UserConfig.create!(user: user, key: KEY, value: { 'id' => identity, 'bound_at' => Time.now.utc.iso8601 })
    end
  end
end

# Prevent client_secret, authorization code, and tokens from ever hitting the
# Rails log even if a future controller change accidentally passes them through.
Rails.application.config.filter_parameters +=
  %i[client_secret code id_token access_token refresh_token code_verifier].reject do |k|
    Rails.application.config.filter_parameters.include?(k)
  end

# /auth/entra routes, registered without touching config/routes.rb.
Rails.application.routes.append do
  get '/auth/entra',          to: 'sso/entra_auth#start',    as: :sso_entra_start
  get '/auth/entra/callback', to: 'sso/entra_auth#callback', as: :sso_entra_callback
end

Rails.application.config.after_initialize do
  if Sso.enforced? && !Sso.configured?
    Rails.logger.warn(
      '[sso] SSO_ENFORCE=true but ENTRA_TENANT_ID/CLIENT_ID/CLIENT_SECRET are not all set. ' \
      'Password login stays enabled as an implicit break-glass. Fix the config or set SSO_ENFORCE=false.'
    )
  end

  %w[SSO_ENFORCE SSO_BREAK_GLASS].each do |name|
    raw = ENV[name].to_s.strip

    next if raw.empty? || %w[true false].include?(raw.downcase)

    Rails.logger.warn("[sso] #{name} is set to #{raw.inspect}, which is neither true nor false. It is read as false.")
  end

  # The effective state, in one line, at every boot. Whether password login is
  # possible should never have to be worked out from three variables.
  begin
    strategy_off = User.singleton_class.ancestors.include?(Sso::NoPasswordStrategy) &&
                   !User.params_authenticatable?(:database)

    domains = Sso::Identity.allowed_domains
    Rails.logger.info(
      "[sso] configured=#{Sso.configured?} enforce=#{Sso.enforced?} break_glass=#{Sso.break_glass?} " \
      "password_login=#{Sso.password_login_allowed? ? 'ALLOWED' : 'blocked'} " \
      "password_strategy=#{strategy_off ? 'off' : 'ON'} " \
      "identity=tid+oid allowed_domains=#{domains.empty? ? 'NONE' : domains.join(',')}"
    )

    if Sso.configured? && domains.empty?
      Rails.logger.warn('[sso] SSO_ALLOWED_DOMAINS is empty: accounts already bound still sign in, ' \
                        'but no new Microsoft account can be bound or provisioned.')
    end

    if !Sso.password_login_allowed? && !strategy_off
      Rails.logger.error('[sso] password login is meant to be blocked but the password strategy is still ON. ' \
                         'The model hook did not attach; a posted password can still create a session.')
    end
  rescue StandardError => e
    Rails.logger.error("[sso] boot diagnostic failed (#{e.class}: #{e.message})")
  end
end

# Runs inside `to_prepare` so it re-applies after every code reload (dev) and
# after eager-load in production.
Rails.application.config.to_prepare do
  # 1. The model: no password authentication while enforcement is on.
  begin
    unless User.singleton_class.ancestors.include?(Sso::NoPasswordStrategy)
      User.singleton_class.prepend(Sso::NoPasswordStrategy)
    end
  rescue NameError => e
    Rails.logger.error("[sso] could not attach the password strategy hook to User (#{e.class}: #{e.message}). " \
                       'Password authentication is NOT blocked at the model.')
  end

  # 2. The controllers: a clear refusal instead of a form that cannot work.
  #
  # prepend_before_action, not before_action. It has to run before anything in
  # ApplicationController touches current_user; see NoPasswordStrategy for what
  # happened when it ran last. With the model hook in place the order no longer
  # decides whether a session is created, but a refusal should still be the
  # first thing these actions do, not the last.
  #
  # `only:` leaves sign-out (destroy) reachable for signed-in users.
  #
  # DocuSeal 3.3.x added a second way into SessionsController#create: an XHR
  # JSON sign-in that skips the CSRF check and answers with JSON. It is the same
  # action; the JSON branch below gives that caller a parseable refusal.
  Sso::ENFORCED_CONTROLLERS.each do |name|
    controller = name.safe_constantize

    if controller.nil?
      # An upstream rename on a version bump. Loud, because a controller that
      # is not patched is a way in that nobody is looking at.
      Rails.logger.error("[sso] #{name} does not exist; SSO enforcement is NOT applied to it. " \
                         'Check config/routes.rb upstream for where password and invitation routes now point.')
      next
    end

    next if controller.instance_variable_get(:@_icodos_sso_patched)

    controller.instance_variable_set(:@_icodos_sso_patched, true)
    controller.class_eval do
      prepend_before_action :__icodos_sso_enforce, only: %i[new create edit update]

      define_method(:__icodos_sso_enforce) do
        return if Sso.password_login_allowed?

        message = 'Password login is disabled. Please sign in with Microsoft.'

        if request.get?
          redirect_to '/auth/entra'
        elsif request.format.json?
          render json: { error: message }, status: :forbidden
        else
          render plain: message, status: :forbidden
        end
      end
      private :__icodos_sso_enforce
    end
  end
end
