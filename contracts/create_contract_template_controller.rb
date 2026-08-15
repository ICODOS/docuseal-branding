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
          fields: {
            type: 'array',
            description: 'Fields to place. Coordinates are fractions of the page (0..1), page numbers are ' \
                         'zero-based, and the origin is the top-left corner — the same geometry DocuSeal ' \
                         'stores, so a verified field preset can be passed through unchanged.',
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
                      page: { type: 'integer', description: 'Zero-based page number' },
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
        required: %w[name source_path filing_folder roles fields]
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
    # everything sent from the DocuSeal UI or the upstream tools, which carry no
    # filing folder and which Phase E therefore ignores. Between them the two
    # paths cover every submission exactly once.
    PHASE_E_MARKER = 'icodos-phase-e'

    ALLOWED_FIELD_TYPES = %w[signature initials date text number checkbox].freeze
    MAX_FIELDS = 40
    MAX_NAME_LENGTH = 250

    # Raised for anything the caller could fix by changing its arguments. Kept
    # distinct from Graph and DocuSeal failures so the message can say which.
    class InvalidArguments < StandardError; end

    # rubocop:disable Metrics
    def call
      return render_tool_error('Phase E is not enabled on this instance') unless IcodosGraph.enabled?

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

      bytes = IcodosGraph.download(source_path)

      raise InvalidArguments, "#{source_path} is empty" if bytes.empty?

      account = current_user.account

      @template = Template.new(
        account: account,
        author: current_user,
        folder: account.default_template_folder,
        source: :mcp,
        name: name,
        external_id: PHASE_E_MARKER,
        submitters: submitters,
        fields: [],
        schema: []
      )

      authorize!(:create, @template)
      @template.save!

      documents = attach_document!(@template, bytes, File.basename(source_path))

      # One PDF per contract. Multiple documents would make the areas ambiguous,
      # since a caller cannot know which attachment its coordinates refer to.
      raise InvalidArguments, "expected one document, got #{documents.length}" unless documents.length == 1

      attachment_uuid = documents.first.uuid

      fields = build_fields!(Array.wrap(mcp_params['fields']), submitters, attachment_uuid)

      preferences = (@template.preferences || {}).merge(
        # Set here so that EVERY send path preserves order, including upstream
        # send_documents, which has no order parameter and otherwise falls back
        # to 'random'.
        'submitters_order' => 'preserved',
        'icodos_filing_folder' => filing_folder,
        'icodos_source_path' => source_path
      )

      @template.update!(
        schema: documents.map { |doc| { 'attachment_uuid' => doc.uuid, 'name' => doc.filename.base } },
        fields: fields,
        folder: folder_name.present? ? TemplateFolders.find_or_create_by_name(current_user, folder_name) : @template.folder,
        preferences: preferences
      )

      WebhookUrls.enqueue_events(@template, 'template.created')
      SearchEntries.enqueue_reindex(@template)

      render_tool_result(
        id: @template.id,
        name: @template.name,
        external_id: @template.external_id,
        folder: @template.folder&.name,
        roles: roles,
        fields: fields.length,
        filing_folder: filing_folder,
        edit_url: edit_template_url(@template)
      )
    rescue InvalidArguments, IcodosGraph::PathError => e
      render_tool_error(e.message)
    rescue IcodosGraph::Error => e
      # Graph and SharePoint failures name themselves well; passing the message
      # through is what lets the caller tell "wrong path" from "lost access".
      Rails.logger.error("[icodos-contracts] create_contract_template: #{e.class} #{e.message}")
      render_tool_error("SharePoint: #{e.message}")
    end
    # rubocop:enable Metrics

    private

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

        raise InvalidArguments, "#{label}: page must be zero or greater" if page.negative?

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
