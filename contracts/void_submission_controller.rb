# frozen_string_literal: true

# ICODOS Phase 5 — MCP tool: void a document that is out for signature.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/mcp/icodos_void_submission_controller.rb
#
# Voiding is upstream's archive of a submission, which is what the web
# interface does: the signing page then shows "archived" and accepts nothing,
# the reminder sweep leaves it alone, and the submission stays in the
# database with its events. Upstream's submission.archived webhook event is
# sent as the web interface sends it. Nobody is emailed.
#
# Only a pending document. A signed one is not voided by a tool: undoing a
# signed contract is a legal act, done with a new document.
module Mcp
  class IcodosVoidSubmissionController < McpBaseController
    SCHEMA = {
      name: 'icodos_void_submission',
      title: 'Void ICODOS Document Out for Signature',
      description: 'Void a document that is still out for signature (wrong document, wrong person, superseded). ' \
                   'The signing links stop working, reminders stop, nothing is filed; nobody is emailed, so tell ' \
                   'the people already invited yourself. A signed document cannot be voided. Two calls: without ' \
                   'confirm it returns a preview and a preview_token and changes nothing; show the preview to the ' \
                   'human, and only after they agree call again with the identical arguments plus confirm true and ' \
                   'that preview_token (valid 15 minutes, once). Never set confirm on your own initiative.',
      inputSchema: {
        type: 'object',
        properties: {
          submission_id: { type: 'integer', description: 'The submission id' },
          reason: { type: 'string', description: 'Why, in a sentence. Recorded on the submission.' },
          confirm: { type: 'boolean', description: 'Must be the boolean true, together with preview_token, to act.' },
          preview_token: { type: 'string', description: 'The preview_token from the preview of exactly these arguments.' }
        },
        required: %w[submission_id reason]
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: false
      }
    }.freeze

    MAX_REASON = 300

    include ::IcodosToolErrors
    include ::IcodosWorkflow::ActionTool

    InvalidArguments = ::IcodosToolErrors::ToolError

    def call
      submission = load_submission!

      return if replayed?(submission)

      ensure_pending!(submission)

      @reason = mcp_params['reason'].to_s.gsub(/[[:cntrl:]]/, ' ').squeeze(' ').strip

      raise InvalidArguments, 'reason is required: why is this document voided?' if @reason.empty?
      raise InvalidArguments, "reason is longer than #{MAX_REASON} characters" if @reason.length > MAX_REASON

      icodos_action(submission)
    end

    private

    def previewed(submission)
      {
        'submission_id' => submission.id,
        'reason' => @reason,
        'signers' => submission.submitters.sort_by(&:id).map do |s|
          [s.id, s.email, s.sent_at&.to_i, s.opened_at&.to_i, s.completed_at&.to_i]
        end
      }
    end

    def preview_payload(submission)
      view = IcodosWorkflow::View
      invited = submission.submitters.select(&:sent_at?)
      signed = submission.submitters.select(&:completed_at?)

      {
        template: view.template(submission),
        signing_order: view.signers(submission, reminder_state: false),
        reason: @reason,
        effect: 'The submission is archived: its signing links show "archived" and accept nothing, reminders stop, ' \
                'nothing is filed. Nobody is emailed. ' \
                "#{signed.any? ? "Already signed by #{signed.map(&:name).join(', ')}; that signature is void with it. " : ''}" \
                "#{invited.any? ? "Invited so far: #{invited.map { |s| "#{s.name} <#{s.email}>" }.join(', ')}; tell them." : 'Nobody has been invited yet.'}"
      }
    end

    def apply!(submission)
      submission.update!(archived_at: Time.current)
      @icodos_done = "submission #{submission.id} voided (archived); do not void it again"

      begin
        WebhookUrls.enqueue_events(submission, 'submission.archived')
      rescue StandardError => e
        Rails.logger.error("[icodos-contracts] void: submission #{submission.id} archived, webhook event not " \
                           "queued (#{e.class}: #{e.message})")
      end

      { action: 'void', summary: "voided: #{@reason}",
        result: { voided: true, archived_at: submission.archived_at.utc.iso8601, reason: @reason } }
    end
  end
end
