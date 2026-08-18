# frozen_string_literal: true

# ICODOS — the reminder sweep.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_reminder_sweep.rb.
#
# Finds submitters whose next reminder is due and, once sending is enabled,
# sends it. Deliberately thin: every scheduling decision lives in
# IcodosReminders, which has no database or network and is tested in isolation.
#
# DRY RUN IS THE DEFAULT. Sending needs ICODOS_REMINDERS_DRY_RUN=false set
# explicitly, so a half-finished deployment cannot start emailing employees.
#
# Triggered by host cron rather than a self-rescheduling job: a chain of
# perform_in calls dies silently if Redis is flushed, and a reminder engine that
# quietly stops is the exact failure this work exists to fix. Cron is visible in
# crontab and its death is detectable via the heartbeat below.

module IcodosReminderSweep
  LOCK_KEY = 'icodos_reminders:sweep:lock'
  HEARTBEAT_KEY = 'icodos_reminders:sweep:last_swept_at'
  LOCK_TTL = 300

  module_function

  # Returns a summary hash. Never raises for one bad submission: a single
  # unparseable policy must not stop everyone else's reminders.
  def call(now: Time.current, limit: IcodosReminders::MAX_PER_SWEEP, dry_run: nil)
    return { status: 'disabled' } unless IcodosReminders.enabled?

    dry_run = IcodosReminders.dry_run? if dry_run.nil?

    unless acquire_lock
      Rails.logger.info('[icodos-reminders] sweep already running, skipping')

      return { status: 'locked' }
    end

    due = []
    errors = []

    begin
      candidates_scope.find_each do |submission|
        break if due.length >= limit

        begin
          due.concat(due_for(submission, now: now))
        rescue StandardError => e
          errors << "submission #{submission.id}: #{e.class}: #{e.message}"
          Rails.logger.error("[icodos-reminders] skipped submission #{submission.id}: #{e.class}: #{e.message}")
        end
      end

      due = due.first(limit)

      due.each { |item| dry_run ? log_intent(item) : deliver!(item) }
    ensure
      release_lock
      heartbeat!(now)
    end

    summary = { status: dry_run ? 'dry_run' : 'sent', due: due.length, errors: errors }

    Rails.logger.info("[icodos-reminders] sweep #{summary[:status]}: #{due.length} due, #{errors.length} errors")

    summary.merge(items: due)
  end

  # Only submissions that could possibly need a reminder. Completed, declined,
  # expired and archived are all excluded, as is anything on an archived
  # template.
  def candidates_scope
    Submission.active
              .where(completed_at: nil)
              .where('expire_at IS NULL OR expire_at > ?', Time.current)
              .includes(:submitters, :template)
  end

  def due_for(submission, now:)
    policy = policy_for(submission)

    return [] if policy.nil?
    return [] if submission.template&.archived_at?

    deadline = policy.dig('before_deadline', 'deadline')

    candidates(submission).filter_map do |submitter|
      state = state_for(submission, submitter)

      at = IcodosReminders.next_at(
        policy: policy,
        sent_at: submitter.sent_at,
        sent_count: state['sent_count'].to_i,
        last_sent_at: IcodosReminders.parse_time(state['last_sent_at']),
        deadline: deadline,
        now: now
      )

      next nil if at.nil? || at > now

      {
        submission: submission,
        submitter: submitter,
        due_at: at,
        sent_count: state['sent_count'].to_i,
        escalate: escalate?(policy, state['sent_count'].to_i),
        policy: policy
      }
    end
  end

  # ORDER AWARENESS. With submitters_order 'preserved' only the person whose
  # turn it is gets reminded — nagging an employee before ICODOS has
  # countersigned is worse than not reminding at all. This mirrors what
  # Submissions.send_signature_requests does when first inviting people, and it
  # is what Adobe means by "only the current recipients will be notified".
  def candidates(submission)
    live = submission.submitters.reject { |s| s.completed_at? || s.declined_at? }
                     .select { |s| s.sent_at.present? }

    return [] if live.empty?
    return live unless submission.submitters_order_preserved?

    ordered = submission.template_submitters.to_a.filter_map do |ts|
      live.find { |s| s.uuid == ts['uuid'] }
    end

    Array(ordered.first)
  end

  def policy_for(submission)
    raw = submission.preferences.to_h[IcodosReminders::POLICY_KEY]

    raw = account_default(submission) if raw.nil?

    IcodosReminders.normalize(raw)
  end

  def account_default(submission)
    config = AccountConfig.find_by(account_id: submission.account_id,
                                   key: IcodosReminders::ACCOUNT_DEFAULT_KEY)

    config&.value
  end

  def state_for(submission, submitter)
    submission.preferences.to_h
              .dig(IcodosReminders::POLICY_KEY, 'per_submitter', submitter.uuid)
              .to_h
  end

  def escalate?(policy, sent_count)
    threshold = policy['escalate_after']

    threshold.present? && sent_count >= threshold
  end

  # ------------------------------------------------------------------- output

  def log_intent(item)
    Rails.logger.info(
      "[icodos-reminders] WOULD SEND submission=#{item[:submission].id} " \
      "to=#{item[:submitter].email} sent_count=#{item[:sent_count]} " \
      "due=#{item[:due_at].iso8601}#{item[:escalate] ? ' ESCALATE' : ''}"
    )
  end

  # Step 3. Deliberately not implemented yet, and deliberately loud rather than
  # a silent no-op: flipping ICODOS_REMINDERS_DRY_RUN=false before the mailer
  # exists should fail visibly, not look like a working system sending nothing.
  def deliver!(item)
    raise NotImplementedError,
          'reminder delivery is not implemented yet (step 3). Leave ICODOS_REMINDERS_DRY_RUN unset or true; ' \
          "submission #{item[:submission].id} would have been reminded at #{item[:due_at].iso8601}."
  end

  # ------------------------------------------------------------- lock and beat

  def acquire_lock
    IcodosReminders.enabled? &&
      Sidekiq.redis { |c| c.call('SET', LOCK_KEY, Process.pid.to_s, 'NX', 'EX', LOCK_TTL) } == 'OK'
  rescue StandardError => e
    Rails.logger.error("[icodos-reminders] could not take the sweep lock (#{e.class}: #{e.message})")

    false
  end

  def release_lock
    Sidekiq.redis { |c| c.call('DEL', LOCK_KEY) }
  rescue StandardError
    nil
  end

  # The heartbeat is what makes a dead cron loud. Without it, a stopped
  # scheduler looks exactly like a scheduler with nothing to do — which is how
  # the Pro setting managed to look configured for weeks while sending nothing.
  def heartbeat!(now = Time.current)
    Sidekiq.redis { |c| c.call('SET', HEARTBEAT_KEY, now.utc.iso8601, 'EX', 7 * 24 * 3600) }
  rescue StandardError
    nil
  end

  def last_swept_at
    raw = Sidekiq.redis { |c| c.call('GET', HEARTBEAT_KEY) }

    raw && Time.zone.parse(raw)
  rescue StandardError
    nil
  end
end
