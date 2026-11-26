# frozen_string_literal: true

# ICODOS Phase 5 — MCP tool: one submission, in full.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/mcp/icodos_get_submission_controller.rb
#
# Read only. Status, every signer in signing order with when they were
# invited, opened, signed or declined, the reminder engine's view, where the
# signed copy goes or went, the timeline of events, and what the ICODOS action
# tools did to it. Event details (addresses of the device, browser) are left
# out; the type, the time and the signer are enough to follow a document.
module Mcp
  class IcodosGetSubmissionController < McpBaseController
    SCHEMA = {
      name: 'icodos_get_submission',
      title: 'ICODOS Submission Details',
      description: 'Read only. One submission in full: status (pending, completed, declined, expired, archived), ' \
                   'signers in signing order with invited, opened, signed and declined times, whose turn it is, ' \
                   'reminders sent and the next one, where the signed copy is filed (filed_path once it is), the ' \
                   'event timeline, and what icodos_set_reminders, icodos_void_submission and ' \
                   'icodos_correct_signer did to it. The submission_id comes from icodos_send_contract or ' \
                   'icodos_pending_signatures.',
      inputSchema: {
        type: 'object',
        properties: {
          submission_id: { type: 'integer', description: 'The submission id' }
        },
        required: %w[submission_id]
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }
    }.freeze

    MAX_EVENTS = 40

    include ::IcodosToolErrors

    InvalidArguments = ::IcodosToolErrors::ToolError

    # rubocop:disable Metrics
    def call
      submission = Submission.accessible_by(current_ability).find(mcp_params['submission_id'])

      authorize!(:read, submission)

      unless IcodosGraph.enabled?
        raise InvalidArguments.new('the contract tools are not enabled on this instance', code: 'disabled')
      end

      view = IcodosWorkflow::View
      now = Time.current
      roles = view.roles(submission)
      by_id = submission.submitters.index_by(&:id)

      events = SubmissionEvent.where(submission_id: submission.id).order(:event_timestamp, :id).last(MAX_EVENTS)

      result = view.summary(submission, now: now).merge(
        source: submission.source,
        submitters_order: submission.submitters_order,
        signing_order: view.signers(submission),
        filing: view.filing(submission),
        filing_name: submission.preferences.to_h[IcodosWorkflow::FILING_NAME_KEY],
        documents_removed_at: submission.preferences.to_h[IcodosWorkflow::PURGED_KEY],
        events: events.map do |e|
          s = by_id[e.submitter_id]

          { at: e.event_timestamp&.utc&.iso8601, event: e.event_type,
            role: s && roles[s.uuid].to_h['name'], name: s&.name }.compact
        end,
        actions: view.actions(submission)
      )

      if submission.archived_at?
        void = view.actions(submission).reverse.find { |a| a['tool'] == 'icodos_void_submission' }
        result[:archived_at] = submission.archived_at.utc.iso8601
        result[:archived_by] = void ? 'icodos_void_submission' : 'the web interface or the API'
      end

      result[:events_note] = "the last #{MAX_EVENTS} events" if events.size == MAX_EVENTS

      render_tool_result(result.compact)
    end
    # rubocop:enable Metrics
  end
end
