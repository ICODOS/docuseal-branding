# frozen_string_literal: true

# ICODOS — offline self-test for the reminder scheduler.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_reminders_selftest.rb.
#
# Runs IN THE CONTAINER rather than on a laptop, unlike the other overlay
# selftests. Reminder scheduling is timezone arithmetic, and getting DST right
# needs real tzinfo data, not a fixed offset. It still touches no network, no
# tenant, no email and no database.
#
#   docker compose exec app bin/rails runner \
#     'require "icodos_reminders_selftest"; IcodosRemindersSelftest.call'
#
# Zeitwerk maps lib/icodos_reminders_selftest.rb to IcodosRemindersSelftest.
# Naming these out of step stops the container booting.

module IcodosRemindersSelftest
  TZ = 'Europe/Berlin'

  module_function

  def call
    @fails = []

    puts "\nICODOS reminder scheduler — selftest\n\n"

    presets
    validation
    basic_schedule
    sending_window
    weekends
    dst
    caps
    stop_conditions
    deadline_anchor
    paused
    summary

    puts
    if @fails.empty?
      puts 'reminder selftest: all checks passed'
      true
    else
      puts "reminder selftest: #{@fails.length} FAILURE(S)"
      @fails.each { |f| puts "  - #{f}" }
      false
    end
  end

  def check(label, ok, detail = '')
    puts format('  %-48s %s  %s', label, ok ? 'ok  ' : 'FAIL', detail)
    @fails << "#{label} #{detail}".strip unless ok
  end

  def zone
    ActiveSupport::TimeZone[TZ]
  end

  def t(str)
    zone.parse(str)
  end

  # ------------------------------------------------------------------ sections

  def presets
    puts "presets\n\n"

    IcodosReminders::PRESETS.each_key do |name|
      policy = IcodosReminders.preset(name)
      ok = name == 'off' ? policy.nil? : policy.is_a?(Hash)
      check("preset #{name}", ok, policy.nil? ? 'no reminders' : policy['preset'].to_s)
    end

    # Each preset must survive normalisation, which is what the tools will do.
    IcodosReminders::PRESETS.each_key do |name|
      begin
        IcodosReminders.normalize(IcodosReminders.preset(name))
        check("#{name} normalises", true)
      rescue StandardError => e
        check("#{name} normalises", false, "#{e.class}: #{e.message}")
      end
    end
  end

  def validation
    puts "\nvalidation — bad policies must be refused\n\n"

    bad = {
      'no anchor at all' => {},
      'descending offsets' => { 'after_send' => { 'schedule' => [168, 72] } },
      'negative offset' => { 'after_send' => { 'schedule' => [-1] } },
      'zero interval' => { 'after_send' => { 'schedule' => [72], 'then_every_hours' => 0 } },
      'unknown timezone' => { 'after_send' => { 'schedule' => [72] }, 'window' => { 'tz' => 'Mars/Olympus' } },
      'window inverted' => { 'after_send' => { 'schedule' => [72] }, 'window' => { 'from' => '18:00', 'to' => '09:00' } },
      'window malformed' => { 'after_send' => { 'schedule' => [72] }, 'window' => { 'from' => '9am', 'to' => '5pm' } },
      'nonsense stop' => { 'after_send' => { 'schedule' => [72] }, 'stop' => { 'whenever' => true } }
    }

    bad.each do |label, policy|
      begin
        IcodosReminders.normalize(policy)
        check(label, false, 'was accepted')
      rescue IcodosReminders::InvalidPolicy => e
        check(label, true, e.message[0, 46])
      end
    end
  end

  def basic_schedule
    puts "\nschedule — day 3, day 7, then daily\n\n"

    policy = IcodosReminders.preset('standard')
    sent = t('2026-08-03 10:00')   # a Monday

    first = IcodosReminders.next_at(policy: policy, sent_at: sent, sent_count: 0, now: sent)
    check('first is 72h later, inside the window', first == t('2026-08-06 10:00'), first.to_s)

    second = IcodosReminders.next_at(policy: policy, sent_at: sent, sent_count: 1, last_sent_at: first, now: first + 60)
    check('second is 168h after sending', second == t('2026-08-10 10:00'), second.to_s)

    third = IcodosReminders.next_at(policy: policy, sent_at: sent, sent_count: 2, last_sent_at: second, now: second + 60)
    check('third is daily after the list', third == t('2026-08-11 10:00'), third.to_s)

    times = IcodosReminders.upcoming(policy: policy, sent_at: sent, now: sent, limit: 4)
    check('upcoming ascends', times == times.sort, times.map { |x| x.strftime('%d %b %H:%M') }.join(' | '))
    check('upcoming respects stop.after_count', times.length <= 6)
  end

  def sending_window
    puts "\nsending window — nobody gets a contract email at 03:12\n\n"

    policy = IcodosReminders.normalize(
      'after_send' => { 'schedule' => [1] },
      'window' => { 'tz' => TZ, 'from' => '09:00', 'to' => '17:00', 'weekdays_only' => false }
    )

    # 02:00 + 1h = 03:00, before the window opens: same day at 09:00.
    early = IcodosReminders.next_at(policy: policy, sent_at: t('2026-08-04 02:00'), now: t('2026-08-04 02:00'))
    check('before the window opens -> 09:00 same day', early == t('2026-08-04 09:00'), early.to_s)

    # 20:00 + 1h = 21:00, after it closes: next day at 09:00.
    late = IcodosReminders.next_at(policy: policy, sent_at: t('2026-08-04 20:00'), now: t('2026-08-04 20:00'))
    check('after it closes -> 09:00 next day', late == t('2026-08-05 09:00'), late.to_s)

    # Inside the window is left exactly alone.
    mid = IcodosReminders.next_at(policy: policy, sent_at: t('2026-08-04 11:00'), now: t('2026-08-04 11:00'))
    check('inside the window is untouched', mid == t('2026-08-04 12:00'), mid.to_s)

    # Boundaries are inclusive, so 17:00 exactly is still allowed.
    edge = IcodosReminders.next_at(policy: policy, sent_at: t('2026-08-04 16:00'), now: t('2026-08-04 16:00'))
    check('17:00 exactly is inside', edge == t('2026-08-04 17:00'), edge.to_s)
  end

  def weekends
    puts "\nweekends\n\n"

    policy = IcodosReminders.preset('standard')   # weekdays_only by default

    # Thursday 6 Aug + 72h = Sunday 9 Aug -> Monday.
    sunday = IcodosReminders.next_at(policy: policy, sent_at: t('2026-08-06 10:00'), now: t('2026-08-06 10:00'))
    check('Sunday is pushed to Monday 09:00', sunday == t('2026-08-10 09:00'), sunday.to_s)

    weekend_ok = IcodosReminders.normalize(
      'after_send' => { 'schedule' => [72] },
      'window' => { 'weekdays_only' => false }
    )
    kept = IcodosReminders.next_at(policy: weekend_ok, sent_at: t('2026-08-06 10:00'), now: t('2026-08-06 10:00'))
    check('weekdays_only false keeps Sunday', kept == t('2026-08-09 10:00'), kept.to_s)
  end

  def dst
    puts "\nDST — the wall clock must stay put across a transition\n\n"

    policy = IcodosReminders.normalize(
      'after_send' => { 'schedule' => [24], 'then_every_hours' => 24 },
      'window' => { 'tz' => TZ, 'from' => '09:00', 'to' => '17:00', 'weekdays_only' => false },
      'stop' => { 'never' => true }
    )

    # Clocks go back in Europe/Berlin on Sunday 25 October 2026.
    autumn = IcodosReminders.upcoming(policy: policy, sent_at: t('2026-10-23 09:00'),
                                      now: t('2026-10-23 09:00'), limit: 5)
    hours = autumn.map { |x| x.in_time_zone(zone).hour }.uniq
    offsets = autumn.map { |x| x.in_time_zone(zone).utc_offset }.uniq
    check('autumn: local hour constant across the change', hours == [9], "hours=#{hours.inspect}")
    check('autumn: the UTC offset really did change', offsets.length > 1, "offsets=#{offsets.inspect}")

    # Clocks go forward on Sunday 29 March 2026.
    spring = IcodosReminders.upcoming(policy: policy, sent_at: t('2026-03-27 09:00'),
                                      now: t('2026-03-27 09:00'), limit: 5)
    hours = spring.map { |x| x.in_time_zone(zone).hour }.uniq
    offsets = spring.map { |x| x.in_time_zone(zone).utc_offset }.uniq
    check('spring: local hour constant across the change', hours == [9], "hours=#{hours.inspect}")
    check('spring: the UTC offset really did change', offsets.length > 1, "offsets=#{offsets.inspect}")
  end

  def caps
    puts "\ncaps — a wrong policy must send fewer emails, never more\n\n"

    hourly = IcodosReminders.normalize(
      'after_send' => { 'schedule' => [1], 'then_every_hours' => 1 },
      'window' => { 'from' => '00:00', 'to' => '23:59', 'weekdays_only' => false },
      'stop' => { 'never' => true }
    )

    sent = t('2026-08-04 09:00')
    times = IcodosReminders.upcoming(policy: hourly, sent_at: sent, now: sent, limit: 4)
    gaps = times.each_cons(2).map { |a, b| ((b - a) / 3600.0).round(1) }

    check('an hourly policy is throttled to daily', gaps.all? { |g| g >= 24 }, "gaps(h)=#{gaps.inspect}")

    ceiling = IcodosReminders.next_at(policy: hourly, sent_at: sent,
                                      sent_count: IcodosReminders::MAX_TOTAL_PER_SUBMITTER, now: sent)
    check("stops at the #{IcodosReminders::MAX_TOTAL_PER_SUBMITTER}-reminder ceiling", ceiling.nil?)

    # A manual send moments ago must delay the scheduled one.
    soon = IcodosReminders.next_at(policy: hourly, sent_at: sent, sent_count: 1,
                                   last_sent_at: t('2026-08-05 08:59'), now: t('2026-08-05 09:00'))
    check('a manual send pushes the next one out', soon >= t('2026-08-06 08:59'), soon.to_s)
  end

  def stop_conditions
    puts "\nstop conditions\n\n"

    counted = IcodosReminders.normalize('after_send' => { 'schedule' => [72], 'then_every_hours' => 24 },
                                        'stop' => { 'after_count' => 2 })
    sent = t('2026-08-03 10:00')
    check('stops after the count', IcodosReminders.upcoming(policy: counted, sent_at: sent, now: sent, limit: 9).length == 2)

    dated = IcodosReminders.normalize('after_send' => { 'schedule' => [72], 'then_every_hours' => 24 },
                                      'stop' => { 'on' => '2026-08-08' })
    after = IcodosReminders.next_at(policy: dated, sent_at: sent, sent_count: 1, now: t('2026-08-09 10:00'))
    check('stops after the date', after.nil?, after.to_s)

    never = IcodosReminders.preset('until_signed')
    check('never keeps going', IcodosReminders.upcoming(policy: never, sent_at: sent, now: sent, limit: 6).length == 6)
  end

  def deadline_anchor
    puts "\ndeadline anchor — the Dropbox Sign pattern, for grant reporting\n\n"

    policy = IcodosReminders.preset('deadline')
    deadline = t('2026-09-30 12:00')
    sent = t('2026-09-01 10:00')

    times = IcodosReminders.upcoming(policy: policy, sent_at: sent, deadline: deadline,
                                      now: sent, limit: 3)
    days_out = times.map { |x| ((deadline - x) / 86_400.0).round }

    check('fires ahead of the deadline, not after sending', days_out.first <= 7, "days before=#{days_out.inspect}")
    check('all reminders precede the deadline', times.all? { |x| x < deadline })

    # Inside the run-up it should switch to daily.
    late = IcodosReminders.upcoming(policy: policy, sent_at: sent, deadline: deadline,
                                     now: t('2026-09-29 09:00'), limit: 2)
    check('daily inside the final 48 hours', late.length >= 1, late.map { |x| x.strftime('%d %b %H:%M') }.join(' | '))

    past = IcodosReminders.next_at(policy: policy, sent_at: sent, deadline: deadline, now: t('2026-10-01 09:00'))
    check('silent once the deadline has passed', past.nil?, past.to_s)
  end

  def paused
    puts "\npause\n\n"

    policy = IcodosReminders.normalize('after_send' => { 'schedule' => [72] },
                                       'paused_until' => '2026-09-15')
    sent = t('2026-08-03 10:00')
    at = IcodosReminders.next_at(policy: policy, sent_at: sent, now: t('2026-08-10 10:00'))

    check('nothing before the pause lifts', at >= t('2026-09-15 00:00'), at.to_s)
  end

  def summary
    puts "\nsummary sentence — what the UI shows\n\n"

    policy = IcodosReminders.preset('standard')
    sent = t('2026-08-03 10:00')

    text = IcodosReminders.describe(policy: policy, sent_at: sent, now: sent,
                                    submitter_name: 'Devraj Solanki', sender_name: 'David')

    check('names the signer', text.include?('Devraj Solanki'))
    check('gives a real date, not a rule', text.match?(/\d{1,2} \w{3}/), text[0, 60])
    check('mentions escalation', text.downcase.include?('escalat'))
    check('states the daily cap', text.downcase.include?('once a day'))

    off = IcodosReminders.describe(policy: nil, sent_at: sent, now: sent)
    check('off reads plainly', off.downcase.include?('no reminders'), off)

    stopped = IcodosReminders.describe(policy: IcodosReminders.preset('gentle'), sent_at: sent,
                                        sent_count: 2, now: sent, submitter_name: 'Devraj Solanki')
    check('exhausted reads plainly', stopped.downcase.include?('no further'), stopped[0, 70])

    puts
    puts "  example: #{text}"
  end
end
