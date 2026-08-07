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

module Sso
  module_function

  def configured?
    ENV['ENTRA_TENANT_ID'].to_s.strip.present? &&
      ENV['ENTRA_CLIENT_ID'].to_s.strip.present? &&
      ENV['ENTRA_CLIENT_SECRET'].to_s.strip.present?
  end

  def enforced?
    ENV['SSO_ENFORCE'] == 'true'
  end

  def break_glass?
    ENV['SSO_BREAK_GLASS'] == 'true'
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
end

# Wrap SessionsController and PasswordsController with an SSO enforcement filter.
# Runs inside `to_prepare` so it re-applies after every code reload (dev) and
# after eager-load in production. Uses `only:` to leave sign-out (destroy)
# reachable for signed-in users.
Rails.application.config.to_prepare do
  [SessionsController, PasswordsController].each do |controller|
    next if controller.instance_variable_get(:@_icodos_sso_patched)

    controller.instance_variable_set(:@_icodos_sso_patched, true)
    controller.class_eval do
      before_action :__icodos_sso_enforce, only: %i[new create edit update]

      define_method(:__icodos_sso_enforce) do
        return if Sso.password_login_allowed?

        if request.get?
          redirect_to '/auth/entra'
        else
          render plain: 'Password login is disabled. Please sign in with Microsoft.',
                 status: :forbidden
        end
      end
      private :__icodos_sso_enforce
    end
  end
end
