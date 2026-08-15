# frozen_string_literal: true

# ICODOS Phase E — MCP tool registration and boot diagnostics.
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
# ROLLBACK: set ICODOS_CONTRACTS_ENABLED=false in /opt/docuseal/.env and
# `docker compose up -d`. The tools stop being advertised and stop being
# routable, and /mcp behaves exactly as it did before Phase E. To remove the
# code as well, delete the whole "Phase E" mount block from docker-compose.yml.

module IcodosContracts
  # Tool name -> controller. Resolved lazily by name because constants are not
  # autoloadable at initializer load time, and because a stale constant would
  # survive a Rails reload in development.
  TOOL_CONTROLLER_NAMES = {
    'icodos_create_contract_template' => 'Mcp::IcodosCreateContractTemplateController',
    'icodos_send_contract' => 'Mcp::IcodosSendContractController'
  }.freeze

  module_function

  def enabled?
    IcodosGraph.enabled?
  rescue StandardError
    false
  end

  def tool_controllers
    TOOL_CONTROLLER_NAMES.transform_values(&:constantize)
  end

  def schemas
    tool_controllers.values.map { |controller| controller::SCHEMA }
  end

  # Prepended to McpController. Intercepts tools/call for ICODOS tool names and
  # otherwise falls straight through to upstream — including for malformed
  # bodies, so upstream keeps ownership of its -32700 parse error.
  module Dispatch
    def call
      return super unless IcodosContracts.enabled?

      body = begin
        JSON.parse(request.raw_post)
      rescue JSON::ParserError, TypeError
        return super
      end

      return super unless body.is_a?(Hash) && body['method'] == 'tools/call'

      controller = IcodosContracts.tool_controllers[body.dig('params', 'name')]

      return super if controller.nil?

      # Upstream sets this before dispatching and McpBaseController#mcp_params
      # reads from it. Without it every tool argument would arrive nil.
      request.request_parameters = body

      controller.dispatch(:call, request, response)
    rescue NameError => e
      # A controller file that failed to mount would otherwise 500 every /mcp
      # request, including the upstream tools. Fail soft and loud instead.
      Rails.logger.error("[icodos-contracts] tool dispatch unavailable (#{e.message}); falling through to upstream")

      super
    end
  end

  # Prepended to Mcp::ProtocolController so the ICODOS tools appear in
  # tools/list alongside the upstream five.
  module ToolsList
    def tools_list
      return super unless IcodosContracts.enabled?

      render_result(tools: McpController::TOOLS + IcodosContracts.schemas)
    rescue NameError => e
      Rails.logger.error("[icodos-contracts] tool schemas unavailable (#{e.message}); listing upstream tools only")

      super
    end
  end
end

# Applied unconditionally rather than gated on enabled?, so that flipping
# ICODOS_CONTRACTS_ENABLED needs nothing but the container restart that
# `docker compose up -d` already performs. Both modules check enabled? at
# request time and fall through when the flag is off.
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
    # Mcp::ProtocolController on a version bump. Fail closed and loud: /mcp
    # keeps working with the upstream five tools and the ICODOS ones are simply
    # never advertised.
    Rails.logger.error("[icodos-contracts] could not attach to the MCP controllers (#{e.class}: #{e.message}). " \
                       'Phase E tools are NOT registered; upstream MCP is unaffected.')
  end
end

# Boot diagnostic, in the style of Phase D's [mcp-oauth] line. The failure this
# is here to catch is a version bump that silently stops registering the tools —
# from the client side that is indistinguishable from the tools never existing.
Rails.application.config.after_initialize do
  begin
    if IcodosContracts.enabled?
      Rails.logger.info(
        "[icodos-contracts] enabled. site=#{IcodosGraph.site_hostname}#{IcodosGraph.site_path} " \
        "prefix=#{IcodosGraph.path_prefix.inspect} " \
        "tools=#{IcodosContracts::TOOL_CONTROLLER_NAMES.keys.join(',')} " \
        "cert_expires=#{IcodosGraph.certificate.not_after.utc.iso8601}"
      )

      unless McpController.ancestors.include?(IcodosContracts::Dispatch)
        Rails.logger.error('[icodos-contracts] enabled but the dispatch hook is NOT attached — tools/call will 404')
      end
    else
      Rails.logger.info('[icodos-contracts] disabled (ICODOS_CONTRACTS_ENABLED is not true, or configuration is unusable)')
    end
  rescue StandardError => e
    Rails.logger.error("[icodos-contracts] boot diagnostic failed (#{e.class}: #{e.message})")
  end
end
