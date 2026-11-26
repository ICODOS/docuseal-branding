# frozen_string_literal: true

# ICODOS — reminder engine boot diagnostics.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/config/initializers/zz_icodos_reminders.rb.
#
# Nothing here may reference IcodosReminders at load time: config/initializers
# runs before Zeitwerk is ready, so /app/lib/icodos_reminders.rb is not
# resolvable yet. Every reference sits inside after_initialize.
#
# ROLLBACK: ICODOS_REMINDERS_ENABLED=false and `docker compose up -d`.

# config/routes.rb is not patched — appended, the same pattern the SSO, Phase D
# and Phase E overlays use. The form partial posts here rather than to
# NotificationsSettingsController, which permits only two AccountConfig keys and
# would have silently dropped ours.
Rails.application.routes.append do
  post '/settings/reminders', to: 'icodos/reminders#create', as: :icodos_reminders
end

Rails.application.config.after_initialize do
  begin
    if IcodosReminders.enabled?
      mode = IcodosReminders.dry_run? ? 'DRY RUN (nothing is sent)' : 'LIVE'

      Rails.logger.info(
        "[icodos-reminders] enabled, #{mode}. presets=#{IcodosReminders::PRESETS.keys.join(',')} " \
        "caps: 1/day, min #{IcodosReminders::MIN_GAP_SECONDS}s apart, " \
        "#{IcodosReminders::MAX_TOTAL_PER_SUBMITTER} per signer, #{IcodosReminders::MAX_PER_SWEEP} per sweep"
      )

      # The heartbeat is not read here. This runs before the embedded Redis
      # has started, so it always found none and reported "no sweep has run
      # yet" on every boot. A stopped or failing sweep is reported by the
      # host's health job (no successful sweep for 30 minutes) and by the
      # settings page and smoke check (heartbeat older than two hours).
    else
      Rails.logger.info('[icodos-reminders] disabled (ICODOS_REMINDERS_ENABLED is not true)')
    end
  rescue StandardError => e
    Rails.logger.error("[icodos-reminders] boot diagnostic failed (#{e.class}: #{e.message})")
  end
end
