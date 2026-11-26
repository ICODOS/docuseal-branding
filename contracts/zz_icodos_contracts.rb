# frozen_string_literal: true

# ICODOS Phase E — MCP tool registration, tool policy and boot diagnostics.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/config/initializers/zz_icodos_contracts.rb.
#
# Loaded with a zz_ prefix for the same reason as zz_sso_entra.rb and
# zz_mcp_oauth.rb: late enough that the classes we touch exist. It sorts AFTER
# zz_mcp_oauth.rb, which is harmless — the two prepend different classes.
#
# IMPORTANT: nothing here may reference IcodosGraph or the tool controllers at
# load time. config/initializers/* runs BEFORE Rails sets up the main Zeitwerk
# autoloader, so /app/lib/icodos_graph.rb is not resolvable yet. Every
# reference below is inside `to_prepare` or `after_initialize`, both of which
# run after the autoloader is ready. This is the same constraint Phase D
# documents, and it bites the same way: a NameError at boot, not at request time.
#
# ROLLBACK
# The contract tools: set ICODOS_CONTRACTS_ENABLED=false in /opt/docuseal/.env
# and `docker compose up -d`. They stop being advertised and stop being
# routable. To remove the code as well, delete the whole "Phase E" mount block
# from docker-compose.yml.
# The hidden upstream tools are a separate switch, on purpose: see
# IcodosContracts.hidden_tools. Turning the contract tools off does NOT bring
# send_documents and create_template back.

module IcodosContracts
  # Tool name -> controller. Resolved lazily by name because constants are not
  # autoloadable at initializer load time, and because a stale constant would
  # survive a Rails reload in development.
  TOOL_CONTROLLER_NAMES = {
    'icodos_create_contract_template' => 'Mcp::IcodosCreateContractTemplateController',
    'icodos_send_contract' => 'Mcp::IcodosSendContractController'
  }.freeze

  # Upstream tools this instance does not offer to agents.
  #
  # The two ICODOS tools carry guards: a preview before sending, employer-first
  # order, a first signer inside the company, files read only from permitted
  # SharePoint folders. Upstream's send_documents and create_template sat next
  # to them with none of that. send_documents takes any template and any
  # recipient and falls back to random signing order; create_template fetches
  # whatever https address it is handed, from the server. An agent acting on an
  # instruction smuggled into a document or an email had no reason to pick the
  # guarded tool. Until 25 November 2026 the guards therefore protected only
  # agents that chose to be protected.
  #
  # Independent of ICODOS_CONTRACTS_ENABLED and of whether SharePoint is
  # reachable. enabled? turns false when the Graph certificate lapses or the
  # configuration breaks, and a broken certificate must not be what quietly
  # puts the unguarded tools back.
  #
  #   ICODOS_MCP_HIDDEN_TOOLS unset          these two (the default)
  #   ICODOS_MCP_HIDDEN_TOOLS=a,b            exactly those
  #   ICODOS_MCP_HIDDEN_TOOLS=none           nothing hidden, upstream as shipped
  DEFAULT_HIDDEN_TOOLS = %w[send_documents create_template].freeze

  module_function

  def enabled?
    IcodosGraph.enabled?
  rescue StandardError
    false
  end

  def hidden_tools
    raw = ENV['ICODOS_MCP_HIDDEN_TOOLS']

    return DEFAULT_HIDDEN_TOOLS if raw.nil? || raw.strip.empty?
    return [] if raw.strip.casecmp('none').zero?

    raw.split(',').map(&:strip).reject(&:empty?)
  end

  def hidden?(name)
    hidden_tools.include?(name.to_s)
  end

  # The controller for an ICODOS tool name, or nil: when the feature is off,
  # when the name is not ours, or when the controller file failed to mount.
  #
  # ONLY THIS LOOKUP IS RESCUED. The rescue used to sit around the whole
  # dispatch, and NoMethodError is a NameError: any bug inside a tool, or an
  # upstream method renamed on a version bump, fell through to upstream, which
  # answered "Unknown tool: icodos_send_contract", possibly after the template
  # had been saved or the emails queued. A tool that fails now fails as itself.
  def controller_for(name)
    return nil unless TOOL_CONTROLLER_NAMES.key?(name) && enabled?

    TOOL_CONTROLLER_NAMES[name].constantize
  rescue NameError => e
    Rails.logger.error("[icodos-contracts] #{name} is registered but its controller cannot be loaded " \
                       "(#{e.message}); answering as an unknown tool")

    nil
  end

  # Schemas of the ICODOS tools, or [] when they are off or cannot be loaded.
  def schemas
    return [] unless enabled?

    TOOL_CONTROLLER_NAMES.values.map { |name| name.constantize::SCHEMA }
  rescue NameError => e
    Rails.logger.error("[icodos-contracts] tool schemas unavailable (#{e.message}); listing upstream tools only")

    []
  end

  # Prepended to McpController. Decides, for tools/call, between a hidden
  # upstream tool, an ICODOS tool and everything else. Everything else falls
  # straight through to upstream — including malformed bodies, so upstream
  # keeps ownership of its -32700 parse error.
  module Dispatch
    def call
      body = icodos_mcp_body

      return super unless body.is_a?(Hash) && body['method'] == 'tools/call'

      name = body.dig('params', 'name')

      # First, and outside every rescue: nothing that goes wrong further down
      # may end in `super` for a tool that is meant to be unreachable.
      if IcodosContracts.hidden?(name)
        request.request_parameters = body

        return Mcp::ProtocolController.dispatch(:icodos_hidden_tool, request, response)
      end

      controller = IcodosContracts.controller_for(name)

      return super if controller.nil?

      # Upstream sets this before dispatching and McpBaseController#mcp_params
      # reads from it. Without it every tool argument would arrive nil.
      request.request_parameters = body

      controller.dispatch(:call, request, response)
    end

    private

    def icodos_mcp_body
      JSON.parse(request.raw_post)
    rescue JSON::ParserError, TypeError
      nil
    end
  end

  # Prepended to Mcp::ProtocolController: what tools/list shows, and the answer
  # for a hidden tool. Both run behind McpBaseController's authentication, like
  # every other action of that controller.
  module ToolsList
    def tools_list
      upstream = McpController::TOOLS.reject { |tool| IcodosContracts.hidden?(tool[:name]) }

      render_result(tools: upstream + IcodosContracts.schemas)
    end

    # A hidden tool is not in tools/list, but a client may still hold an older
    # list. It gets a tool error that says what to use instead, not a protocol
    # error it can only guess at.
    def icodos_hidden_tool
      name = mcp_body.dig('params', 'name')

      Rails.logger.info("[icodos-contracts] refused hidden tool #{name} user_id=#{current_user&.id}")

      render_tool_error(
        "#{name} is switched off on this instance. For contracts use icodos_create_contract_template, which " \
        'reads the PDF from the SharePoint contracts library, and icodos_send_contract, which previews first ' \
        'and sends employer first. Anything those two do not cover is done in the DocuSeal web interface.'
      )
    end
  end
end

# Applied unconditionally rather than gated on enabled?, so that flipping
# ICODOS_CONTRACTS_ENABLED needs nothing but the container restart that
# `docker compose up -d` already performs. Both modules check at request time.
# config/routes.rb is NOT patched — the filing hook is added with
# routes.append, the same pattern the SSO and Phase D overlays use. Resolved
# from a string so the controller is not referenced at load time.
Rails.application.routes.append do
  post '/icodos/hooks/filing', to: 'icodos/filing_hook#create', as: :icodos_filing_hook
end

Rails.application.config.to_prepare do
  begin
    unless McpController.instance_variable_get(:@_icodos_contracts_patched)
      McpController.instance_variable_set(:@_icodos_contracts_patched, true)
      McpController.prepend(IcodosContracts::Dispatch)
    end

    unless Mcp::ProtocolController.instance_variable_get(:@_icodos_contracts_patched)
      Mcp::ProtocolController.instance_variable_set(:@_icodos_contracts_patched, true)
      Mcp::ProtocolController.prepend(IcodosContracts::ToolsList)
    end
  rescue NameError => e
    # Partial rollback, or an upstream rename of McpController /
    # Mcp::ProtocolController on a version bump. Loud, and it now matters
    # twice: the ICODOS tools are not registered, AND the hidden upstream tools
    # are reachable again, because the code that hides them did not attach.
    Rails.logger.error("[icodos-contracts] could not attach to the MCP controllers (#{e.class}: #{e.message}). " \
                       'Phase E tools are NOT registered and NO upstream tool is hidden.')
  end
end

# Boot diagnostic, in the style of Phase D's [mcp-oauth] line. The failure this
# is here to catch is a version bump that silently stops registering the tools —
# from the client side that is indistinguishable from the tools never existing.
Rails.application.config.after_initialize do
  begin
    attached = McpController.ancestors.include?(IcodosContracts::Dispatch) &&
               Mcp::ProtocolController.ancestors.include?(IcodosContracts::ToolsList)

    hidden = IcodosContracts.hidden_tools
    unknown = hidden - McpController::TOOLS.map { |tool| tool[:name].to_s }

    Rails.logger.info("[icodos-contracts] tool policy: hidden=#{hidden.empty? ? 'none' : hidden.join(',')} " \
                      "hooks=#{attached ? 'attached' : 'NOT ATTACHED'}")

    if unknown.any?
      # A typo in the variable, or upstream renamed a tool. Either way the tool
      # that was meant to be hidden is not.
      Rails.logger.error("[icodos-contracts] hidden tool name(s) #{unknown.join(', ')} match no upstream tool; " \
                         "upstream offers #{McpController::TOOLS.map { |tool| tool[:name] }.join(', ')}")
    end

    unless attached
      Rails.logger.error('[icodos-contracts] the MCP hooks are NOT attached: ICODOS tools would answer as unknown ' \
                         'and hidden upstream tools are reachable')
    end

    if IcodosContracts.enabled?
      Rails.logger.info(
        "[icodos-contracts] enabled. site=#{IcodosGraph.site_hostname}#{IcodosGraph.site_path} " \
        "prefixes=#{IcodosGraph.path_prefixes.inspect} " \
        "tools=#{IcodosContracts::TOOL_CONTROLLER_NAMES.keys.join(',')} " \
        "cert_expires=#{IcodosGraph.certificate.not_after.utc.iso8601} " \
        'send=preview_token ' \
        "fixed_term_guard=#{ENV['ICODOS_CONTRACTS_FIXED_TERM_GUARD'].to_s.strip.casecmp('off').zero? ? 'off' : 'on'} " \
        "email_code=#{Mcp::IcodosSendContractController.email_code_policy}"
      )
    else
      Rails.logger.info('[icodos-contracts] disabled (ICODOS_CONTRACTS_ENABLED is not true, or configuration is unusable)')
    end
  rescue StandardError => e
    Rails.logger.error("[icodos-contracts] boot diagnostic failed (#{e.class}: #{e.message})")
  end
end
