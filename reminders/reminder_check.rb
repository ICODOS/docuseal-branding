# frozen_string_literal: true

# ICODOS — reminder engine smoke check.
#
# Mounted read-only at /app/lib/icodos_reminder_check.rb.
# Zeitwerk: lib/icodos_reminder_check.rb -> IcodosReminderCheck.
#
#   docker compose exec app bin/rails runner \
#     'require "icodos_reminder_check"; IcodosReminderCheck.call'
#
# The failure this exists to catch is the one that already happened once on this
# instance in a different form: a reminder system that looks configured and
# sends nothing. A stale heartbeat is therefore a FAILURE, not a note.

module IcodosReminderCheck
  module_function

  def call
    @failed = false

    puts "\nICODOS reminder engine — check\n\n"

    step('enabled') do
      raise "#{IcodosReminders::ENABLED_FLAG} is not true" unless IcodosReminders.enabled?

      IcodosReminders.dry_run? ? 'DRY RUN — nothing is sent' : 'LIVE — reminders are being sent'
    end

    step('scheduler maths load') do
      p = IcodosReminders.preset('standard')
      at = IcodosReminders.next_at(policy: p, sent_at: 3.days.ago, now: Time.current)

      raise 'the standard preset produced no next reminder' if at.nil?

      "standard -> next #{at.iso8601}"
    end

    step('redis lock and heartbeat work') do
      first = IcodosReminderSweep.acquire_lock
      second = IcodosReminderSweep.acquire_lock
      IcodosReminderSweep.release_lock

      raise 'the sweep lock is not exclusive — two sweeps could double-send' unless first && !second

      'exclusive'
    end

    step('sweep heartbeat is fresh') do
      last = IcodosReminderSweep.last_swept_at

      raise 'no sweep has ever run — is the host cron installed?' if last.nil?

      age = ((Time.current - last) / 60).round

      raise "the last sweep was #{age} minutes ago; the cron is probably gone" if age > 120

      "#{age} min ago"
    end

    step('pending submissions are visible') do
      count = IcodosReminderSweep.candidates_scope.count

      "#{count} submission(s) in scope"
    end

    step('dry-run sweep completes') do
      result = IcodosReminderSweep.call(dry_run: true)

      raise "sweep returned #{result[:status]}" unless %w[dry_run locked].include?(result[:status])
      raise "sweep reported errors: #{result[:errors].join('; ')}" if result[:errors].to_a.any?

      "#{result[:due]} reminder(s) currently due"
    end

    step('the Pro setting is not still lying around') do
      rows = AccountConfig.where(key: 'submitter_reminders').count

      raise 'submitter_reminders is still set; the settings page implies reminders that DocuSeal will never send' if rows.positive?

      'removed'
    end

    puts "\n#{@failed ? 'FAILED — see above' : 'All checks passed.'}\n\n"

    !@failed
  end

  def step(label)
    detail = yield
    puts format('  %-44s ok    %s', label, detail)
  rescue StandardError => e
    @failed = true
    puts format('  %-44s FAIL  %s: %s', label, e.class.name.split('::').last, e.message)
  end
end
