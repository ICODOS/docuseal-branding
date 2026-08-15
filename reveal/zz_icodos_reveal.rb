# frozen_string_literal: true

# ICODOS — SSO-based API key reveal: registration and boot diagnostics.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/config/initializers/zz_icodos_reveal.rb.
#
# Sorts after zz_sso_entra.rb, which it depends on: the reveal round trip is a
# purpose-tagged variant of the existing /auth/entra flow and reuses its state,
# nonce and PKCE handling wholesale.
#
# As with the other zz_ initializers, nothing here may reference IcodosReveal or
# the controllers at load time — config/initializers/* runs before Zeitwerk is
# ready, so /app/lib/icodos_reveal.rb is not resolvable yet. Every reference is
# inside to_prepare or after_initialize.
#
# ROLLBACK: unset ICODOS_SSO_REVEAL_ENABLED and `docker compose up -d`. The
# prepend stays attached but does nothing, and the upstream password dialog is
# served unchanged. To remove the code, delete the Reveal block from
# docker-compose.yml.

Rails.application.config.to_prepare do
  begin
    unless RevealAccessTokenController.instance_variable_get(:@_icodos_reveal_patched)
      RevealAccessTokenController.instance_variable_set(:@_icodos_reveal_patched, true)
      RevealAccessTokenController.prepend(IcodosReveal::RevealAccessTokenPatch)
    end
  rescue NameError => e
    # An upstream rename, or a partial rollback. Fail closed and loud: the
    # password dialog keeps working, and SSO reveal is simply unavailable.
    Rails.logger.error("[icodos-reveal] could not attach to RevealAccessTokenController " \
                       "(#{e.class}: #{e.message}). SSO reveal is NOT active; the password dialog is unaffected.")
  end
end

Rails.application.config.after_initialize do
  begin
    if IcodosReveal.enabled?
      Rails.logger.info(
        "[icodos-reveal] enabled. auth_time_max_age=#{IcodosReveal::AUTH_TIME_MAX_AGE}s " \
        "grant_ttl=#{IcodosReveal::GRANT_TTL}s rate_limit=#{IcodosReveal::RATE_LIMIT}/min"
      )

      unless RevealAccessTokenController.ancestors.include?(IcodosReveal::RevealAccessTokenPatch)
        Rails.logger.error('[icodos-reveal] enabled but the controller patch is NOT attached — ' \
                           'the password dialog will be shown to users who have no password')
      end
    else
      Rails.logger.info("[icodos-reveal] disabled (#{IcodosReveal::ENV_FLAG} is not true, " \
                        'SSO is unconfigured, or the cache cannot enforce single use)')
    end
  rescue StandardError => e
    Rails.logger.error("[icodos-reveal] boot diagnostic failed (#{e.class}: #{e.message})")
  end
end
