# frozen_string_literal: true

# ICODOS Phase 5 — MCP tool: who is waiting to sign, and what was filed.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/mcp/icodos_pending_signatures_controller.rb
#
# Read only. Answers the questions that used to need the web interface: which
# documents are out, whose turn it is, how long they have been waiting, when
# the next reminder goes, and whether what was signed lately is in SharePoint.
#
# WHY NOT upstream search_documents
# It searches by name and returns up to ten submissions with upstream's
# status, all of them, the abandoned and the superseded included; an agent
# reading it took an older pending copy for the state of a signed contract.
# It knows nothing about reminders or filing.
module Mcp
  class IcodosPendingSignaturesController < McpBaseController
    SCHEMA = {
      name: 'icodos_pending_signatures',
      title: 'ICODOS Documents Waiting for Signature',
      description: 'Read only. Lists every document out for signature in this account: whose turn it is ' \
                   '(signing order respected), since when, opened or not, reminders sent and the next one, ' \
                   'expiry. Also lists documents completed in the last days with where the signed copy was ' \
                   'filed, or that it was not. Use icodos_get_submission for one document in detail.',
      inputSchema: {
        type: 'object',
        properties: {
          completed_days: {
            type: 'integer',
            description: 'Also list documents completed in this many past days, with their filing state. ' \
                         '0 to 90, default 14.'
          },
          limit: {
            type: 'integer',
            description: 'At most this many pending documents, oldest first. 1 to 100, default 50.'
          }
        }
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }
    }.freeze

    include ::IcodosToolErrors

    InvalidArguments = ::IcodosToolErrors::ToolError

    # rubocop:disable Metrics
    def call
      authorize!(:read, Submission.new(account_id: current_user.account_id))

      unless IcodosGraph.enabled?
        raise InvalidArguments.new('the contract tools are not enabled on this instance', code: 'disabled')
      end

      days = bounded!('completed_days', 14, 0, 90)
      limit = bounded!('limit', 50, 1, 100)
      now = Time.current
      view = IcodosWorkflow::View
      scope = Submission.accessible_by(current_ability).where(account_id: current_user.account_id)
                        .includes(:submitters, :template, :created_by_user)

      open = scope.where(archived_at: nil, completed_at: nil).order(:id).to_a
                  .select { |s| view.status(s) == 'pending' }

      completed = days.zero? ? [] : scope.where('completed_at > ?', now - days * 86_400).order(completed_at: :desc).to_a

      unfiled = completed.count do |s|
        f = view.filing(s)
        f[:folder].present? && !f[:filed]
      end

      render_tool_result(
        as_of: now.utc.iso8601,
        counts: { pending: open.size, completed_in_period: completed.size, completed_not_filed: unfiled },
        pending: open.first(limit).map { |s| view.summary(s, now: now) },
        truncated: open.size > limit ? "#{open.size - limit} more pending; raise limit to see them" : nil,
        completed: completed.map do |s|
          { submission_id: s.id, template: view.template(s), completed_at: s.completed_at.utc.iso8601,
            signers: s.submitters.map(&:name).compact, filing: view.filing(s) }
        end,
        note: 'Times are UTC. waiting_on is whoever must act next; in signing order only one signer is invited ' \
              'at a time. filing.by "server" means the filing hook files it; anything else is filed by the ' \
              'Make scenario or by a person and is not tracked here.'
      )
    end
    # rubocop:enable Metrics

    private

    def bounded!(name, default, min, max)
      raw = mcp_params[name]

      return default if raw.nil?

      value = Integer(raw.to_s, 10)

      raise ArgumentError unless value.between?(min, max)

      value
    rescue ArgumentError, TypeError
      raise InvalidArguments, "#{name} must be a whole number from #{min} to #{max}"
    end
  end
end
