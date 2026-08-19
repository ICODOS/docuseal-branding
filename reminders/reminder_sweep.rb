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
              .dig(IcodosReminders::STATE_KEY, 'per_submitter', submitter.uuid)
              .to_h
  end

  def record_sent!(submission, submitter, at:)
    prefs = submission.preferences.to_h
    state = prefs[IcodosReminders::STATE_KEY].to_h
    per = state['per_submitter'].to_h
    mine = per[submitter.uuid].to_h

    per[submitter.uuid] = {
      'sent_count' => mine['sent_count'].to_i + 1,
      'last_sent_at' => at.utc.iso8601
    }

    state['per_submitter'] = per
    state['last_sent_at'] = at.utc.iso8601

    submission.update!(preferences: prefs.merge(IcodosReminders::STATE_KEY => state))
  end

  # Recorded as a SubmissionEvent so a reminder appears in the submission's own
  # timeline in the DocuSeal UI, next to the invitation and the signature. The
  # event type already exists upstream and had never been written by anything.
  def log_event!(submitter)
    SubmissionEvent.create!(
      submission_id: submitter.submission_id,
      submitter_id: submitter.id,
      account_id: submitter.submission.account_id,
      event_type: 'send_reminder_email'
    )
  rescue StandardError => e
    # An audit row failing must not un-send an email that has already gone.
    Rails.logger.error("[icodos-reminders] could not record the audit event: #{e.class}: #{e.message}")
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

  # Sends, then records. In that order deliberately: if recording fails we have
  # an email out and a log line saying so, which is recoverable. If it were the
  # other way round a failed send would look like a successful one and the
  # person would never be chased again.
  def deliver!(item)
    submitter = item[:submitter]
    policy = item[:policy]

    IcodosReminderMailer.reminder_email(
      submitter,
      note: policy['note'],
      sent_count: item[:sent_count]
    ).deliver_now!

    record_sent!(item[:submission], submitter, at: Time.current)
    log_event!(submitter)

    Rails.logger.info(
      "[icodos-reminders] SENT submission=#{item[:submission].id} to=#{submitter.email} " \
      "reminder=#{item[:sent_count] + 1}"
    )

    escalate!(item) if item[:escalate]

    :sent
  end

  # Tells the sender once, and records it so it is not repeated on every
  # subsequent sweep. Never raises: an escalation failing must not undo a
  # reminder that has already gone out.
  def escalate!(item)
    submission = item[:submission]
    to = submission.created_by_user&.email

    if to.blank?
      Rails.logger.error("[icodos-reminders] cannot escalate submission=#{submission.id}: no sender address")

      return
    end

    prefs = submission.preferences.to_h
    state = prefs[IcodosReminders::STATE_KEY].to_h

    if state['escalated_at'].present?
      Rails.logger.info("[icodos-reminders] already escalated submission=#{submission.id}")

      return
    end

    IcodosReminderMailer.escalation_email(item[:submitter], to: to, sent_count: item[:sent_count] + 1).deliver_now!

    state['escalated_at'] = Time.current.utc.iso8601
    submission.update!(preferences: prefs.merge(IcodosReminders::STATE_KEY => state))

    Rails.logger.info("[icodos-reminders] ESCALATED submission=#{submission.id} to=#{to}")
  rescue StandardError => e
    Rails.logger.error("[icodos-reminders] escalation failed for submission=#{item[:submission].id}: " \
                       "#{e.class}: #{e.message}")
  end

  # Sends one reminder for one submitter, ignoring the dry-run flag and whether
  # the schedule says it is due. This is how the first live reminder was sent,
  # deliberately and one at a time, rather than by flipping the global flag and
  # letting the sweep loose on everything pending.
  def send_one!(submission_id, email)
    submission = Submission.find(submission_id)
    submitter = submission.submitters.find { |s| s.email.to_s.casecmp(email.to_s).zero? }

    raise ArgumentError, "no submitter #{email.inspect} on submission #{submission_id}" if submitter.nil?
    raise ArgumentError, 'that submitter has already completed' if submitter.completed_at?

    policy = policy_for(submission) || IcodosReminders.preset('standard')
    state = state_for(submission, submitter)

    deliver!(submission: submission, submitter: submitter, policy: policy,
             sent_count: state['sent_count'].to_i, due_at: Time.current,
             escalate: escalate?(policy, state['sent_count'].to_i))
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

  # Cheap by design. An earlier version ran a full dry-run sweep here to show a
  # "due right now" count, which meant every view of the settings page swept all
  # submissions AND took the sweep lock — so a page load could make the real cron
  # sweep skip itself as "already running", and every page view wrote a
  # "sweep dry_run" line to the log. The counts were removed from the UI, so the
  # sweep went with them. This now touches Redis once and nothing else.
  def status(_account = nil)
    last = last_swept_at

    {
      enabled: IcodosReminders.enabled?,
      dry_run: IcodosReminders.dry_run?,
      last_swept_at: last,
      stale: last.nil? || last < 2.hours.ago
    }
  rescue StandardError => e
    Rails.logger.error("[icodos-reminders] status failed (#{e.class}: #{e.message})")

    { enabled: false, dry_run: true, last_swept_at: nil, stale: true, error: "#{e.class}: #{e.message}" }
  end

  def last_swept_at
    raw = Sidekiq.redis { |c| c.call('GET', HEARTBEAT_KEY) }

    raw && Time.zone.parse(raw)
  rescue StandardError
    nil
  end
end
