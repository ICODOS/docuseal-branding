# frozen_string_literal: true

# ICODOS Phase 5 — MCP tool: pause, resume or send a reminder now.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/mcp/icodos_set_reminders_controller.rb
#
# Acts through the reminder engine (reminders/), never around it:
#
#   pause     writes paused_until into the submission's own policy, which the
#             engine already honours (no reminder before that time)
#   resume    removes it again
#   send_now  one reminder to the signer whose turn it is, through the
#             engine's own sender, so the 20-hour cap per signer, the
#             record on the submission and the timeline event all apply
#
# Preview first, like every ICODOS tool that changes something
# (IcodosWorkflow::ActionTool): send_now emails a real person.
module Mcp
  class IcodosSetRemindersController < McpBaseController
    SCHEMA = {
      name: 'icodos_set_reminders',
      title: 'ICODOS Reminders: Pause, Resume, Send Now',
      description: 'Pause or resume the automatic reminders of one pending submission, or send one reminder ' \
                   'now to the signer whose turn it is. Two calls: without confirm it returns a preview and a ' \
                   'preview_token and changes nothing; show the preview to the human, and only after they agree ' \
                   'call again with the identical arguments plus confirm true and that preview_token (valid 15 ' \
                   'minutes, once). send_now emails a real person and is refused within 20 hours of the last ' \
                   'reminder to them. Never set confirm on your own initiative.',
      inputSchema: {
        type: 'object',
        properties: {
          submission_id: { type: 'integer', description: 'The submission id' },
          action: { type: 'string', enum: %w[pause resume send_now],
                    description: 'pause, resume or send_now' },
          until: {
            type: 'string',
            description: 'For pause only, optional: a date (YYYY-MM-DD, start of that day in the account time ' \
                         'zone) or an ISO 8601 time. Without it the pause lasts until resumed.'
          },
          confirm: { type: 'boolean', description: 'Must be the boolean true, together with preview_token, to act.' },
          preview_token: { type: 'string', description: 'The preview_token from the preview of exactly these arguments.' }
        },
        required: %w[submission_id action]
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
      }
    }.freeze

    ACTIONS = %w[pause resume send_now].freeze

    # "Until resumed" is a date far enough away that the engine's own pause
    # check covers it; the views show it as "until resumed".
    INDEFINITE = '2099-12-31T23:59:59Z'

    include ::IcodosToolErrors
    include ::IcodosWorkflow::ActionTool

    InvalidArguments = ::IcodosToolErrors::ToolError

    def call
      submission = load_submission!

      return if replayed?(submission)

      ensure_pending!(submission)

      unless IcodosReminders.enabled?
        raise InvalidArguments.new('the reminder engine is switched off on this instance', code: 'disabled')
      end

      @action = mcp_params['action'].to_s.strip

      raise InvalidArguments, "action must be one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(@action)

      @policy = IcodosReminderSweep.policy_for(submission)
      @recipient = IcodosWorkflow::View.waiting_on(submission).first
      @until = parse_until! if @action == 'pause'

      check_possible!(submission)

      icodos_action(submission)
    end

    private

    # rubocop:disable Metrics
    def check_possible!(submission)
      paused = IcodosReminders.parse_time(@policy&.dig('paused_until'))
      paused = nil if paused && paused <= Time.current

      case @action
      when 'pause'
        raise InvalidArguments, 'reminders are off for this submission; there is nothing to pause' if @policy.nil?
      when 'resume'
        raise InvalidArguments, 'the reminders of this submission are not paused' if paused.nil?
      when 'send_now'
        raise InvalidArguments, 'nobody is waiting to be reminded: no signer has been invited yet' if @recipient.nil?

        held = IcodosReminderSweep.claimable?(@recipient) == false

        if held
          raise InvalidArguments.new(
            "#{@recipient.email} got a reminder (or a failed attempt) less than 20 hours ago; a reminder now " \
            'would be held. Nothing was sent.', code: 'too_soon',
                                                hint: 'Try again tomorrow, or write to the person directly.'
          )
        end
      end
    end
    # rubocop:enable Metrics

    def parse_until!
      raw = mcp_params['until'].to_s.strip

      return nil if raw.empty?

      zone = ActiveSupport::TimeZone[current_user.account.timezone.to_s] || Time.zone
      time = raw.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? zone.parse(raw)&.beginning_of_day : zone.parse(raw)

      raise ArgumentError if time.nil?
      raise InvalidArguments, "until #{time.utc.iso8601} is in the past" if time <= Time.current

      time
    rescue ArgumentError
      raise InvalidArguments, "until #{raw.inspect} is not a date I can read"
    end

    def recipient_state(submission)
      return nil unless @recipient

      count, last = IcodosReminderSweep.effective_history(submission, @recipient)

      [@recipient.id, @recipient.email, count, IcodosWorkflow.iso(last)]
    end

    def previewed(submission)
      {
        'submission_id' => submission.id,
        'action' => @action,
        'until' => @until ? IcodosWorkflow.iso(@until) : (@action == 'pause' ? 'resumed' : nil),
        'policy' => @policy,
        'recipient' => recipient_state(submission)
      }
    end

    # rubocop:disable Metrics
    def preview_payload(submission)
      view = IcodosWorkflow::View
      now_info = @recipient ? view.reminders(submission, @recipient) : nil

      effect =
        case @action
        when 'pause'
          "No automatic reminder for this submission #{@until ? "until #{IcodosWorkflow.iso(@until)}" : 'until resumed'}. " \
            'Signing is not affected.'
        when 'resume'
          'Automatic reminders resume under the submission\'s policy; a reminder that fell due during the pause ' \
            'goes out at the next sweep (within 15 minutes), within the sending hours.'
        when 'send_now'
          "One reminder email now to #{@recipient.name} <#{@recipient.email}>, with the account's reminder text " \
            'and the signing link. It counts towards the reminder total; no further reminder to them for 20 hours.'
        end

      {
        action: @action,
        template: view.template(submission),
        waiting_on: @recipient && { name: @recipient.name, email: @recipient.email, status: @recipient.status,
                                    invited_at: IcodosWorkflow.iso(@recipient.sent_at) },
        reminders_now: now_info,
        effect: effect
      }.compact
    end
    # rubocop:enable Metrics

    # rubocop:disable Metrics
    def apply!(submission)
      case @action
      when 'pause', 'resume'
        submission.reload
        prefs = submission.preferences.to_h
        policy = (@policy || {}).dup
        policy.delete('paused_until')
        policy['paused_until'] = @until ? IcodosWorkflow.iso(@until) : INDEFINITE if @action == 'pause'

        submission.update!(preferences: prefs.merge(IcodosReminders::POLICY_KEY => policy))
        @icodos_done = "reminders #{@action == 'pause' ? 'paused' : 'resumed'} on submission #{submission.id}"

        { action: @action,
          summary: @action == 'pause' ? "paused #{@until ? "until #{IcodosWorkflow.iso(@until)}" : 'until resumed'}" : 'resumed',
          result: { action: @action, paused_until: @action == 'pause' ? (@until ? IcodosWorkflow.iso(@until) : 'until resumed') : nil,
                    reminders: @recipient ? IcodosWorkflow::View.reminders(submission.reload, @recipient) : nil }.compact }
      else
        count, = IcodosReminderSweep.effective_history(submission, @recipient)
        outcome = IcodosReminderSweep.deliver!(submission: submission, submitter: @recipient,
                                               policy: @policy || IcodosReminders.preset('standard'),
                                               sent_count: count, due_at: Time.current, escalate: false)

        if outcome == :sent
          @icodos_done = "a reminder was sent to #{@recipient.email}; do not send it again"
        end

        { action: 'send_now',
          summary: outcome == :sent ? "reminder sent to #{@recipient.email}" : "held: #{@recipient.email} had one less than 20 h ago",
          result: { action: 'send_now', sent: outcome == :sent, to: @recipient.email,
                    held: outcome == :sent ? nil : 'a reminder to this signer is less than 20 hours old; nothing was sent' }.compact }
      end
    end
    # rubocop:enable Metrics
  end
end
