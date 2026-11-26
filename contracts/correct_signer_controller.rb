# frozen_string_literal: true

# ICODOS Phase 5 — MCP tool: correct a signer's address or name before they
# sign.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/mcp/icodos_correct_signer_controller.rb
#
# The case it exists for: a contract went out with a mistyped private
# address, or to the employee's company address. Changing the address alone
# would not be a correction. The signing link is a secret in the URL, and the
# invitation already sent carries it: whoever got that email could still open
# and sign. So when the signer had already been invited, the link is replaced
# (a new slug), the old one stops working, and the invitation goes again to
# the corrected address. A signer not invited yet (waiting for an earlier
# signer) only gets the new address; the invitation goes there when it is
# their turn.
#
# The rules of the send tool hold here too: the first signer stays at a
# company domain, and the email code is on for an address outside the
# company (a correction never switches it off).
module Mcp
  class IcodosCorrectSignerController < McpBaseController
    SCHEMA = {
      name: 'icodos_correct_signer',
      title: 'Correct ICODOS Signer Before Signing',
      description: 'Correct the email address and/or name of one signer of a pending document, before that ' \
                   'signer has signed. If they were already invited, their old signing link stops working and ' \
                   'the invitation is sent again to the corrected address. Two calls: without confirm it returns ' \
                   'a preview and a preview_token and changes nothing; show the preview to the human, and only ' \
                   'after they agree call again with the identical arguments plus confirm true and that ' \
                   'preview_token (valid 15 minutes, once). Never set confirm on your own initiative.',
      inputSchema: {
        type: 'object',
        properties: {
          submission_id: { type: 'integer', description: 'The submission id' },
          role: { type: 'string', description: 'The signer\'s role on the document, as icodos_get_submission shows it' },
          email: { type: 'string', description: 'Optional: the corrected address' },
          name: { type: 'string', description: 'Optional: the corrected full name' },
          confirm: { type: 'boolean', description: 'Must be the boolean true, together with preview_token, to act.' },
          preview_token: { type: 'string', description: 'The preview_token from the preview of exactly these arguments.' }
        },
        required: %w[submission_id role]
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
      }
    }.freeze

    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/.freeze

    include ::IcodosToolErrors
    include ::IcodosWorkflow::ActionTool

    InvalidArguments = ::IcodosToolErrors::ToolError

    # rubocop:disable Metrics
    def call
      submission = load_submission!

      return if replayed?(submission)

      ensure_pending!(submission)

      role = mcp_params['role'].to_s.strip
      roles = IcodosWorkflow::View.roles(submission)
      uuid = roles.find { |_, ts| ts['name'] == role }&.first

      raise InvalidArguments, "role #{role.inspect} is not on this document — it has #{roles.values.map { |r| r['name'] }.inspect}" if uuid.nil?

      @submitter = submission.submitters.find { |s| s.uuid == uuid }

      raise InvalidArguments, "nobody has been named for #{role} on this document" if @submitter.nil?

      if @submitter.completed_at?
        raise InvalidArguments.new("#{@submitter.name} signed at #{@submitter.completed_at.utc.iso8601}; a signature " \
                                   'cannot be redirected. Void the document and send a new one.', code: 'not_pending')
      end

      raise InvalidArguments.new("#{@submitter.name} declined; send a new document.", code: 'not_pending') if @submitter.declined_at?

      @role = role
      @first = IcodosWorkflow::View.ordered_submitters(submission).first == @submitter
      @new_email = mcp_params['email'].to_s.strip.presence
      @new_name = mcp_params['name'].to_s.gsub(/[[:cntrl:]]/, ' ').squeeze(' ').strip.presence

      raise InvalidArguments, 'give email, name or both' if @new_email.nil? && @new_name.nil?
      raise InvalidArguments, "#{@new_email.inspect} is not a valid email address" if @new_email && !@new_email.match?(EMAIL_RE)

      @new_email = nil if @new_email && @new_email.casecmp(@submitter.email.to_s).zero?
      @new_name = nil if @new_name && @new_name == @submitter.name

      raise InvalidArguments, 'nothing to correct: the email and name given are the ones on the document' if @new_email.nil? && @new_name.nil?

      enforce_first_signer_domain! if @first && @new_email

      @email_code = email_code_after

      icodos_action(submission)
    end
    # rubocop:enable Metrics

    private

    def domains
      Mcp::IcodosSendContractController.first_signer_domains
    end

    def enforce_first_signer_domain!
      domain = @new_email.split('@').last.to_s.downcase

      return if domains.include?(domain)

      raise InvalidArguments,
            "#{@role} signs first and countersigns for ICODOS; the address must be at one of #{domains.join(', ')}, " \
            "not #{domain.inspect}."
    end

    # Never switched off by a correction; switched on for an outside address
    # under the default policy, as the send tool would have.
    def email_code_after
      before = @submitter.preferences.to_h['require_email_2fa'] == true

      return before if @new_email.nil?

      case Mcp::IcodosSendContractController.email_code_policy
      when 'all' then true
      when 'off' then before
      else before || !domains.include?(@new_email.split('@').last.to_s.downcase)
      end
    end

    def invited?
      @submitter.sent_at.present?
    end

    def previewed(submission)
      s = @submitter

      {
        'submission_id' => submission.id,
        'submitter' => [s.id, s.uuid, s.email, s.name, s.sent_at&.to_i, s.opened_at&.to_i, s.completed_at&.to_i],
        'new_email' => @new_email,
        'new_name' => @new_name,
        'email_code' => @email_code
      }
    end

    # rubocop:disable Metrics
    def preview_payload(submission)
      s = @submitter
      warnings = []

      if invited? && s.opened_at && @new_email
        warnings << "The document was opened from the link sent to #{s.email} at #{s.opened_at.utc.iso8601}: whoever " \
                    'holds that mailbox has seen it. The link stops working with this correction.'
      end

      unless @first
        first = IcodosWorkflow::View.ordered_submitters(submission).first

        if first && !first.completed_at? && @new_email
          warnings << "The invitation to #{first.name} named #{s.email} as the next signer. Tell them it was corrected."
        end
      end

      effect =
        if @new_email && invited?
          "The link sent to #{s.email} stops working. A new invitation goes now to #{@new_email}; reminders count " \
            'from now.'
        elsif @new_email
          "Nothing is sent now. The invitation goes to #{@new_email} when it is #{@role}'s turn."
        else
          'Only the name on the document changes. Nothing is sent.'
        end

      {
        template: IcodosWorkflow::View.template(submission),
        role: @role,
        before: { name: s.name, email: s.email, status: s.status, invited_at: IcodosWorkflow.iso(s.sent_at),
                  opened_at: IcodosWorkflow.iso(s.opened_at) }.compact,
        after: { name: @new_name || s.name, email: @new_email || s.email, email_code: @email_code },
        effect: effect,
        warnings: warnings.presence
      }.compact
    end
    # rubocop:enable Metrics

    # rubocop:disable Metrics
    def apply!(submission)
      s = @submitter
      before = { 'email' => s.email, 'name' => s.name, 'opened_at' => IcodosWorkflow.iso(s.opened_at) }
      resend = @new_email.present? && invited?

      s.email = @new_email if @new_email
      s.name = @new_name if @new_name
      s.preferences = s.preferences.to_h.merge('require_email_2fa' => @email_code)

      if resend
        # The old link is the secret in the email already sent. A new slug
        # makes it lead nowhere; the new invitation carries the new one.
        s.slug = SecureRandom.base58(14)
        s.opened_at = nil
        s.sent_at = Time.current
      end

      s.save!
      @icodos_done = "signer #{@role} of submission #{submission.id} corrected; do not correct it again"

      Submitters.send_signature_requests([s]) if resend

      begin
        SearchEntries.enqueue_reindex(s)
      rescue StandardError
        nil
      end

      changed = [(@new_email ? "email #{before['email']} -> #{@new_email}" : nil),
                 (@new_name ? "name #{before['name']} -> #{@new_name}" : nil)].compact.join(', ')

      { action: 'correct',
        summary: "#{@role}: #{changed}#{resend ? '; old link revoked, invitation sent again' : ''}",
        result: { role: @role, email: s.email, name: s.name, email_code: @email_code,
                  invitation_sent_again: resend, old_link_revoked: resend,
                  previously: before.compact } }
    end
    # rubocop:enable Metrics
  end
end
