# frozen_string_literal: true

# ICODOS — saves the account-level default reminder policy.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/icodos/reminders_controller.rb.
#
# WHY THIS EXISTS RATHER THAN REUSING NotificationsSettingsController
# That controller hard-restricts which AccountConfig keys may be written:
#
#   attrs[:key] = nil unless attrs[:key].in?([BCC_EMAILS, SUBMITTER_REMINDERS])
#
# Posting our key through it would have silently failed — key nil, nothing
# saved, no error, a form that looks like it works. Since the form partial is
# ours, its action can be ours too, which avoids patching an upstream private
# method and avoids storing our policy in DocuSeal's Pro-shaped key.

module Icodos
  class RemindersController < ApplicationController
    Unchanged = Class.new(StandardError)

    before_action :load_config
    authorize_resource :account_config

    # Stored with the time it takes effect and the defaults before it
    # (IcodosReminders.default_record), so the change applies to documents
    # sent from now on, as the notice says. Until November 2026 the bare
    # policy was stored and every pending signer moved to the new schedule at
    # once; "off" deleted the record, which did the same in the other
    # direction.
    def create
      policy = build_policy
      previous = @account_config.persisted? ? @account_config.value : nil

      @account_config.value = IcodosReminders.default_record(previous, policy)
      @account_config.save!

      notice = policy.nil? ? 'Reminders are off for documents sent from now on.' :
                             'Saved. This applies to documents sent from now on.'
      notice += ' Documents already sent keep the schedule they were sent with.'

      redirect_back fallback_location: settings_notifications_path, notice: notice
    rescue Unchanged
      redirect_back fallback_location: settings_notifications_path
    rescue IcodosReminders::InvalidPolicy => e
      # Shown to the person who typed it, in their own words, rather than a 500.
      redirect_back fallback_location: settings_notifications_path, alert: e.message
    end

    private

    def load_config
      @account_config = AccountConfig.find_or_initialize_by(
        account: current_account,
        key: IcodosReminders::ACCOUNT_DEFAULT_KEY
      )
    end

    # The settings page offers four named choices and nothing else, so this only
    # ever resolves a preset. Nothing more specific is offered anywhere: the
    # sweep reads a per-document schedule or deadline from a submission's
    # preferences, but no tool or page writes one; only the Rails console can.
    def build_policy
      preset = params.dig(:icodos_reminders, :preset).to_s

      # The radio shown when a custom schedule is already in place. Selecting it
      # is a no-op rather than an error.
      raise Unchanged if preset == 'custom'

      IcodosReminders.preset(preset)
    end

  end
end
