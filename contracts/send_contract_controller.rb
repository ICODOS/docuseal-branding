# frozen_string_literal: true

# ICODOS Phase E — MCP tool: send a contract template for signature.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/mcp/icodos_send_contract_controller.rb
#
# THIS IS THE IRREVERSIBLE STEP. It emails a real person, usually at a private
# address, about their own employment. Three properties follow from that:
#
#   1. It is a SEPARATE tool from template creation, so preparing a contract
#      can never send one as a side effect.
#   2. Without confirm it returns a preview: who receives what, in which
#      order, with which message, filed where, and a preview_token. Nothing is
#      sent.
#   3. It sends only with confirm true AND the preview_token of a preview of
#      exactly the same arguments, within 15 minutes, once. A confirmation is
#      therefore bound to what a human was shown, not to whatever the second
#      call happens to carry.
#
# And the ICODOS signer, who signs first, is told in the invitation who the
# document goes to next and where the signed copy is filed, so the one person
# who sees the contract before the employee does can stop a wrong address.
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
                   'the signers. Two calls. First call without confirm: returns a preview of exactly what ' \
                   'would be sent (signers in order, each signer\'s email subject and text, filing folder, ' \
                   'expiry, email code) and a preview_token. Show ALL of it to the human, the email texts ' \
                   'included. Only after they agree, call again with the identical arguments plus confirm true ' \
                   'and that preview_token. The token is valid for 15 minutes and works once; any changed ' \
                   'argument needs a new preview. Never set confirm on your own initiative. Fixed-term ' \
                   'employment documents (working student, internship, thesis, fixed-term contracts, amendments ' \
                   'that set or extend an end date) are refused for now; they are signed on paper.',
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
          fixed_term: {
            type: 'boolean',
            description: 'Required. true if the document sets, extends or changes an end date of an employment ' \
                         '(fixed-term contract, working student, internship or thesis agreement, an amendment ' \
                         'that sets or extends an end date); false otherwise. true is refused for now.'
          },
          expire_at: {
            type: 'string',
            description: 'Optional expiry. ISO 8601 datetime, or a date (YYYY-MM-DD), which means the end of ' \
                         'that day in the account time zone. Must be at least one hour ahead. Signing is no ' \
                         'longer possible after it.'
          },
          message: {
            type: 'object',
            description: 'Optional email subject and body for every signer. Without it the template and ' \
                         'account defaults are used. The preview shows the resulting text per signer.',
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
          require_email_code: {
            type: 'boolean',
            description: 'Optional. true: every signer must enter a code sent to their email address before ' \
                         'the document opens; false: nobody. Leave it out for the server default (a code for ' \
                         'addresses outside the company). The preview shows the value per signer.'
          },
          confirm: {
            type: 'boolean',
            description: 'Must be the boolean true, together with preview_token, to actually send. Anything ' \
                         'else returns a preview and sends nothing.'
          },
          preview_token: {
            type: 'string',
            description: 'The preview_token from the preview of exactly these arguments. Required with ' \
                         'confirm true.'
          }
        },
        required: %w[template_id submitters fixed_term]
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    }.freeze

    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/.freeze
    FILING_FOLDER_KEY = 'icodos_filing_folder'
    SOURCE_PATH_KEY = 'icodos_source_path'
    PREVIEW_NONCE_KEY = 'icodos_preview_nonce'
    DATE_ONLY_RE = /\A\d{4}-\d{2}-\d{2}\z/.freeze
    MIN_EXPIRY = 3600

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

    # Fixed-term employment documents are signed on paper for now, by
    # company decision, not through this instance. Two lines: the caller must
    # declare fixed_term, and the names on the template are checked for the
    # document classes that are fixed-term here (working student, intern,
    # thesis, extensions). The second line does not trust the first.
    # "unbefristet" (permanent) is not a match.
    # ICODOS_CONTRACTS_FIXED_TERM_GUARD=off lifts it, on the server only.
    FIXED_TERM_PATTERN = /
      werk\s*student | working[\s-]*student | praktik | \bintern(ship)?s?\b |
      \bthesis\b | abschlussarbeit | masterarbeit | bachelorarbeit |
      (?<!un)befrist | fixed[\s-]*term | time[\s-]*limit(ed|ation)? |
      verl(ä|ae)ngerung | \bextension\b
    /xi.freeze

    FIXED_TERM_REFUSAL =
      'Fixed-term employment documents (working student, internship, thesis, fixed-term contracts, amendments ' \
      'that set or extend an end date) are signed on paper for now, not through this instance. Nothing was sent.'

    # Used for the first signer only, when neither the call, the template nor
    # the account settings provide an invitation text to add the note to.
    FALLBACK_BODY = "Hello {submitter.first_name},\n\n" \
                    "You have been invited to sign \"{template.name}\":\n\n" \
                    "{submitter.link}\n\n" \
                    "If you have any questions, reply to this email.\n\n" \
                    "Thanks,  \n{account.name}"

    # Errors answer as structured tool errors (IcodosToolErrors, finding T5).
    # InvalidArguments keeps its name for the offline selftests; its code
    # defaults to invalid_arguments.
    include ::IcodosToolErrors

    InvalidArguments = ::IcodosToolErrors::ToolError

    # A confirmation is valid only for what was previewed. The token is
    #
    #   pv1.<expiry, unix seconds>.<nonce, 32 hex>.<HMAC-SHA256, 64 hex>
    #
    # and the HMAC covers the user and a digest of everything the preview
    # showed: template and its content, signers in order, each signer's email
    # subject and text, filing folder, expiry, email code. The confirming call
    # recomputes that digest from its own arguments, so a token cannot carry a
    # changed address, message or folder across. Single use: the nonce is
    # recorded in Redis with SET NX before anything is sent, and on the
    # submission, which survives a Redis that lost its last minutes.
    #
    # Plain Ruby, no Rails: contracts/send_selftest.rb runs it offline.
    module PreviewToken
      VERSION = 'pv1'
      TTL = 15 * 60
      FORMAT = /\Apv1\.(\d{10})\.(\h{32})\.(\h{64})\z/.freeze

      module_function

      # Hash keys sorted at every level, so the digest does not depend on the
      # order in which a caller or this code happened to build the hash.
      def canonical(value)
        case value
        when Hash then value.map { |k, v| [k.to_s, canonical(v)] }.sort_by(&:first)
        when Array then value.map { |v| canonical(v) }
        else value
        end
      end

      def digest(content)
        OpenSSL::Digest::SHA256.hexdigest(JSON.generate(canonical(content)))
      end

      def mac(key, user_id, exp, nonce, digest)
        OpenSSL::HMAC.hexdigest('SHA256', key, [VERSION, user_id.to_i, exp.to_i, nonce, digest].join('|'))
      end

      def issue(key, user_id, digest, now: Time.now.to_i, nonce: SecureRandom.hex(16))
        exp = now.to_i + TTL

        [VERSION, exp, nonce, mac(key, user_id, exp, nonce, digest)].join('.')
      end

      # { status: :ok, nonce:, exp: } or { status: :malformed | :mismatch | :expired }.
      # The MAC is checked before the expiry, so an expired token with
      # different arguments reports the difference, which is the more useful
      # of the two.
      def verify(token, key, user_id, digest, now: Time.now.to_i)
        match = FORMAT.match(token.to_s)

        return { status: :malformed } unless match

        exp = match[1].to_i
        nonce = match[2]

        return { status: :mismatch } unless secure_compare(mac(key, user_id, exp, nonce, digest), match[3])
        return { status: :expired, exp: exp } if now.to_i > exp

        { status: :ok, nonce: nonce, exp: exp }
      end

      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        bytes = left.bytes
        diff = 0
        right.bytes.each_with_index { |byte, i| diff |= byte ^ bytes[i] }
        diff.zero?
      end
    end

    # rubocop:disable Metrics
    def call
      @template = Template.accessible_by(current_ability).find(mcp_params['template_id'])

      authorize!(:read, @template)

      # After authorize!, never before it: an early render ahead of authorize!
      # trips McpBaseController's check_authorization and becomes a bare 500.
      # See IcodosCreateContractTemplateController#call, where it did.
      unless IcodosGraph.enabled?
        raise InvalidArguments.new('the contract tools are not enabled on this instance', code: 'disabled')
      end

      raise InvalidArguments.new('template has been archived', code: 'template_archived') if @template.archived_at?

      ensure_original_contract_template!
      raise InvalidArguments, 'template has no fields — nothing to sign' if @template.fields.blank?

      # Same refusal as upstream send_documents since 3.4.0.
      raise InvalidArguments, 'templates with variables are not supported' if @template.variables_schema.present?

      ensure_not_fixed_term!
      ensure_first_role_signs!

      authorize!(:create, Submission.new(template: @template, account_id: current_user.account_id))

      ordered = match_submitters!(Array.wrap(mcp_params['submitters']))
      filing_folder = resolve_filing_folder!
      expire_at = parse_expire_at!(mcp_params['expire_at'])
      email_code = resolve_email_codes!(ordered)
      messages = build_messages(ordered, filing_folder, expire_at)

      digest = PreviewToken.digest(previewed_content(ordered, filing_folder, expire_at, email_code, messages))

      # Preview path — no side effects whatsoever.
      #
      # Exactly the JSON boolean true sends, and only with the token of a
      # preview of these same arguments. confirm used to be a Rails boolean
      # cast ("False", "no" and 2 all sent), and later a bare `== true` that
      # the very first call could carry, with arguments nobody had seen.
      unless mcp_params['confirm'] == true
        return render_preview(ordered, filing_folder, expire_at, email_code, messages, digest)
      end

      nonce, prior = accept_preview_token!(digest)

      # The same confirmed call again, typically after a client timeout: the
      # answer is the send that already happened, not a second one and not an
      # error the agent might "fix" by making a new preview (finding T6).
      return render_sent(prior, filing_folder, replayed: true) if prior

      submissions = nil

      # Until the signature requests go out, a failure leaves nothing behind:
      # the half-made submission is removed and the preview_token released,
      # so the same confirmed call can simply be repeated.
      begin
        submissions = Submissions.create_from_submitters(
          template: @template,
          user: current_user,
          source: :mcp,
          # Hardcoded, not read from template.preferences. Upstream falls back
          # to 'random' when the preference is unset, which silently emails the
          # employee before the employer has signed.
          submitters_order: 'preserved',
          # expire_at belongs HERE. Upstream reads it from the submission
          # attributes only; passed in params, as it was until November 2026,
          # it was echoed by the preview and silently dropped, and the
          # account's invitation text "Could you sign by
          # {submission.expire_at}?" went out with a blank date.
          submissions_attrs: { submitters: submitter_attrs(ordered, messages, email_code), expire_at: expire_at },
          # Both places, as upstream does it: submissions_attrs builds the
          # records, params drives per-submitter delivery.
          params: { 'send_email' => true, 'submitters' => submitter_attrs(ordered, messages, email_code) }
        )

        raise InvalidArguments.new('no valid submitters', code: 'submission_failed') if submissions.blank?

        # Guard against the silent failure this tool hit during development:
        # the submission is created, the order is right, and every submitter
        # has a blank email, so nothing is ever delivered and nothing reports
        # an error. An inert submission looks sent, which is the worst of both.
        blank = submissions.flat_map(&:submitters).select { |s| s.email.blank? }

        if blank.any?
          raise InvalidArguments.new(
            "#{blank.length} submitter record(s) came back without an email address; the submission was " \
            'discarded rather than left undeliverable. This indicates a DocuSeal API change: check that ' \
            'submitter attributes still reach Submissions::CreateFromSubmitters.',
            code: 'submission_failed'
          )
        end

        # Carried onto the submission so the filing hook needs neither the
        # template nor any parsing of its name to know where the signed PDF
        # goes. The preview nonce makes the single use survive a Redis restart.
        submissions.each do |submission|
          submission.update!(preferences: (submission.preferences || {}).merge(FILING_FOLDER_KEY => filing_folder,
                                                                               PREVIEW_NONCE_KEY => nonce))
        end

        WebhookUrls.enqueue_events(submissions, 'submission.created')
      rescue StandardError
        discard_unsent!(submissions, nonce)
        raise
      end

      submission = submissions.first

      # From here on the invitations are on their way. Whatever fails after
      # this line, the agent is told so and must not send again.
      @icodos_done = "sent: submission #{submission.id}; it must not be sent again"
      Submissions.send_signature_requests(submissions)
      record_sent!(nonce, submission)

      Rails.logger.info("[icodos-contracts] sent submission=#{submission.id} template=#{@template.id} " \
                        "order=preserved filing=#{filing_folder.inspect} preview=#{nonce[0, 8]} " \
                        "email_code=#{email_code.join(',')} expire_at=#{expire_at&.iso8601 || 'none'}")

      render_sent(submission, filing_folder)
    end
    # rubocop:enable Metrics

    private

    def render_sent(submission, filing_folder, replayed: false)
      result = {
        sent: true,
        submission_id: submission.id,
        template: { id: @template.id, name: @template.name },
        signing_order: submission.submitters.map do |s|
          { name: s.name, email: s.email, status: s.status, email_code: s.preferences['require_email_2fa'] == true }
        end,
        filing_folder: submission.preferences.to_h[FILING_FOLDER_KEY] || filing_folder,
        expire_at: submission.expire_at&.iso8601
      }

      if replayed
        Rails.logger.info("[icodos-contracts] replayed submission=#{submission.id} template=#{@template.id} " \
                          "user_id=#{current_user.id}")

        result[:replayed] = true
        result[:note] = "This preview_token was already used at #{submission.created_at.utc.iso8601}; this is " \
                        'that send. Nothing was sent again. If a second copy really is wanted, make a new ' \
                        'preview and show it to the requester.'
      end

      render_tool_result(result)
    end

    # Undo a send that failed before any invitation went out: remove what was
    # created and release the preview_token, so the identical confirmed call
    # can be repeated. If even that fails, the error says so.
    def discard_unsent!(submissions, nonce)
      Array.wrap(submissions).each { |s| s.destroy! if s.persisted? }
      ::Sidekiq.redis { |c| c.call('DEL', preview_redis_key(nonce)) }

      @icodos_done = 'nothing (the preview_token may be used again)'
    rescue StandardError => e
      Rails.logger.error("[icodos-contracts] send_contract: could not discard an unsent submission " \
                         "(#{e.class}: #{e.message}) template=#{@template.id}")

      @icodos_done = "unknown: a submission of template #{@template.id} may exist without having been sent. " \
                     'Check the template in the web interface before sending again.'
    end

    # The used token now points at its submission, for a repeated call.
    def record_sent!(nonce, submission)
      ::Sidekiq.redis do |c|
        c.call('SET', preview_redis_key(nonce), "submission:#{submission.id}", 'XX', 'KEEPTTL')
      end
    rescue StandardError => e
      # The nonce on the submission still makes a repeat a replay.
      Rails.logger.error("[icodos-contracts] send_contract: could not record the send against its preview " \
                         "(#{e.class}: #{e.message}) submission=#{submission.id}")
    end

    def preview_redis_key(nonce)
      "icodos:send_contract:preview:#{nonce}"
    end

    def render_preview(ordered, filing_folder, expire_at, email_code, messages, digest)
      token = PreviewToken.issue(preview_key, current_user.id, digest)
      expires = Time.at(token.split('.')[1].to_i).utc

      Rails.logger.info("[icodos-contracts] preview template=#{@template.id} user_id=#{current_user.id} " \
                        "preview=#{token.split('.')[2][0, 8]}")

      render_tool_result(
        sent: false,
        preview: true,
        template: { id: @template.id, name: @template.name },
        documents: Array.wrap(@template.schema).map { |item| item['name'] },
        signing_order: ordered.each_with_index.map do |s, i|
          { order: i + 1, role: s['role'], name: s['name'], email: s['email'], email_code: email_code[i] }
        end,
        first_invitation_to: ordered.first['email'],
        remaining_notified_after: ordered.first['role'],
        filing_folder: filing_folder,
        expire_at: expire_at&.iso8601,
        template_default_expiry: expire_at ? nil : template_expiry_default['default_expire_at_duration'],
        emails: messages.map do |m|
          { to: m['email'], role: m['role'], source: m['source'],
            subject: m['subject'] || '(DocuSeal standard subject)', body: m['body'] || '(DocuSeal standard text)' }
        end,
        preview_token: token,
        preview_token_expires_at: expires.iso8601,
        note: 'Nothing has been sent. Show the requester all of the above, the email texts included ({...} ' \
              'placeholders are filled in per signer when sent). If they agree, call again with exactly the ' \
              'same arguments plus confirm true and this preview_token, before preview_token_expires_at. ' \
              'The token works once.'
      )
    end

    # Everything the preview shows, nothing it does not. Template content is
    # bound too: a template edited between preview and send needs a new
    # preview, because the document itself is part of what was agreed.
    def previewed_content(ordered, filing_folder, expire_at, email_code, messages)
      {
        'template_id' => @template.id,
        'template_content' => template_fingerprint,
        'signers' => ordered.map { |s| [s['role'], s['name'], s['email']] },
        'filing_folder' => filing_folder,
        'expire_at' => expire_at&.utc&.iso8601,
        'email_code' => email_code,
        'emails' => messages.map { |m| [m['role'], m['subject'], m['body']] }
      }
    end

    def template_fingerprint
      documents = @template.documents.map { |d| [d.try(:uuid).to_s, d.blob&.checksum.to_s] }

      PreviewToken.digest('submitters' => @template.submitters, 'fields' => @template.fields,
                          'schema' => @template.schema, 'documents' => documents,
                          'expiry_default' => template_expiry_default)
    end

    # Applies when the call gives no expire_at (Templates.build_default_expire_at).
    # Bound as the setting, not as a time, which would differ between calls.
    def template_expiry_default
      @template.preferences.to_h.slice('default_expire_at_duration', 'default_expire_at').compact
    end

    def preview_key
      Rails.application.key_generator.generate_key('icodos send_contract preview token v1', 32)
    end

    # Returns [nonce, nil] once the token is proven to belong to this preview
    # and has been recorded as used, or [nonce, submission] when it was
    # already used and that send is found. Raises otherwise; nothing has been
    # sent then.
    # rubocop:disable Metrics
    def accept_preview_token!(digest)
      token = mcp_params['preview_token']
      new_preview = 'Make a new preview and show it to the requester.'

      if token.blank?
        raise InvalidArguments.new(
          'confirm true needs the preview_token from a preview of exactly these arguments. Nothing was sent.',
          code: 'preview_required',
          hint: 'Call without confirm first, show the preview to the requester, then confirm with its preview_token.'
        )
      end

      result = PreviewToken.verify(token, preview_key, current_user.id, digest)

      case result[:status]
      when :malformed
        raise InvalidArguments.new('preview_token is not a token this tool issued. Nothing was sent.',
                                   code: 'preview_invalid', hint: new_preview)
      when :mismatch
        raise InvalidArguments.new(
          'preview_token does not match these arguments: something differs from what was previewed (a signer, ' \
          'an address, the message, the filing folder, the expiry, the email code or the template itself), or ' \
          'the token belongs to another preview or user. Nothing was sent.',
          code: 'preview_mismatch', hint: new_preview
        )
      when :expired
        raise InvalidArguments.new(
          "preview_token expired at #{Time.at(result[:exp]).utc.iso8601} (valid 15 minutes). Nothing was sent.",
          code: 'preview_expired', hint: new_preview
        )
      end

      [result[:nonce], burn_preview_nonce!(result[:nonce], result[:exp])]
    end
    # rubocop:enable Metrics

    # nil when this call may send; the earlier submission when the token was
    # used before. Raises while another call with the same token is still
    # sending, and when Redis cannot be asked.
    def burn_preview_nonce!(nonce, exp)
      ttl = [exp - Time.now.to_i, 0].max + 300
      key = preview_redis_key(nonce)

      stored, value =
        begin
          ::Sidekiq.redis do |c|
            set = c.call('SET', key, "pending:#{current_user.id}", 'NX', 'EX', ttl)
            [set, set == 'OK' ? nil : c.call('GET', key)]
          end
        rescue StandardError => e
          Rails.logger.error("[icodos-contracts] send_contract: preview store unreachable (#{e.class}: #{e.message})")

          raise InvalidArguments.new('the record of used preview tokens (Redis) is not reachable, so nothing was sent.',
                                     code: 'store_unreachable', retryable: true,
                                     hint: 'Retry the same call, with the same preview_token, in a minute.')
        end

      prior = sent_with(nonce, exp, value)

      if stored == 'OK'
        # A Redis that lost its last minutes forgets a used token; the
        # submission does not. Point the record at it again and replay.
        ::Sidekiq.redis { |c| c.call('SET', key, "submission:#{prior.id}", 'XX', 'KEEPTTL') } if prior

        return prior
      end

      return prior if prior

      raise InvalidArguments.new(
        'another call with this preview_token is sending right now. Nothing was sent by this call.',
        code: 'in_progress', retryable: true,
        hint: 'Wait half a minute and repeat the same call; it then answers with that send. If it still says ' \
              'this after two minutes, look at the template\'s submissions in the web interface before making ' \
              'a new preview.'
      )
    end

    def sent_with(nonce, exp, value)
      id = value.to_s[/\Asubmission:(\d+)\z/, 1]
      scope = Submission.where(account_id: current_user.account_id, template_id: @template.id)

      (id && scope.find_by(id: id)) ||
        scope.where('created_at > ?', Time.at(exp) - PreviewToken::TTL - 600)
             .where('preferences LIKE ?', "%#{nonce}%")
             .order(:id).first
    end

    # Only an original template made by icodos_create_contract_template.
    # A template made in the web interface, or a copy of a contract template,
    # carries a filing folder and file name that belong to another document:
    # sent from here, its signed copy went into the first employee's folder
    # under the first employee's file name, and, the copy having lost the
    # marker that keeps Make away, was filed by Make a second time.
    def ensure_original_contract_template!
      marker = Icodos::FilingHookController::MARKER
      original = Icodos::FilingHookController::Filing.copy_of(@template)

      if @template.external_id != marker
        raise InvalidArguments.new(
          "template #{@template.id} was not made by icodos_create_contract_template (it was made in the web " \
          'interface, or it is a copy of one). Its filing folder and file name may belong to another document.',
          code: 'template_not_original', hint: 'Create the template with icodos_create_contract_template.'
        )
      end

      return unless original

      raise InvalidArguments.new(
        "template #{@template.id} is a copy of template #{original}, and its filing folder and file name belong " \
        'to that one.',
        code: 'template_not_original', hint: 'Create a new template with icodos_create_contract_template.'
      )
    end

    def ensure_not_fixed_term!
      return if ENV['ICODOS_CONTRACTS_FIXED_TERM_GUARD'].to_s.strip.casecmp('off').zero?

      declared = mcp_params['fixed_term']

      unless [true, false].include?(declared)
        raise InvalidArguments,
              'fixed_term is required, as the boolean true or false: does this document set, extend or change ' \
              'an end date of an employment (fixed-term contract, working student, internship or thesis ' \
              'agreement, an amendment that sets or extends an end date)? Read the document to answer it.'
      end

      raise InvalidArguments.new(FIXED_TERM_REFUSAL, code: 'fixed_term_refused') if declared == true

      hit = fixed_term_hit

      return unless hit

      raise InvalidArguments.new(
        "#{FIXED_TERM_REFUSAL} (The template looks fixed-term: #{hit[:where]} contains #{hit[:match].inspect}.)",
        code: 'fixed_term_refused', hint: 'If that is wrong, the guard can only be lifted on the server.'
      )
    end

    def fixed_term_hit
      source = @template.preferences.to_h[SOURCE_PATH_KEY].to_s

      corpus = [['the template name', @template.name.to_s],
                ['the source file name', File.basename(source)]]
      corpus += Array.wrap(@template.schema).map { |item| ['a document name', item['name'].to_s] }
      corpus += Array.wrap(@template.submitters).map { |item| ['a role name', item['name'].to_s] }

      corpus.each do |where, text|
        match = text.unicode_normalize(:nfc).match(FIXED_TERM_PATTERN)

        return { where: where, match: match[0] } if match
      end

      nil
    end

    # Per signer, in signing order: whether the signing page asks for a code
    # mailed to the signer's address before the document opens (upstream's
    # require_email_2fa, plan step 4.2). A call may say true (everyone) or
    # false (nobody). Otherwise ICODOS_CONTRACTS_EMAIL_CODE decides:
    #
    #   external (default)  addresses outside the company domains, which are
    #                       the employees' private addresses. Staff mailboxes
    #                       sit behind Microsoft sign-in with MFA already, so a
    #                       code to the same mailbox adds little, and monthly
    #                       time declarations between staff stay as they were.
    #   all                 every signer
    #   off                 nobody
    #
    # Decided by David on 26 November 2026 (D14). The company domains are the
    # first-signer domains.
    def resolve_email_codes!(ordered)
      value = mcp_params['require_email_code']

      return ordered.map { value } if [true, false].include?(value)
      raise InvalidArguments, 'require_email_code must be the boolean true or false' unless value.nil?

      case self.class.email_code_policy
      when 'all' then ordered.map { true }
      when 'off' then ordered.map { false }
      else
        domains = first_signer_domains

        ordered.map { |s| !domains.include?(s['email'].to_s.split('@').last.to_s.downcase) }
      end
    end

    def self.email_code_policy
      value = ENV.fetch('ICODOS_CONTRACTS_EMAIL_CODE', 'external').to_s.strip.downcase

      %w[all off].include?(value) ? value : 'external'
    end

    # Returns submitters ordered to match the TEMPLATE's roles. The order of the
    # incoming array is deliberately ignored: employer-first is a property of
    # the template, not of however the caller happened to list people.
    def match_submitters!(raw)
      raise InvalidArguments, 'submitters is required' if raw.empty?

      template_roles = @template.submitters.map { |s| s['name'] }

      supplied = raw.map do |entry|
        raise InvalidArguments, 'each submitter must be an object with role, name and email' unless entry.is_a?(Hash)

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

    # The attributes handed to upstream. The first signer carries its own
    # message: the invitation text plus the note naming who signs next and
    # where the signed copy is filed. With a message in the call, everyone
    # gets exactly the text the preview showed them (a subject left out is
    # filled from the defaults, not by upstream's generic one). Without one,
    # the others get upstream's own defaults, unchanged.
    def submitter_attrs(ordered, messages, email_code)
      ordered.each_with_index.map do |s, i|
        attrs = s.dup
        attrs['require_email_2fa'] = email_code[i]

        if i.zero? || given_message
          attrs['message'] = { 'subject' => messages[i]['subject'], 'body' => messages[i]['body'] }.compact
        end

        attrs
      end
    end

    # What each signer's invitation will say, in signing order, as the preview
    # shows it and the token binds it. Mirrors upstream's choice in
    # SubmitterMailer#invitation_email: a message given with the call, else
    # the template's per-role text, else the template's text, else the
    # account's invitation email setting, else DocuSeal's built-in text.
    def build_messages(ordered, filing_folder, expire_at)
      roles = Array.wrap(@template.submitters)
      per_role = Array.wrap(@template.preferences.to_h['submitters']).index_by { |e| e['uuid'] }
      config = AccountConfig.find_by(account_id: current_user.account_id,
                                     key: AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)&.value
      config = {} unless config.is_a?(Hash)

      ordered.each_with_index.map do |s, i|
        uuid = roles.find { |r| r['name'] == s['role'] }.to_h['uuid']
        role_prefs = per_role[uuid].to_h

        subject = given_message&.dig('subject') ||
                  role_prefs['request_email_subject'].presence ||
                  @template.preferences.to_h['request_email_subject'].presence ||
                  config['subject'].presence
        body = given_message&.dig('body') ||
               role_prefs['request_email_body'].presence ||
               @template.preferences.to_h['request_email_body'].presence ||
               config['body'].presence
        source = given_message ? 'message given in this call' : 'template and account defaults'

        if i.zero?
          subject ||= I18n.t(:you_are_invited_to_sign_a_document)
          body = "#{body || FALLBACK_BODY}\n\n#{first_signer_note(ordered, filing_folder, expire_at)}"
          source += ', plus the note for the first signer'
        end

        { 'role' => s['role'], 'email' => s['email'], 'source' => source, 'subject' => subject, 'body' => body }
      end
    end

    # The first signer is the only person who sees the document before the
    # second party is contacted. Telling them who that is, and where the
    # signed copy will be kept, is what makes their signature a check.
    def first_signer_note(ordered, filing_folder, expire_at)
      later = ordered.drop(1).map do |s|
        "#{plain(s['role'])}: #{plain(s['name'])}, #{plain(s['email'])}  "
      end

      lines = ['**Please check before you sign.** When you have signed, this document goes to:', '']
      lines += later.empty? ? ['(nobody else; you are the only signer)'] : later
      lines += ['', "Once everyone has signed, the signed PDF is filed in SharePoint: #{plain(filing_folder)}"]
      lines += ['', "Signing closes on #{plain(expire_at.strftime('%Y-%m-%d %H:%M %Z'))}."] if expire_at
      lines += ['', 'If a name, an address or the folder is wrong, do not sign. Reply to this email instead.']

      lines.join("\n")
    end

    # Names, addresses and folders come from the caller. In the note they
    # must read as text: no markdown emphasis or links, no {variables} that
    # upstream would fill in, no HTML.
    def plain(text)
      text.to_s.gsub(/[\[\]*~`<>{}\\]/, ' ').gsub('++', '+')
          .gsub(%r{://}i, ': //').gsub(/\bwww\./i, 'www .')
          .gsub(/[[:cntrl:]]/, ' ').squeeze(' ').strip
    end

    def given_message
      return @given_message if defined?(@given_message)

      raw = mcp_params['message']

      @given_message =
        if raw.is_a?(Hash) && (raw['subject'].to_s.strip.present? || raw['body'].to_s.strip.present?)
          { 'subject' => raw['subject'].to_s.strip.presence, 'body' => raw['body'].to_s.presence }.compact
        end
    end

    # The first-signer domain guard below constrains the address of the FIRST
    # ROLE. Upstream decides who actually signs first differently: a role that
    # owns no field becomes a viewer (Submissions::CreateFromSubmitters), and
    # the first invitation goes to the first role that is NOT a viewer
    # (Submissions.send_signature_requests). So a template whose fields all
    # belong to the second role passed the domain guard on role one and then
    # invited role two straight away, who could sign alone and have the result
    # filed as "(signed)". The guard only means something if the role it checks
    # is a role that signs.
    def ensure_first_role_signs!
      first = @template.submitters.first.to_h

      signs = @template.fields.any? do |field|
        field['submitter_uuid'] == first['uuid'] && field['type'] == 'signature'
      end

      return if signs

      raise InvalidArguments,
            "the first signing role (#{first['name'].inspect}) has no signature field on this template, so it " \
            'would not sign at all and the next role would be invited immediately. Recreate the template with ' \
            'a signature field for every role.'
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

      list = raw.split(',').map { |d| d.strip.downcase.delete_prefix('@') }.reject(&:empty?)

      # A value with no domain in it (",", " , ") must not switch the guard
      # off; it falls back to the default like an unset variable.
      list.empty? ? DEFAULT_FIRST_SIGNER_DOMAINS : list
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

    # A date alone means the end of that day where the account is, not its
    # first second: "sign by 5 December" must not close at midnight before it.
    def parse_expire_at!(raw)
      return nil if raw.blank?

      zone = ActiveSupport::TimeZone[current_user.account.timezone.to_s] || Time.zone
      text = raw.to_s.strip
      time = text.match?(DATE_ONLY_RE) ? zone.parse(text)&.end_of_day : zone.parse(text)

      raise InvalidArguments, "expire_at #{raw.inspect} is not a date I can read" if time.nil?

      if time < Time.current + MIN_EXPIRY
        raise InvalidArguments, "expire_at #{time.utc.iso8601} is less than an hour ahead; signing would close " \
                                'before anyone could sign'
      end

      time
    rescue ArgumentError
      raise InvalidArguments, "expire_at #{raw.inspect} is not a date I can read"
    end

  end
end
