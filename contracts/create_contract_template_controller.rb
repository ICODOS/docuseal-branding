# frozen_string_literal: true

# ICODOS Phase E — MCP tool: create a contract template from a SharePoint file.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at
#   /app/app/controllers/mcp/icodos_create_contract_template_controller.rb
#
# Replaces the browser half of the contract workflow: upload, rename parties,
# drag four fields into place, move to a folder. All of it becomes one call.
#
# Inherits Mcp::McpBaseController deliberately — that is where authentication,
# the archived-user check and the Phase D OAuth hook already live, so this tool
# is subject to exactly the same access control as the five upstream ones.
#
# WHY NOT upstream create_template
# It takes only a name and an optional URL, hardcodes the folder to the
# account default and the fields to [], and its URL branch would need the
# contract exposed at a fetchable address. This reads the file server-side
# from SharePoint and sets fields, roles, folder and signing order in one go.

module Mcp
  class IcodosCreateContractTemplateController < McpBaseController
    # NAMED FIELD PRESETS. The layouts in use, kept here so an agent names
    # one instead of carrying coordinates around (they used to live as JSON
    # files in SharePoint and were passed through on every call). Geometry as
    # DocuSeal stores it: fractions of the page, origin top-left, zero-based
    # pages, -1 for the last page. submitter_index maps onto roles in order.
    #
    # Measured, not designed: amendment_v1 and full_contract_v1 from the
    # verified templates of 14 and 19 August 2026; the time declarations from
    # the templates in production in October and November 2026 (43 of 46 EU
    # declarations and every OXBREN one since October share these positions;
    # the other 3 EU ones had their block lower, because more work packages
    # pushed it down). A layout that moves needs fields, not a preset, and
    # edit_url is where that is seen.
    date = ->(name, idx, x, y, w, h, page, fmt = 'DD/MM/YYYY') do
      { 'name' => name, 'submitter_index' => idx, 'type' => 'date', 'required' => true,
        'preferences' => { 'format' => fmt }, 'areas' => [{ 'page' => page, 'x' => x, 'y' => y, 'w' => w, 'h' => h }] }
    end
    field = ->(name, type, idx, x, y, w, h, page) do
      { 'name' => name, 'submitter_index' => idx, 'type' => type, 'required' => true,
        'areas' => [{ 'page' => page, 'x' => x, 'y' => y, 'w' => w, 'h' => h }] }
    end
    eu = [date.call('Employee Date', 0, 0.1674, 0.3917, 0.2026, 0.0189, 0),
          field.call('Employee Signature', 'signature', 0, 0.1539, 0.4289, 0.2208, 0.0231, 0)]
    oxbren = [date.call('Employee Date', 0, 0.0475, 0.8590, 0.2970, 0.0252, 0),
              field.call('Employee Signature', 'signature', 0, 0.0475, 0.9090, 0.2970, 0.0336, 0)]

    PRESETS = {
      'amendment_v1' => {
        roles: 2,
        fields: [date.call('Employer Date', 0, 0.1166, 0.1120, 0.2, 0.0286, 1),
                 field.call('Employer Signature', 'signature', 0, 0.1502, 0.1709, 0.2491, 0.0341, 1),
                 date.call('Employee Date', 1, 0.5265, 0.1057, 0.2, 0.0286, 1),
                 field.call('Employee Signature', 'signature', 1, 0.5353, 0.1742, 0.2491, 0.0341, 1)]
      },
      'full_contract_v1' => {
        roles: 2,
        fields: [date.call('Employer Date', 0, 0.2169, 0.1605, 0.1446, 0.0286, -1),
                 field.call('Employer Signature', 'signature', 0, 0.1566, 0.2379, 0.2656, 0.0341, -1),
                 date.call('Employee Date', 1, 0.6386, 0.1605, 0.1447, 0.0286, -1),
                 field.call('Employee Signature', 'signature', 1, 0.5863, 0.2379, 0.2493, 0.0341, -1),
                 date.call('Employee Receipt Date', 1, 0.4278, 0.4530, 0.1446, 0.0286, -1),
                 field.call('Employee Receipt Signature', 'signature', 1, 0.3756, 0.5305, 0.2493, 0.0341, -1)]
      },
      'eu_time_declaration_v5' => {
        roles: 2,
        fields: eu + [date.call('Supervisor Date', 1, 0.5806, 0.3934, 0.1922, 0.0172, 0),
                      field.call('Supervisor Name', 'text', 1, 0.5829, 0.4249, 0.2063, 0.0147, 0),
                      field.call('Supervisor Signature', 'signature', 1, 0.5651, 0.4462, 0.2253, 0.0215, 0)]
      },
      'eu_time_declaration_v5_single' => { roles: 1, fields: eu },
      'oxbren_time_declaration_v1' => {
        roles: 2,
        fields: oxbren + [date.call('Supervisor Date', 1, 0.5939, 0.8590, 0.2970, 0.0252, 0),
                          field.call('Supervisor Signature', 'signature', 1, 0.5939, 0.9090, 0.2970, 0.0336, 0)]
      },
      'oxbren_time_declaration_v1_single' => { roles: 1, fields: oxbren }
    }.each_value { |v| v[:fields].each(&:freeze) }.freeze
    PRESET_NAMES = PRESETS.keys.freeze

    # An employee folder name, which routes a completed document to the Make
    # scenario's Notion write-back. A reusable template must never have one.
    EMPLOYEE_FOLDER_RE = /\A\d{6} /.freeze

    SCHEMA = {
      name: 'icodos_create_contract_template',
      title: 'Create ICODOS Contract Template',
      description: 'Create a DocuSeal template from a contract PDF already stored in the ICODOS SharePoint ' \
                   'library, with signature fields placed and signing roles assigned. The file is read ' \
                   'server-side — do not upload or paste file content. Returns the template id and an edit ' \
                   'URL for visual confirmation before sending.',
      inputSchema: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: 'Template name, e.g. "Amendment to Employment Contract, Devraj Solanki"'
          },
          source_path: {
            type: 'string',
            description: 'Path of the PDF inside the employee-contracts folder, relative to the document ' \
                         'library root, e.g. "General/09 Legal Documents/10 Contracts/01 Employee ' \
                         'contracts/Archive/Working versions of employee contracts/20260814-Amendment.pdf"'
          },
          filing_folder: {
            type: 'string',
            description: 'Folder the signed PDF will be filed into when both parties have signed, in the same ' \
                         'form as source_path. Must already exist. Stored on the template and used later by ' \
                         'the filing hook, which is why the signed copy no longer depends on the name format.'
          },
          folder_name: {
            type: 'string',
            description: 'Optional DocuSeal template folder, e.g. "000029 Devraj Solanki"'
          },
          roles: {
            type: 'array',
            description: 'Signing roles IN SIGNING ORDER. The employer signs first, so ["Employer", "Employee"].',
            items: { type: 'string' }
          },
          preset: {
            type: 'string',
            enum: PRESET_NAMES,
            description: 'A named field layout kept on the server, instead of fields: amendment_v1 (2-page ' \
                         'amendment, 2 roles), full_contract_v1 (full contract, 3 blocks on the last page, 2 ' \
                         'roles), eu_time_declaration_v5 / _single (EU monthly declaration; Employee and ' \
                         'Supervisor, or Employee alone), oxbren_time_declaration_v1 / _single. roles are mapped ' \
                         'in order. Check the result in edit_url: a layout that moved needs fields instead.'
          },
          reusable: {
            type: 'boolean',
            description: 'Optional. true makes a standard template that is sent again and again with values ' \
                         'filled in (a monthly time sheet): it is never archived after filing, and every send ' \
                         'names its signed copy (filing_name). Needs a folder_name that is not an employee ' \
                         'folder ("000NNN Name"). Leave it out for a contract.'
          },
          fields: {
            type: 'array',
            description: 'Fields to place, unless preset is given. Coordinates are fractions of the page (0..1), ' \
                         'page numbers are zero-based (-1 is the last page), and the origin is the top-left ' \
                         'corner — the same geometry DocuSeal stores, so a verified field preset can be passed ' \
                         'through unchanged.',
            items: {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'Field name, e.g. "Employer Signature"' },
                type: { type: 'string', description: 'signature, initials, date, text, number or checkbox' },
                role: { type: 'string', description: 'Which role fills it — must be one of roles' },
                submitter_index: {
                  type: 'integer',
                  description: 'Alternative to role: zero-based index into roles. Accepted so that a stored ' \
                               'field preset can be passed through unchanged. Supply role or submitter_index, ' \
                               'not both.'
                },
                required: { type: 'boolean', description: 'Defaults to true' },
                preferences: {
                  type: 'object',
                  description: 'Optional DocuSeal field preferences, e.g. {"format": "DD/MM/YYYY"} on a date ' \
                               'field. Passed through unchanged.'
                },
                areas: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      page: { type: 'integer', description: 'Zero-based page number; -1 is the last page' },
                      x: { type: 'number' },
                      y: { type: 'number' },
                      w: { type: 'number' },
                      h: { type: 'number' }
                    },
                    required: %w[page x y w h]
                  }
                }
              },
              required: %w[name type role areas]
            }
          }
        },
        required: %w[name source_path filing_folder roles]
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
      }
    }.freeze

    # Stamped on every template this tool creates, so the existing Make
    # scenario can tell "Phase E will file this one" from "nobody else will".
    #
    # It has to be external_id specifically: the submission.completed webhook
    # serialises only id, name, slug, source, submitters_order, expire_at and
    # timestamps, plus template id/name/external_id. Notably NOT preferences —
    # so the filing folder itself is invisible to Make, and external_id is the
    # only field available to carry a marker.
    #
    # Make filters on template.external_id and skips these; it keeps handling
    # everything else. The hook files a submission of a template with the
    # marker however it was sent (from the web interface as well, since
    # November 2026), but never a copy: a copy made in the web interface has
    # no external_id and goes to Make, and a copy that still carries the marker
    # is left to a person (Filing.destination logs it, the host's health job
    # reports it).
    PHASE_E_MARKER = 'icodos-phase-e'

    ALLOWED_FIELD_TYPES = %w[signature initials date text number checkbox].freeze
    MAX_FIELDS = 40
    MAX_NAME_LENGTH = 250
    MAX_SOURCE_BYTES = 3 * 1024 * 1024

    # An identical call within this window returns the template the first
    # one made instead of a second copy (finding T6). Identical means the same
    # user and the same arguments, compared as canonical JSON.
    REUSE_WINDOW = 24 * 3600
    CREATE_DIGEST_KEY = 'icodos_create_digest'
    # While one call creates, an identical one waits instead of racing it.
    IN_FLIGHT_TTL = 600
    FIELD_PLACEHOLDER = 'pending-attachment'

    # Errors answer as structured tool errors (IcodosToolErrors, finding T5).
    # InvalidArguments is anything the caller could fix by changing its
    # arguments; its code defaults to invalid_arguments.
    include ::IcodosToolErrors

    InvalidArguments = ::IcodosToolErrors::ToolError

    # rubocop:disable Metrics
    def call
      account = current_user.account

      # AUTHORIZE FIRST, before the enabled check and before any validation.
      #
      # McpBaseController declares check_authorization, which CanCan enforces as
      # an after_action: an action that finishes without having called
      # authorize! raises CanCan::AuthorizationNotPerformed after the response
      # is built, and the client gets a bare HTTP 500. The render_tool_error
      # calls below are ordinary renders, not exceptions, so that after_action
      # runs for every one of them. While authorize! sat after the SharePoint
      # download, every argument, path and SharePoint error this tool words so
      # carefully was replaced by that 500, which Claude's connector shows as
      # "Bad Gateway". It stayed hidden because only failures trigger it: the
      # logs since 2026-11-01 hold 24 successful calls and no failed one until
      # 2026-11-20, when six failed in a row.
      #
      # It is also the right order regardless: SharePoint used to be read before
      # the caller had been checked for permission to create a template.
      #
      # The Template rule looks only at account_id, so the unsaved record is
      # enough to check. Name and roles are filled in once validated.
      @template = Template.new(
        account: account,
        author: current_user,
        folder: account.default_template_folder,
        source: :mcp,
        external_id: PHASE_E_MARKER,
        fields: [],
        schema: []
      )

      authorize!(:create, @template)

      unless IcodosGraph.enabled?
        raise InvalidArguments.new('the contract tools are not enabled on this instance', code: 'disabled')
      end

      name = mcp_params['name'].to_s.strip
      folder_name = mcp_params['folder_name'].to_s.strip
      roles = Array.wrap(mcp_params['roles']).map { |r| r.to_s.strip }.reject(&:empty?)

      raise InvalidArguments, 'name is required' if name.blank?
      raise InvalidArguments, "name is longer than #{MAX_NAME_LENGTH} characters" if name.length > MAX_NAME_LENGTH
      raise InvalidArguments, 'roles must contain at least one signing role' if roles.empty?
      raise InvalidArguments, 'roles must be unique' if roles.uniq.length != roles.length

      # Both paths go through the allowlist. This is the security boundary —
      # see the header of icodos_graph.rb.
      source_path = IcodosGraph.normalize_path!(mcp_params['source_path'])
      filing_folder = IcodosGraph.normalize_path!(mcp_params['filing_folder'])

      # Checked now rather than at filing time. A contract that cannot be filed
      # once signed is a much worse problem than one that fails to be created.
      unless IcodosGraph.exists?(filing_folder)
        raise InvalidArguments, "filing_folder does not exist in SharePoint: #{filing_folder}"
      end

      submitters = roles.map { |role| { 'name' => role, 'uuid' => SecureRandom.uuid } }
      raw_fields = fields_or_preset!(roles)
      @reusable = reusable!(folder_name)

      # Every argument is checked before the download and before anything is
      # saved, so a refusal costs nothing and leaves nothing behind. Fields
      # used to be checked after the template was saved with the contract
      # attached, and each failed attempt left one orphan template holding
      # the PDF (finding T6).
      ensure_every_role_signs!(raw_fields, submitters)
      fields = build_fields!(raw_fields, submitters, FIELD_PLACEHOLDER)

      digest = create_digest
      existing = earlier_identical(digest)

      return render_created(existing, reused: true) if existing

      create_once(digest) do
        # Waits out OneDrive sync rather than failing on a 404 the caller
        # would have to interpret. See IcodosGraph#download_when_synced.
        bytes = IcodosGraph.download_when_synced(source_path)

        check_source!(bytes, source_path, fields)

        @template.assign_attributes(name: name, submitters: submitters,
                                    preferences: (@template.preferences || {}).merge(CREATE_DIGEST_KEY => digest))

        build!(bytes, source_path, fields, filing_folder, folder_name)

        @icodos_done = "template #{@template.id} created; do not create it again"

        WebhookUrls.enqueue_events(@template, 'template.created')
        SearchEntries.enqueue_reindex(@template)

        render_created(@template)
      end
    end
    # rubocop:enable Metrics

    private

    # The fields of the call, or those of the named preset. Never both: a
    # call that names a preset and also sends fields has two answers to
    # where the signatures go.
    # rubocop:disable Metrics
    def fields_or_preset!(roles)
      name = mcp_params['preset'].to_s.strip
      raw_fields = Array.wrap(mcp_params['fields'])

      return raw_fields if name.empty?

      raise InvalidArguments, 'give fields or preset, not both' if raw_fields.any?

      preset = PRESETS[name]

      raise InvalidArguments, "unknown preset #{name.inspect}; known: #{PRESET_NAMES.join(', ')}" if preset.nil?

      if roles.length != preset[:roles]
        raise InvalidArguments, "preset #{name} is for #{preset[:roles]} role(s) in signing order; roles has " \
                                "#{roles.length}"
      end

      @preset = name

      preset[:fields].map { |f| f.deep_dup }
    end
    # rubocop:enable Metrics

    def reusable!(folder_name)
      value = mcp_params['reusable']

      raise InvalidArguments, 'reusable must be the boolean true or false' unless [nil, true, false].include?(value)

      return false unless value == true

      if folder_name.blank? || folder_name.match?(EMPLOYEE_FOLDER_RE) || folder_name.casecmp('default').zero?
        raise InvalidArguments,
              'a reusable template needs a folder_name of its own, e.g. "Time declarations", and never an ' \
              'employee folder ("000NNN Name"): the Make scenario would take its documents for contracts and ' \
              'look for a Notion contract page.'
      end

      true
    end

    # Saves the template, attaches the PDF and sets fields and preferences.
    # Whatever fails on the way, the half-made template is removed again.
    # rubocop:disable Metrics
    def build!(bytes, source_path, fields, filing_folder, folder_name)
      @template.save!

      documents = attach_document!(@template, bytes, File.basename(source_path))

      # One PDF per contract. Multiple documents would make the areas
      # ambiguous, since a caller cannot know which attachment its
      # coordinates refer to.
      raise InvalidArguments, "expected one document, got #{documents.length}" unless documents.length == 1

      attachment_uuid = documents.first.uuid

      fields.each { |field| field['areas'].each { |area| area['attachment_uuid'] = attachment_uuid } }

      preferences = (@template.preferences || {}).merge(
        # Set here so that EVERY send path preserves order, including upstream
        # send_documents, which has no order parameter and otherwise falls
        # back to 'random'.
        'submitters_order' => 'preserved',
        'icodos_filing_folder' => filing_folder,
        'icodos_source_path' => source_path,
        # A copy of this template inherits these preferences, this one
        # included, and so can be told from the original: its folder and
        # file name belong to the original's employee.
        'icodos_template_id' => @template.id
      )
      preferences[IcodosWorkflow::REUSABLE_KEY] = true if @reusable

      # FilenameUtils.basename(blob[:filename]) is how upstream names
      # documents since 3.3.6, at every site that used to call filename.base.
      # Kept in step so a document reads the same whichever path created it.
      schema = documents.map do |doc|
        { 'attachment_uuid' => doc.uuid, 'name' => FilenameUtils.basename(doc.blob[:filename]) }
      end

      @template.update!(
        schema: schema,
        fields: fields,
        folder: folder_name.present? ? TemplateFolders.find_or_create_by_name(current_user, folder_name) : @template.folder,
        preferences: preferences
      )
    rescue StandardError
      discard_template!
      raise
    end
    # rubocop:enable Metrics

    def discard_template!
      return unless @template&.persisted?

      id = @template.id
      @template.destroy!
      @icodos_done = 'nothing'
    rescue StandardError => e
      Rails.logger.error("[icodos-contracts] create_contract_template: could not remove half-made template #{id} " \
                         "(#{e.class}: #{e.message})")

      @icodos_done = "unknown: a half-made template #{id} may exist; archive it in the web interface"
    end

    def render_created(template, reused: false)
      result = {
        id: template.id,
        name: template.name,
        external_id: template.external_id,
        folder: template.folder&.name,
        roles: Array.wrap(template.submitters).map { |s| s['name'] },
        fields: Array.wrap(template.fields).length,
        filing_folder: template.preferences.to_h['icodos_filing_folder'],
        reusable: IcodosWorkflow.reusable?(template) || nil,
        preset: @preset,
        edit_url: edit_template_url(template)
      }.compact

      if reused
        Rails.logger.info("[icodos-contracts] create_contract_template reused template=#{template.id} " \
                          "user_id=#{current_user.id}")

        result[:reused] = true
        result[:note] = "An identical call created this template at #{template.created_at.utc.iso8601}; it was " \
                        'not created again. To create a second one on purpose, change the name, or archive ' \
                        'this one first.'
      end

      render_tool_result(result)
    end

    # The same user and the same arguments, as canonical JSON.
    def create_digest
      IcodosAudit.digest('user_id' => current_user.id, 'arguments' => mcp_params.to_h)
    end

    def earlier_identical(digest)
      Template.where(account_id: current_user.account_id, author_id: current_user.id,
                     external_id: PHASE_E_MARKER, archived_at: nil)
              .where('created_at > ?', Time.current - REUSE_WINDOW)
              .where('preferences LIKE ?', "%#{digest}%")
              .order(:id).last
    end

    # One identical call at a time. A client that times out during the slow
    # SharePoint download and calls again would otherwise race the first call
    # into a second template. Without Redis the call goes ahead: creating a
    # template sends nothing, and the digest still finds it afterwards.
    def create_once(digest)
      key = "icodos:create_contract_template:#{digest}"

      held =
        begin
          ::Sidekiq.redis { |c| c.call('SET', key, current_user.id.to_s, 'NX', 'EX', IN_FLIGHT_TTL) } == 'OK'
        rescue StandardError => e
          Rails.logger.error("[icodos-contracts] create_contract_template: in-flight store unreachable " \
                             "(#{e.class}: #{e.message}); going ahead")
          nil
        end

      if held == false
        raise InvalidArguments.new(
          'an identical call is creating this template right now. Nothing was created by this call.',
          code: 'in_progress', retryable: true,
          hint: 'Wait half a minute and repeat the same call; it then answers with that template.'
        )
      end

      begin
        yield
      ensure
        begin
          ::Sidekiq.redis { |c| c.call('DEL', key) } if held
        rescue StandardError
          nil
        end
      end
    end

    # The downloaded file, before anything is saved: not empty, not too big
    # to file once signed, a PDF, and long enough for every field.
    # rubocop:disable Metrics
    def check_source!(bytes, source_path, fields)
      raise InvalidArguments.new("#{source_path} is empty", code: 'invalid_pdf') if bytes.empty?

      # The signed copy is the draft plus signatures and the audit trail, and
      # it is filed with Graph's simple upload, which takes 4 MiB. A larger
      # draft used to be accepted (up to 32 MiB) and its signed copy could
      # then never be filed. Production drafts are well under 2 MB.
      if bytes.bytesize > MAX_SOURCE_BYTES
        raise InvalidArguments.new(
          "#{source_path} is #{(bytes.bytesize / 1_048_576.0).round(1)} MB. Drafts are limited to " \
          "#{MAX_SOURCE_BYTES / 1_048_576} MB so that the signed copy can be filed in SharePoint.",
          code: 'invalid_pdf', hint: 'Reduce the file (images, embedded fonts) and try again.'
        )
      end

      # Cheap insurance against a .docx passed by mistake, or a file OneDrive
      # has only partly written. Without it the template is created from
      # whatever arrived and the problem surfaces at signature time.
      unless bytes[0, 5].to_s.b == '%PDF-'.b
        raise InvalidArguments.new(
          "#{source_path} does not look like a PDF (it begins #{bytes[0, 8].to_s.inspect}).",
          code: 'invalid_pdf', hint: 'Pass the PDF, not the .docx, and make sure OneDrive has finished writing it.'
        )
      end

      pages = begin
        HexaPDF::Document.new(io: StringIO.new(bytes)).pages.count
      rescue HexaPDF::Error => e
        raise InvalidArguments.new("#{source_path} could not be read as a PDF (#{e.message}).", code: 'invalid_pdf')
      end

      # -1 is the last page, whatever the document's length (a full contract
      # has 13 or 14 pages, and its signature blocks are on the last).
      fields.each { |f| f['areas'].each { |a| a['page'] = pages - 1 if a['page'] == -1 } }

      beyond = fields.flat_map { |f| f['areas'].map { |a| [f['name'], a['page']] } }.select { |_, page| page >= pages }

      return if beyond.empty?

      raise InvalidArguments.new(
        "#{source_path} has #{pages} page(s) (numbered 0 to #{pages - 1}), but " \
        "#{beyond.map { |name, page| "#{name} is on page #{page}" }.uniq.join(', ')}.",
        hint: 'Page numbers are zero-based.'
      )
    end
    # rubocop:enable Metrics

    def attach_document!(template, bytes, filename)
      tempfile = Tempfile.new
      tempfile.binmode
      tempfile.write(bytes)
      tempfile.rewind

      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename,
        type: Marcel::MimeType.for(tempfile)
      )

      # extract_fields: false on purpose. AcroForm extraction would compete with
      # the coordinates supplied here, and upstream assigns every extracted
      # field to submitters.first, which cannot express a two-party contract.
      documents, = Templates::CreateAttachments.call(template, { files: [file] }, extract_fields: false)

      documents
    ensure
      tempfile&.close
      tempfile&.unlink
    end

    # Every role must own a signature field.
    #
    # Upstream turns a role that owns no field into a viewer and invites the
    # next role at once. With roles ["Employer", "Employee"] and every field
    # assigned to "Employee", the employer never signs: the employee is invited
    # immediately, signs alone, and the document completes and is filed as
    # signed. The first-signer domain guard in icodos_send_contract checked the
    # employer's address and was satisfied, because it looks at the first ROLE,
    # not at who upstream actually sends to first. Requiring a signature per
    # role closes that from this side; the send tool refuses such a template
    # from the other, for templates made before 25 November 2026 or edited by
    # hand. All 97 templates this tool had created by then already comply.
    def ensure_every_role_signs!(raw_fields, submitters)
      signing = raw_fields.each_with_index.map do |raw, index|
        next unless raw.is_a?(Hash) && raw['type'].to_s.strip.downcase == 'signature'

        resolve_submitter_uuid!(raw, submitters, "field #{index + 1}")
      end

      missing = submitters.reject { |s| signing.include?(s['uuid']) }.map { |s| s['name'] }

      return if missing.empty?

      raise InvalidArguments,
            "every role must sign: there is no signature field for #{missing.join(', ')}. A role without one " \
            'would be treated as a viewer and skipped, and the next role would be invited straight away.'
    end

    def build_fields!(raw_fields, submitters, attachment_uuid)
      raise InvalidArguments, 'fields must contain at least one field' if raw_fields.empty?
      raise InvalidArguments, "at most #{MAX_FIELDS} fields" if raw_fields.length > MAX_FIELDS

      raw_fields.each_with_index.map do |raw, index|
        label = "field #{index + 1}"

        field_name = raw['name'].to_s.strip
        type = raw['type'].to_s.strip.downcase

        raise InvalidArguments, "#{label}: name is required" if field_name.blank?

        unless ALLOWED_FIELD_TYPES.include?(type)
          raise InvalidArguments, "#{label}: type #{type.inspect} is not one of #{ALLOWED_FIELD_TYPES.join(', ')}"
        end

        field = {
          'uuid' => SecureRandom.uuid,
          'submitter_uuid' => resolve_submitter_uuid!(raw, submitters, label),
          'name' => field_name,
          'type' => type,
          'required' => raw.key?('required') ? ActiveModel::Type::Boolean.new.cast(raw['required']) : true,
          'areas' => build_areas!(Array.wrap(raw['areas']), attachment_uuid, label)
        }

        # Carries things like a date field's display format. Dropping it would
        # silently change how a signed contract renders, so it passes through.
        field['preferences'] = raw['preferences'] if raw['preferences'].is_a?(Hash) && raw['preferences'].any?

        field
      end
    end

    # Accepts either a role name or a zero-based index into roles, so a stored
    # field preset — which records submitter_index, because uuids differ per
    # template — can be handed over without rewriting.
    def resolve_submitter_uuid!(raw, submitters, label)
      role = raw['role'].to_s.strip
      has_index = raw.key?('submitter_index') && !raw['submitter_index'].nil?

      if role.present? && has_index
        raise InvalidArguments, "#{label}: supply role or submitter_index, not both"
      end

      if has_index
        index = raw['submitter_index'].to_i

        unless index.between?(0, submitters.length - 1)
          raise InvalidArguments, "#{label}: submitter_index #{index} is outside roles (0..#{submitters.length - 1})"
        end

        return submitters[index]['uuid']
      end

      raise InvalidArguments, "#{label}: role or submitter_index is required" if role.blank?

      match = submitters.find { |s| s['name'] == role }

      raise InvalidArguments, "#{label}: role #{role.inspect} is not in roles" if match.nil?

      match['uuid']
    end

    def build_areas!(raw_areas, attachment_uuid, label)
      raise InvalidArguments, "#{label}: at least one area is required" if raw_areas.empty?

      raw_areas.map do |area|
        page = area['page'].to_i

        raise InvalidArguments, "#{label}: page must be zero or greater, or -1 for the last page" if page < -1

        box = %w[x y w h].to_h do |key|
          value = area[key].to_f

          unless value.finite? && value >= 0 && value <= 1
            raise InvalidArguments, "#{label}: #{key} must be a fraction of the page between 0 and 1"
          end

          [key, value]
        end

        if box['w'].zero? || box['h'].zero?
          raise InvalidArguments, "#{label}: w and h must be greater than zero"
        end

        if box['x'] + box['w'] > 1.0001 || box['y'] + box['h'] > 1.0001
          raise InvalidArguments, "#{label}: area extends past the edge of the page"
        end

        box.merge('page' => page, 'attachment_uuid' => attachment_uuid)
      end
    end
  end
end
