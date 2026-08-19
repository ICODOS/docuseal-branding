# frozen_string_literal: true

# ICODOS — signature reminder policy and scheduling.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_reminders.rb.
#
# WHY THIS EXISTS
# Automatic reminders are a DocuSeal Pro feature. Our build ships the reminder
# email template, its per-template override and a `send_reminder_email` audit
# event type, but nothing that decides when to send or actually sends. Worse,
# the settings page renders a working-looking form writing `submitter_reminders`,
# which nothing reads: on 15 Aug 2026 it held {two_days, four_days, six_days}
# and had sent exactly zero reminders while 13 submissions sat unsigned.
#
# THIS FILE HOLDS THE MATHS ONLY. It sends nothing and touches no network, so
# every rule below is testable in isolation. See reminders/selftest.rb.
#
# The schedule shape is one list of hour offsets plus an optional steady
# interval, which expresses every cadence the major products offer and the
# escalating pattern none of them do natively:
#
#   DocuSign default      schedule [72],      then_every_hours 72
#   Dropbox Sign default   schedule [72, 168], no steady phase
#   Adobe weekly-until     schedule [168],     then_every_hours 168
#   Recommended escalation schedule [72, 168], then_every_hours 24
#
# ROLLBACK: ICODOS_REMINDERS_ENABLED=false and `docker compose up -d`.

module IcodosReminders
  class Error < StandardError; end
  class InvalidPolicy < Error; end

  ENABLED_FLAG = 'ICODOS_REMINDERS_ENABLED'
  DRY_RUN_FLAG = 'ICODOS_REMINDERS_DRY_RUN'

  POLICY_KEY = 'icodos_reminders'
  ACCOUNT_DEFAULT_KEY = 'icodos_reminder_policy'

  # Per-submitter counters live under a SEPARATE key from the policy.
  #
  # Not cosmetic: most submissions have no policy of their own and inherit the
  # account default. If state were written into POLICY_KEY, the first send would
  # leave behind a hash containing only counters, policy_for would then read
  # that as the submission's policy instead of falling back to the account
  # default, and normalize would reject it for having no anchor. Reminders would
  # stop after exactly one, per submission, for a reason nobody would guess.
  STATE_KEY = 'icodos_reminder_state'

  DEFAULT_TZ = 'Europe/Berlin'
  DEFAULT_WINDOW = { 'tz' => DEFAULT_TZ, 'from' => '09:00', 'to' => '17:00', 'weekdays_only' => true }.freeze

  # --- caps that no policy can override ---------------------------------------
  #
  # These exist so a configuration mistake cannot become an incident. A wrong
  # policy should produce fewer emails than intended, never more.

  # DocuSign's rule, and simpler to explain than an hours figure.
  MAX_PER_DAY_PER_SUBMITTER = 1

  # Dropbox Sign's rule. Counts manual sends too, so a human and the scheduler
  # cannot collide.
  MIN_GAP_SECONDS = 3600

  # Matches RightSignature's documented ceiling. A backstop, not a target.
  MAX_TOTAL_PER_SUBMITTER = 30

  # A bad query must not be able to mail the company.
  MAX_PER_SWEEP = 200

  # Guards the window search against a policy that admits no valid slot.
  MAX_WINDOW_SHIFT_DAYS = 14

  PRESETS = {
    'off' => nil,

    # Dropbox Sign's default: two nudges, then leave them alone.
    'gentle' => {
      'after_send' => { 'schedule' => [72, 168] },
      'stop' => { 'after_count' => 2 }
    },

    # The escalating pattern the research recommends: day 3, day 7, then daily.
    # Escalation is what makes an open-ended cadence defensible.
    'standard' => {
      'after_send' => { 'schedule' => [72, 168], 'then_every_hours' => 24 },
      'stop' => { 'after_count' => 6 },
      'escalate_after' => 3
    },

    # Deadline-anchored, the Dropbox Sign pattern, for grant reporting where the
    # pressure is a date rather than how long ago we sent it.
    'deadline' => {
      'before_deadline' => { 'days' => [7, 3, 1], 'daily_within_hours' => 48 },
      'stop' => { 'after_count' => 8 },
      'escalate_after' => 2
    },

    'until_signed' => {
      'after_send' => { 'schedule' => [72], 'then_every_hours' => 168 },
      'stop' => { 'never' => true },
      'escalate_after' => 3
    }
  }.freeze

  module_function

  def enabled?
    ENV[ENABLED_FLAG].to_s.strip.casecmp('true').zero?
  end

  # Dry run is the DEFAULT. Sending requires explicitly setting it to false,
  # so a half-finished deployment cannot start emailing employees.
  def dry_run?
    !ENV[DRY_RUN_FLAG].to_s.strip.casecmp('false').zero?
  end

  # ------------------------------------------------------------------ policies

  def preset(name)
    key = name.to_s.strip.downcase

    raise InvalidPolicy, "unknown preset #{name.inspect} (have: #{PRESETS.keys.join(', ')})" unless PRESETS.key?(key)

    value = PRESETS[key]

    value.nil? ? nil : deep_dup(value).merge('preset' => key)
  end

  # Fills in defaults and rejects anything nonsensical. Returns nil for "no
  # reminders", which is a valid policy and not an error.
  def normalize(policy)
    return nil if policy.nil?

    policy = stringify(policy)

    return preset(policy['preset']) if policy.key?('preset') && policy.keys.sort == %w[preset]

    after = policy['after_send']
    before = policy['before_deadline']

    if after.nil? && before.nil?
      raise InvalidPolicy, 'a policy needs after_send, before_deadline, or both'
    end

    if after
      offsets = Array(after['schedule']).map { |h| Integer(h) rescue raise(InvalidPolicy, "schedule offsets must be whole hours, got #{h.inspect}") }

      raise InvalidPolicy, 'schedule offsets must be positive' if offsets.any?(&:negative?)
      raise InvalidPolicy, 'schedule offsets must ascend' unless offsets == offsets.sort

      every = after['then_every_hours']

      if every && Integer(every) < 1
        raise InvalidPolicy, 'then_every_hours must be at least 1'
      end

      after = { 'schedule' => offsets }
      after['then_every_hours'] = Integer(every) if every
    end

    if before
      days = Array(before['days']).map { |d| Integer(d) }

      raise InvalidPolicy, 'before_deadline.days must be positive' if days.any? { |d| d < 0 }

      before = { 'days' => days.sort.reverse }
      before['deadline'] = before_deadline_date(policy).to_s if before_deadline_date(policy)
      before['daily_within_hours'] = Integer(policy.dig('before_deadline', 'daily_within_hours')) if policy.dig('before_deadline', 'daily_within_hours')
    end

    normalized = {}
    normalized['preset'] = policy['preset'] if policy['preset']
    normalized['after_send'] = after if after
    normalized['before_deadline'] = before if before
    normalized['window'] = normalize_window(policy['window'])
    normalized['stop'] = normalize_stop(policy['stop'])
    normalized['escalate_after'] = Integer(policy['escalate_after']) if policy['escalate_after']
    normalized['note'] = policy['note'].to_s.strip[0, 300] if policy['note'].to_s.strip.present?
    normalized['paused_until'] = policy['paused_until'].to_s if policy['paused_until'].present?

    normalized
  end

  def normalize_window(window)
    window = stringify(window || {})

    tz = window['tz'].presence || DEFAULT_TZ

    raise InvalidPolicy, "unknown timezone #{tz.inspect}" if ActiveSupport::TimeZone[tz].nil?

    from = window['from'].presence || DEFAULT_WINDOW['from']
    to   = window['to'].presence   || DEFAULT_WINDOW['to']

    raise InvalidPolicy, "window times must look like 09:00, got #{from.inspect}/#{to.inspect}" unless
      from.to_s.match?(/\A\d{2}:\d{2}\z/) && to.to_s.match?(/\A\d{2}:\d{2}\z/)

    raise InvalidPolicy, 'window from must be earlier than to' if minutes_of(from) >= minutes_of(to)

    {
      'tz' => tz,
      'from' => from,
      'to' => to,
      'weekdays_only' => window.key?('weekdays_only') ? !!window['weekdays_only'] : DEFAULT_WINDOW['weekdays_only']
    }
  end

  def normalize_stop(stop)
    stop = stringify(stop || {})

    return { 'after_count' => 6 } if stop.empty?
    return { 'never' => true } if stop['never']

    if stop['after_count']
      count = Integer(stop['after_count'])

      raise InvalidPolicy, 'stop.after_count must be at least 1' if count < 1

      return { 'after_count' => [count, MAX_TOTAL_PER_SUBMITTER].min }
    end

    return { 'on' => stop['on'].to_s } if stop['on'].present?

    raise InvalidPolicy, "stop must be after_count, on, or never (got #{stop.inspect})"
  end

  # ---------------------------------------------------------------- scheduling

  # When the next reminder for one submitter is due, or nil if never.
  #
  # Deliberately pure: every input is passed in, so the whole ruleset is
  # testable without a database, a tenant or a clock.
  def next_at(policy:, sent_at:, sent_count: 0, last_sent_at: nil, deadline: nil, now: Time.current)
    policy = normalize(policy)

    return nil if policy.nil?
    return nil if sent_at.nil?
    return nil if stopped?(policy, sent_count: sent_count, now: now)

    paused = parse_time(policy['paused_until'])

    return paused if paused && paused > now

    candidate = [
      after_send_candidate(policy, sent_at: sent_at, sent_count: sent_count, last_sent_at: last_sent_at),
      before_deadline_candidate(policy, deadline: deadline, last_sent_at: last_sent_at, now: now)
    ].compact.min

    return nil if candidate.nil?

    candidate = [candidate, now].max
    candidate = enforce_gaps(candidate, last_sent_at: last_sent_at, policy: policy)

    shift_into_window(candidate, policy['window'])
  end

  # Advancing a whole number of days must preserve the WALL CLOCK, not add
  # absolute seconds. Adding 86_400s across a spring-forward day moves 09:00 to
  # 10:00, because that day is only 23 hours long. The selftest caught exactly
  # this on 29 March 2026, and the autumn case had been passing only by luck:
  # it landed at 08:00 and the window shift happened to correct it.
  def advance_hours(base, hours, zone)
    return base + (hours * 3600) unless (hours.abs % 24).zero?

    base.in_time_zone(zone).advance(days: hours / 24)
  end

  def zone_for(policy)
    ActiveSupport::TimeZone[policy.dig('window', 'tz') || DEFAULT_TZ] || ActiveSupport::TimeZone[DEFAULT_TZ]
  end

  def after_send_candidate(policy, sent_at:, sent_count:, last_sent_at:)
    after = policy['after_send']

    return nil if after.nil?

    offsets = after['schedule']
    zone = zone_for(policy)

    return advance_hours(sent_at, offsets[sent_count], zone) if sent_count < offsets.length

    every = after['then_every_hours']

    return nil if every.nil?

    base = last_sent_at || advance_hours(sent_at, offsets.last || 0, zone)

    advance_hours(base, every, zone)
  end

  def before_deadline_candidate(policy, deadline:, last_sent_at:, now:)
    before = policy['before_deadline']

    return nil if before.nil?

    deadline = parse_time(deadline || before['deadline'])

    return nil if deadline.nil?
    return nil if now > deadline

    # Daily once inside the run-up, which is what a reporting deadline warrants.
    within = before['daily_within_hours']

    zone = zone_for(policy)

    if within && (deadline - now) <= (within * 3600)
      base = last_sent_at || advance_hours(now, -24, zone)

      return [advance_hours(base, 24, zone), now].max
    end

    before['days']
      .map { |d| advance_hours(deadline, -(d * 24), zone) }
      .select { |t| t > (last_sent_at || Time.at(0)) && t >= (now - 3600) }
      .min
  end

  # The caps from the research, applied after the policy has had its say. A
  # policy asking for hourly reminders gets daily ones, not hourly.
  def enforce_gaps(candidate, last_sent_at:, policy:)
    return candidate if last_sent_at.nil?

    zone = zone_for(policy)

    earliest_by_gap = last_sent_at + MIN_GAP_SECONDS

    # "At most once a day" means not twice on the same calendar day, so this
    # advances in calendar terms too. Expressing it as 86_400 seconds would
    # fight the wall-clock fix above on a spring-forward day and push 09:00
    # out to 10:00.
    earliest_by_day = advance_hours(last_sent_at, 24 * MAX_PER_DAY_PER_SUBMITTER, zone)

    [candidate, earliest_by_gap, earliest_by_day].max
  end

  def stopped?(policy, sent_count:, now: Time.current)
    return true if sent_count >= MAX_TOTAL_PER_SUBMITTER

    stop = policy['stop'] || {}

    return false if stop['never']
    return sent_count >= stop['after_count'] if stop['after_count']

    if stop['on']
      on = parse_time(stop['on'])

      return now > on if on
    end

    false
  end

  # Moves a time into the next moment that satisfies the sending window. Nobody
  # should receive a contract reminder at 03:12.
  def shift_into_window(time, window)
    window = normalize_window(window)
    zone = ActiveSupport::TimeZone[window['tz']]

    from = minutes_of(window['from'])
    to   = minutes_of(window['to'])

    candidate = time.in_time_zone(zone)

    MAX_WINDOW_SHIFT_DAYS.times do
      minutes = (candidate.hour * 60) + candidate.min

      if window['weekdays_only'] && candidate.on_weekend?
        candidate = at_minutes(candidate + 1.day, from, zone)
        next
      end

      return candidate if minutes >= from && minutes <= to

      # Before the window opens on a valid day: wait for it. After it closes:
      # tomorrow. Computed through the zone so DST shifts are handled by tzinfo
      # rather than by arithmetic.
      candidate = minutes < from ? at_minutes(candidate, from, zone) : at_minutes(candidate + 1.day, from, zone)
    end

    nil
  end

  def at_minutes(time, minutes, zone)
    local = time.in_time_zone(zone)

    zone.local(local.year, local.month, local.day, minutes / 60, minutes % 60, 0)
  end

  # ------------------------------------------------------------------ helpers

  def minutes_of(hhmm)
    hours, mins = hhmm.to_s.split(':').map(&:to_i)

    (hours * 60) + mins
  end

  def parse_time(value)
    return nil if value.blank?
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    return value.to_time if value.is_a?(Date)

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def before_deadline_date(policy)
    parse_time(policy.dig('before_deadline', 'deadline'))
  end

  def stringify(hash)
    return {} if hash.nil?
    return hash.deep_stringify_keys if hash.respond_to?(:deep_stringify_keys)

    hash
  end

  def deep_dup(value)
    Marshal.load(Marshal.dump(value))
  end

  # ------------------------------------------------------- preview and summary
  #
  # THE SAME CODE THAT SCHEDULES ALSO DESCRIBES. That is deliberate and it is a
  # correctness property, not presentation: the UI's "what will happen" sentence
  # is produced by simulating this scheduler forward, so a preview cannot drift
  # from the behaviour. Every good recurrence picker renders a plain-text
  # description built from the live values; we can do better than a generic one
  # because we know the real send date and the real signer.

  # The next `limit` reminder times, by running the scheduler forward.
  def upcoming(policy:, sent_at:, sent_count: 0, last_sent_at: nil, deadline: nil, now: Time.current, limit: 4)
    times = []
    count = sent_count
    last = last_sent_at
    cursor = now

    limit.times do
      at = next_at(policy: policy, sent_at: sent_at, sent_count: count,
                   last_sent_at: last, deadline: deadline, now: cursor)

      break if at.nil?

      times << at
      count += 1
      last = at
      cursor = at + 1
    end

    times
  end

  # A sentence a person can check at a glance. Real dates, real names.
  def describe(policy:, sent_at:, sent_count: 0, last_sent_at: nil, deadline: nil,
               submitter_name: nil, sender_name: nil, now: Time.current)
    normalized = normalize(policy)

    return 'No reminders. Nobody will be chased about this one.' if normalized.nil?

    paused = parse_time(normalized['paused_until'])

    if paused && paused > now
      return "Paused until #{stamp(paused, normalized)}. No reminders until then."
    end

    times = upcoming(policy: normalized, sent_at: sent_at, sent_count: sent_count,
                     last_sent_at: last_sent_at, deadline: deadline, now: now, limit: 4)

    who = submitter_name.presence || 'the signer'

    if times.empty?
      return "No further reminders for #{who}: #{stopped_because(normalized, sent_count)}."
    end

    parts = ["Reminds #{who} on #{stamp(times.first, normalized)}"]
    parts << "then #{stamp(times[1], normalized, short: true)}" if times[1]
    parts << "then #{stamp(times[2], normalized, short: true)}" if times[2]

    steady = normalized.dig('after_send', 'then_every_hours')
    parts << (steady == 24 ? 'then daily' : "then every #{pluralize_hours(steady)}") if steady && times.length >= 3

    sentence = "#{parts.join(', ')}."

    if (threshold = normalized['escalate_after'])
      remaining = threshold - sent_count

      sentence += remaining.positive? ?
        " Escalates to #{sender_name.presence || 'the sender'} after #{remaining} more unanswered." :
        " Already escalated to #{sender_name.presence || 'the sender'}."
    end

    sentence += " Stops after #{normalized.dig('stop', 'after_count')} in total." if normalized.dig('stop', 'after_count')
    sentence += ' Never more than once a day.'

    sentence
  end

  def stopped_because(policy, sent_count)
    return "#{sent_count} already sent, which is the limit" if policy.dig('stop', 'after_count').to_i <= sent_count && policy.dig('stop', 'after_count')
    return 'the stop date has passed' if policy.dig('stop', 'on')
    return "the #{MAX_TOTAL_PER_SUBMITTER}-reminder ceiling has been reached" if sent_count >= MAX_TOTAL_PER_SUBMITTER

    'the schedule has no further slots'
  end

  def stamp(time, policy, short: false)
    zone = ActiveSupport::TimeZone[policy.dig('window', 'tz') || DEFAULT_TZ]
    local = time.in_time_zone(zone)

    short ? local.strftime('%a %-d %b') : local.strftime('%a %-d %b at %H:%M')
  end

  def pluralize_hours(hours)
    return '24 hours' if hours.nil?
    return 'week' if hours == 168
    return 'day' if hours == 24

    "#{hours} hours"
  end
end
