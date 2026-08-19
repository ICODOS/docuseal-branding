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

    def create
      policy = build_policy

      if policy.nil?
        @account_config.delete if @account_config.persisted?

        return redirect_back(fallback_location: settings_notifications_path,
                             notice: 'Reminders are off for new documents.')
      end

      @account_config.value = policy
      @account_config.save!

      redirect_back fallback_location: settings_notifications_path,
                    notice: I18n.t('changes_have_been_saved')
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
    # ever resolves a preset. Anything more specific is set per document through
    # the MCP tool, where a per-document deadline can actually be supplied.
    def build_policy
      preset = params.dig(:icodos_reminders, :preset).to_s

      # The radio shown when a custom schedule is already in place. Selecting it
      # is a no-op rather than an error.
      raise Unchanged if preset == 'custom'

      IcodosReminders.preset(preset)
    end

  end
end
