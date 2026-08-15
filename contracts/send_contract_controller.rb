# frozen_string_literal: true

# ICODOS Phase E — MCP tool: send a contract template for signature.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/mcp/icodos_send_contract_controller.rb
#
# THIS IS THE IRREVERSIBLE STEP. It emails a real person, usually at a private
# address, about their own employment. Two properties follow from that:
#
#   1. It is a SEPARATE tool from template creation, so preparing a contract
#      can never send one as a side effect.
#   2. It does nothing unless confirm is true. Without it the tool returns a
#      preview — who would receive what, in which order — and sends nothing.
#      That gives the human an actual decision to make rather than a tool call
#      to notice after the fact.
#
# WHY NOT upstream send_documents
# It has no signing-order parameter and falls back to the template preference,
# defaulting to 'random' when unset — which is the case for every template on
# this instance created before Phase E. Employer-first is a hard requirement
# here, so this hardcodes 'preserved' and lets the TEMPLATE's role order decide
# who signs first (Submissions.send_signature_requests reads template_submitters,
# not the array passed in). It also carries the filing folder onto the
# submission, which is what lets the signed PDF be filed without parsing names.

module Mcp
  class IcodosSendContractController < McpBaseController
    SCHEMA = {
      name: 'icodos_send_contract',
      title: 'Send ICODOS Contract for Signature',
      description: 'Send a prepared contract template for signature, employer first. IRREVERSIBLE: it emails ' \
                   'the employee. Call with confirm omitted or false to get a preview of exactly what would ' \
                   'be sent, show that to the human, and only call again with confirm true once they have ' \
                   'agreed. Never set confirm true on your own initiative.',
      inputSchema: {
        type: 'object',
        properties: {
          template_id: {
            type: 'integer',
            description: 'Template id returned by icodos_create_contract_template'
          },
          submitters: {
            type: 'array',
            description: 'One entry per signing role on the template. Signing order comes from the template, ' \
                         'not from this array.',
            items: {
              type: 'object',
              properties: {
                role: { type: 'string', description: 'Must match a role on the template' },
                name: { type: 'string', description: 'Full legal name of the signer' },
                email: {
                  type: 'string',
                  description: 'For employees this is their PRIVATE address, so the record outlives their ' \
                               'ICODOS account'
                }
              },
              required: %w[role name email]
            }
          },
          expire_at: {
            type: 'string',
            description: 'Optional expiry, ISO 8601 date or datetime'
          },
          message: {
            type: 'object',
            description: 'Optional email subject and body',
            properties: {
              subject: { type: 'string' },
              body: { type: 'string' }
            }
          },
          filing_folder: {
            type: 'string',
            description: 'Optional override for where the signed PDF is filed. Defaults to the folder recorded ' \
                         'on the template at creation time, which is almost always what you want.'
          },
          confirm: {
            type: 'boolean',
            description: 'Must be true to actually send. Anything else returns a preview and sends nothing.'
          }
        },
        required: %w[template_id submitters]
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    }.freeze

    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    FILING_FOLDER_KEY = 'icodos_filing_folder'

    # The first signer is structurally the employer — the template's role order
    # decides who signs first, and for ICODOS employment documents that is
    # always the company. Constraining that address is the cheapest defence
    # against the worst thing this tool could be talked into: an instruction
    # smuggled through a Notion page or an email that sends a fabricated
    # contract with BOTH roles pointed at addresses the attacker controls,
    # producing a document that appears to be countersigned by ICODOS.
    #
    # Override with ICODOS_CONTRACTS_FIRST_SIGNER_DOMAINS (comma-separated) if
    # an entity outside these domains ever has to countersign — the Spanish SPV,
    # for instance. The error message says so when it fires.
    DEFAULT_FIRST_SIGNER_DOMAINS = %w[icodos.com icodos.de].freeze

    class InvalidArguments < StandardError; end

    # rubocop:disable Metrics
    def call
      return render_tool_error('Phase E is not enabled on this instance') unless IcodosGraph.enabled?

      @template = Template.accessible_by(current_ability).find(mcp_params['template_id'])

      authorize!(:read, @template)

      raise InvalidArguments, 'template has been archived' if @template.archived_at?
      raise InvalidArguments, 'template has no fields — nothing to sign' if @template.fields.blank?

      authorize!(:create, Submission.new(template: @template, account_id: current_user.account_id))

      ordered = match_submitters!(Array.wrap(mcp_params['submitters']))
      filing_folder = resolve_filing_folder!

      expire_at = parse_expire_at!(mcp_params['expire_at'])

      # Preview path — no side effects whatsoever.
      unless ActiveModel::Type::Boolean.new.cast(mcp_params['confirm'])
        return render_tool_result(
          sent: false,
          preview: true,
          template: { id: @template.id, name: @template.name },
          signing_order: ordered.map { |s| { role: s['role'], name: s['name'], email: s['email'] } },
          first_invitation_to: ordered.first['email'],
          remaining_notified_after: ordered.first['role'],
          filing_folder: filing_folder,
          expire_at: expire_at&.iso8601,
          note: 'Nothing has been sent. Show this to the requester and call again with confirm true if they agree.'
        )
      end

      submissions = Submissions.create_from_submitters(
        template: @template,
        user: current_user,
        source: :mcp,
        # Hardcoded, not read from template.preferences. Upstream falls back to
        # 'random' when the preference is unset, which silently emails the
        # employee before the employer has signed.
        submitters_order: 'preserved',
        submissions_attrs: { submitters: ordered },
        # ordered appears in BOTH places, as upstream does it: submissions_attrs
        # builds the records, params drives per-submitter delivery.
        params: build_params(expire_at).merge('submitters' => ordered)
      )

      raise InvalidArguments, 'no valid submitters' if submissions.blank?

      # Guard against the silent failure this tool hit during development: the
      # submission is created, the order is right, and every submitter has a
      # blank email, so nothing is ever delivered and nothing reports an error.
      # An inert submission looks sent, which is the worst of both.
      blank = submissions.flat_map(&:submitters).select { |s| s.email.blank? }

      if blank.any?
        submissions.each(&:destroy!)

        raise InvalidArguments,
              "#{blank.length} submitter record(s) came back without an email address; the submission was " \
              'discarded rather than left undeliverable. This indicates a DocuSeal API change — check that ' \
              'submitter attributes still reach Submissions::CreateFromSubmitters.'
      end

      # Carried onto the submission so the filing hook needs neither the
      # template nor any parsing of its name to know where the signed PDF goes.
      submissions.each do |submission|
        submission.update!(preferences: (submission.preferences || {}).merge(FILING_FOLDER_KEY => filing_folder))
      end

      WebhookUrls.enqueue_events(submissions, 'submission.created')
      Submissions.send_signature_requests(submissions)

      submission = submissions.first

      Rails.logger.info("[icodos-contracts] sent submission=#{submission.id} template=#{@template.id} " \
                        "order=preserved filing=#{filing_folder.inspect}")

      render_tool_result(
        sent: true,
        submission_id: submission.id,
        template: { id: @template.id, name: @template.name },
        signing_order: submission.submitters.map { |s| { name: s.name, email: s.email, status: s.status } },
        filing_folder: filing_folder,
        expire_at: submission.expire_at&.iso8601
      )
    rescue InvalidArguments, IcodosGraph::PathError => e
      render_tool_error(e.message)
    rescue IcodosGraph::Error => e
      Rails.logger.error("[icodos-contracts] send_contract: #{e.class} #{e.message}")
      render_tool_error("SharePoint: #{e.message}")
    end
    # rubocop:enable Metrics

    private

    # Returns submitters ordered to match the TEMPLATE's roles. The order of the
    # incoming array is deliberately ignored: employer-first is a property of
    # the template, not of however the caller happened to list people.
    def match_submitters!(raw)
      raise InvalidArguments, 'submitters is required' if raw.empty?

      template_roles = @template.submitters.map { |s| s['name'] }

      supplied = raw.map do |entry|
        role = entry['role'].to_s.strip
        name = entry['name'].to_s.strip
        email = entry['email'].to_s.strip

        raise InvalidArguments, 'each submitter needs a role' if role.blank?
        raise InvalidArguments, "#{role}: name is required" if name.blank?
        raise InvalidArguments, "#{role}: #{email.inspect} is not a valid email address" unless email.match?(EMAIL_RE)

        unless template_roles.include?(role)
          raise InvalidArguments, "role #{role.inspect} is not on this template — expected #{template_roles.inspect}"
        end

        # with_indifferent_access is NOT cosmetic. Submissions::CreateFromSubmitters
        # reads these with symbol keys, so a plain string-keyed hash produces
        # submitter records with a blank name and email — created successfully,
        # ordered correctly, and never emailed, because there is no address to
        # send to. Upstream send_documents does the same conversion.
        { 'role' => role, 'name' => name, 'email' => email }.with_indifferent_access
      end

      duplicates = supplied.map { |s| s['role'] }.tally.select { |_, count| count > 1 }.keys

      raise InvalidArguments, "more than one submitter for #{duplicates.join(', ')}" if duplicates.any?

      missing = template_roles - supplied.map { |s| s['role'] }

      raise InvalidArguments, "no submitter given for #{missing.join(', ')}" if missing.any?

      ordered = template_roles.map { |role| supplied.find { |s| s['role'] == role } }

      enforce_first_signer_domain!(ordered.first)

      ordered
    end

    def enforce_first_signer_domain!(first)
      domains = first_signer_domains

      return if domains.empty?

      domain = first['email'].to_s.split('@').last.to_s.downcase

      return if domains.include?(domain)

      raise InvalidArguments,
            "the first signer (#{first['role']}) must be at one of #{domains.join(', ')} — got #{domain.inspect}. " \
            'The first signer countersigns on behalf of ICODOS. If an entity outside these domains genuinely ' \
            'has to sign first, add its domain to ICODOS_CONTRACTS_FIRST_SIGNER_DOMAINS on the server.'
    end

    def first_signer_domains
      raw = ENV['ICODOS_CONTRACTS_FIRST_SIGNER_DOMAINS'].to_s.strip

      return DEFAULT_FIRST_SIGNER_DOMAINS if raw.empty?

      raw.split(',').map { |d| d.strip.downcase.delete_prefix('@') }.reject(&:empty?)
    end

    # A contract that cannot be filed once signed is worse than one that is not
    # sent, so this fails now rather than at completion.
    def resolve_filing_folder!
      raw = mcp_params['filing_folder'].presence || @template.preferences.to_h[FILING_FOLDER_KEY]

      if raw.blank?
        raise InvalidArguments,
              'no filing folder on this template and none supplied — the signed PDF would have nowhere to go. ' \
              'Templates made with icodos_create_contract_template carry one automatically.'
      end

      folder = IcodosGraph.normalize_path!(raw)

      raise InvalidArguments, "filing folder no longer exists in SharePoint: #{folder}" unless IcodosGraph.exists?(folder)

      folder
    end

    def parse_expire_at!(raw)
      return nil if raw.blank?

      Time.zone.parse(raw.to_s) || raise(InvalidArguments, "expire_at #{raw.inspect} is not a date I can read")
    rescue ArgumentError
      raise InvalidArguments, "expire_at #{raw.inspect} is not a date I can read"
    end

    def build_params(expire_at)
      params = { 'send_email' => true }
      params['expire_at'] = expire_at if expire_at

      message = mcp_params['message']

      if message.is_a?(Hash) && (message['subject'].present? || message['body'].present?)
        params['message'] = message.slice('subject', 'body')
      end

      params
    end
  end
end
