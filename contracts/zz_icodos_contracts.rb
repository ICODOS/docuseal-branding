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
# The tool policy is a separate switch, on purpose: see
# IcodosContracts.upstream_allowed. Turning the contract tools off does NOT
# bring send_documents and create_template back.

module IcodosContracts
  # Tool name -> controller. Resolved lazily by name because constants are not
  # autoloadable at initializer load time, and because a stale constant would
  # survive a Rails reload in development.
  TOOL_CONTROLLER_NAMES = {
    'icodos_create_contract_template' => 'Mcp::IcodosCreateContractTemplateController',
    'icodos_send_contract' => 'Mcp::IcodosSendContractController'
  }.freeze

  # THE TOOL POLICY (finding T1): which upstream tools agents may use here.
  #
  # An allowlist, not a list of tools to hide. The two ICODOS tools carry
  # guards: a preview bound to its confirmation, employer-first order, a first
  # signer inside the company, files read only from permitted SharePoint
  # folders. Upstream's send_documents and create_template sit next to them
  # with none of that: send_documents takes any template and any recipient and
  # falls back to random signing order; create_template fetches whatever https
  # address it is handed, from the server. An agent acting on an instruction
  # smuggled into a document or an email would simply use them.
  #
  # From 25 November 2026 those two were hidden by name. That left the door
  # open the other way: a tool that a later upstream version adds would have
  # been offered to agents the moment the image was bumped, unreviewed. Now an
  # upstream tool is offered only when it is named here. The three allowed by
  # default read and change nothing.
  #
  # Independent of ICODOS_CONTRACTS_ENABLED and of whether SharePoint is
  # reachable. enabled? turns false when the Graph certificate lapses or the
  # configuration breaks, and a broken certificate must not be what quietly
  # puts the unguarded tools back.
  #
  #   ICODOS_MCP_UPSTREAM_TOOLS unset or empty   the three below (the default)
  #   ICODOS_MCP_UPSTREAM_TOOLS=a,b              exactly those upstream tools
  #   ICODOS_MCP_UPSTREAM_TOOLS=none             no upstream tool
  #   ICODOS_MCP_UPSTREAM_TOOLS=all              upstream as shipped, including
  #                                              tools nobody here has reviewed
  #
  # The ICODOS tools are not part of the list: they are offered whenever
  # ICODOS_CONTRACTS_ENABLED is true and SharePoint is usable.
  DEFAULT_UPSTREAM_TOOLS = %w[search_templates load_template search_documents].freeze

  # The upstream tools of DocuSeal 3.4.0, read and judged when the policy was
  # written. Anything else upstream offers after a version bump is reported
  # at boot as not reviewed; it stays refused unless named above.
  REVIEWED_UPSTREAM_TOOLS = %w[search_templates load_template create_template send_documents
                               search_documents].freeze

  module_function

  def enabled?
    IcodosGraph.enabled?
  rescue StandardError
    false
  end

  # :all, or the list of upstream tool names agents may use.
  def upstream_allowed
    raw = ENV['ICODOS_MCP_UPSTREAM_TOOLS'].to_s.strip

    return DEFAULT_UPSTREAM_TOOLS if raw.empty?
    return [] if raw.casecmp('none').zero?
    return :all if raw.casecmp('all').zero?

    raw.split(',').map(&:strip).reject(&:empty?)
  end

  def upstream_tools
    McpController::TOOL_CONTROLLERS.keys.map(&:to_s)
  end

  # True for an upstream tool this instance does not offer. A name that is
  # neither upstream nor ICODOS is not refused here; it reaches upstream and
  # gets upstream's own "tool not found".
  def refused?(name)
    name = name.to_s
    allowed = upstream_allowed

    upstream_tools.include?(name) && allowed != :all && !allowed.include?(name)
  end

  def refused_tools
    upstream_tools.select { |name| refused?(name) }
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

  # Prepended to McpController. Decides, for tools/call, between a refused
  # upstream tool, an ICODOS tool and everything else. Everything else falls
  # straight through to upstream — including malformed bodies, so upstream
  # keeps ownership of its -32700 parse error.
  #
  # Every tools/call, whichever of the three it reaches and however it ends,
  # leaves one line in the audit record (IcodosAudit), written in an ensure
  # after the response exists.
  module Dispatch
    def call
      body = icodos_mcp_body

      return super unless body.is_a?(Hash) && body['method'] == 'tools/call'

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        icodos_dispatch(body) { super() }
      ensure
        IcodosAudit.record_call(request, response, body, started)
      end
    end

    private

    def icodos_dispatch(body)
      name = body.dig('params', 'name')

      # First, and outside every rescue: nothing that goes wrong further down
      # may end in `super` for a tool that is meant to be unreachable.
      if IcodosContracts.refused?(name)
        request.request_parameters = body

        return Mcp::ProtocolController.dispatch(:icodos_hidden_tool, request, response)
      end

      controller = IcodosContracts.controller_for(name)

      return yield if controller.nil?

      # Upstream sets this before dispatching and McpBaseController#mcp_params
      # reads from it. Without it every tool argument would arrive nil.
      request.request_parameters = body

      controller.dispatch(:call, request, response)
    end

    def icodos_mcp_body
      JSON.parse(request.raw_post)
    rescue JSON::ParserError, TypeError
      nil
    end
  end

  # Prepended to Mcp::ProtocolController: what tools/list shows, and the answer
  # for a refused tool. Both run behind McpBaseController's authentication,
  # like every other action of that controller.
  module ToolsList
    def tools_list
      upstream = McpController::TOOLS.reject { |tool| IcodosContracts.refused?(tool[:name]) }

      render_result(tools: upstream + IcodosContracts.schemas)
    end

    # A refused tool is not in tools/list, but a client may still hold an
    # older list. It gets a tool error that says what to use instead, not a
    # protocol error it can only guess at.
    def icodos_hidden_tool
      name = mcp_body.dig('params', 'name')

      Rails.logger.info("[icodos-contracts] refused tool #{name} user_id=#{current_user&.id}")

      render_result(
        content: [{ type: 'text', text: IcodosToolErrors.payload(
          'tool_refused',
          "#{name} is switched off on this instance.",
          retryable: false,
          hint: 'For contracts use icodos_create_contract_template, which reads the PDF from the SharePoint ' \
                'contracts library, and icodos_send_contract, which previews first and sends employer first. ' \
                'Anything those two do not cover is done in the DocuSeal web interface.',
          request_id: request.request_id
        ).to_json }],
        isError: true
      )
    end
  end
end

# Structured errors of the ICODOS tools (finding T5).
#
# Until November 2026 a failing tool answered with a sentence, or, for any
# exception nobody had thought of, a bare HTTP 500, which Claude's connector
# shows as "Bad Gateway". An agent could not tell "fix your arguments" from
# "try again in a minute" from "something may already have been sent", and a
# bare 500 invited it to try a different tool. Every error of the two tools
# now answers as a tool error whose text is one JSON object:
#
#   {"error":"preview_expired","message":"...","retryable":false,
#    "hint":"Make a new preview and show it to the requester.",
#    "done":"nothing","request_id":"..."}
#
# error      a stable code; the list is in the README
# retryable  true only when the SAME call may simply be repeated later
# done       what had already happened when the error came: "nothing", or a
#            sentence saying what exists now and what must not be repeated
# request_id matches the log and the audit record
#
# Included by both tool controllers. The handlers are declared from the most
# general to the most specific, because Rails tries the last declared first.
module IcodosToolErrors
  class ToolError < StandardError
    attr_reader :code, :retryable, :hint

    def initialize(message = nil, code: 'invalid_arguments', retryable: false, hint: nil)
      super(message)
      @code = code
      @retryable = retryable
      @hint = hint
    end
  end

  # Graph statuses that say "later", not "never".
  RETRYABLE_GRAPH_STATUSES = [408, 423, 429, 500, 502, 503, 504].freeze

  def self.payload(code, message, retryable:, hint: nil, done: 'nothing', request_id: nil)
    { error: code, message: message.to_s, retryable: retryable, hint: hint, done: done,
      request_id: request_id }.compact
  end

  def self.included(base)
    base.rescue_from StandardError, with: :icodos_unexpected_error
    base.rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, with: :icodos_save_error
    base.rescue_from Faraday::Error, with: :icodos_network_error
    base.rescue_from IcodosGraph::Error, with: :icodos_graph_error
    base.rescue_from ToolError, with: :icodos_tool_error
    base.rescue_from ActiveRecord::RecordNotFound, with: :icodos_not_found
    # Upstream's own answer (McpBaseController), restated so that the
    # catch-all above does not take it over.
    base.rescue_from CanCan::AccessDenied, with: :icodos_access_denied
  end

  private

  def icodos_tool_name
    self.class::SCHEMA[:name]
  rescue StandardError
    self.class.name
  end

  # What had already happened. A tool sets @icodos_done once something
  # exists that a repeated call must not create again.
  def icodos_done
    @icodos_done || 'nothing'
  end

  def icodos_error(code, message, retryable:, hint: nil)
    Rails.logger.info("[icodos-contracts] #{icodos_tool_name} error=#{code} retryable=#{retryable} " \
                      "done=#{icodos_done == 'nothing' ? 'nothing' : 'something'} user_id=#{current_user&.id}")

    render_result(content: [{ type: 'text', text: IcodosToolErrors.payload(
      code, message, retryable: retryable, hint: hint, done: icodos_done, request_id: request.request_id
    ).to_json }], isError: true)
  end

  def icodos_tool_error(error)
    icodos_error(error.code, error.message, retryable: error.retryable, hint: error.hint)
  end

  def icodos_not_found(_error)
    icodos_error('not_found', 'No such template or submission in this account.',
                 retryable: false, hint: 'Check the id with search_templates or search_documents.')
  end

  def icodos_access_denied(_error)
    render_error(-32_603, 'Forbidden', status: :forbidden)
  end

  # rubocop:disable Metrics
  def icodos_graph_error(error)
    Rails.logger.error("[icodos-contracts] #{icodos_tool_name}: #{error.class} #{error.message}")

    status = error.respond_to?(:status) ? error.status.to_i : 0

    case error
    when IcodosGraph::PathError
      icodos_error('path_refused', error.message,
                   retryable: false,
                   hint: 'Paths are relative to the document library root and must lie inside the permitted ' \
                         'folders. Ask the requester for the exact path.')
    when IcodosGraph::ConfigError, IcodosGraph::AuthError
      icodos_error('sharepoint_config', "SharePoint access is not working on the server: #{error.message}",
                   retryable: false,
                   hint: 'Not fixable by the caller. Tell the requester; an administrator must check the Graph ' \
                         'certificate and app registration.')
    else
      if status == 404
        icodos_error('sharepoint_not_found', "SharePoint: #{error.message}",
                     retryable: false, hint: 'The file or folder is not there. Check the path with the requester.')
      elsif RETRYABLE_GRAPH_STATUSES.include?(status)
        icodos_error('sharepoint_unavailable', "SharePoint: #{error.message}",
                     retryable: true, hint: 'SharePoint is busy or briefly unavailable. Retry the same call in a minute.')
      else
        icodos_error('sharepoint_error', "SharePoint: #{error.message}", retryable: false)
      end
    end
  end
  # rubocop:enable Metrics

  def icodos_network_error(error)
    Rails.logger.error("[icodos-contracts] #{icodos_tool_name}: #{error.class} #{error.message}")

    icodos_error('sharepoint_unreachable',
                 "SharePoint could not be reached (#{error.class.name.demodulize}: #{error.message}).",
                 retryable: true, hint: 'A network failure, not a problem with the arguments. Retry the same ' \
                                        'call in a minute.')
  end

  def icodos_save_error(error)
    Rails.logger.error("[icodos-contracts] #{icodos_tool_name}: #{error.class} #{error.message}")

    icodos_error('save_failed', "DocuSeal could not save the record: #{error.message}",
                 retryable: false, hint: 'Not a network failure. Report the request_id.')
  end

  # Anything nobody anticipated. Two exceptions are left alone: CanCan's
  # check that every action authorized (a security net, raised after the
  # response, which must stay an error), and anything raised after a
  # response was already rendered.
  def icodos_unexpected_error(error)
    raise error if error.is_a?(CanCan::AuthorizationNotPerformed) || performed?

    Rails.logger.error("[icodos-contracts] #{icodos_tool_name}: unexpected #{error.class}: #{error.message} " \
                       "at #{Array(error.backtrace).first(3).join(' | ')}")

    icodos_error('internal_error', "The tool failed unexpectedly (#{error.class.name}).",
                 retryable: false,
                 hint: 'Do not retry with another tool. Look at "done" before trying again, and report the ' \
                       'request_id.')
  end
end

# The audit record of agent actions (finding O4): one JSON line per
# tools/call, appended to a file per month on the data volume, which the
# nightly backup takes whole and which survives deploys (the container log,
# until November 2026 the only trace, does not).
#
#   {"at":"2026-11-26T10:00:00.123Z","request_id":"...","user_id":1,
#    "auth":"oauth","client":"3f2a9c01b7de","client_name":"Claude",
#    "tool":"icodos_send_contract","args_sha256":"...","outcome":"ok",
#    "sent":true,"submission_id":120,"template_id":129,"ms":812}
#
# No arguments in clear: they carry employees' names and private addresses.
# args_sha256 is SHA-256 over the arguments as canonical JSON (keys sorted
# at every level, as [key, value] pairs, no whitespace), so a known call can
# be matched to its line. client is the first 12 hex digits of SHA-256 over
# the OAuth client_id (the client_id itself starts alike for every client,
# which is why the [mcp-oauth] log lines cannot tell clients apart), or
# "static:<mcp_tokens id>" for a static token. outcome is ok, tool_error,
# protocol_error, unauthorized, forbidden or http_<status>.
#
# Fails open: a record that cannot be written is logged as an error and the
# call stands. It is written after the response exists, so it could not
# stop the action anyway; the error line is what makes a gap visible.
module IcodosAudit
  DEFAULT_DIR = '/data/docuseal/icodos_audit'

  module_function

  def dir
    ENV['ICODOS_AUDIT_DIR'].to_s.strip.presence || DEFAULT_DIR
  end

  def path(now = Time.now.utc)
    File.join(dir, "mcp-#{now.strftime('%Y-%m')}.jsonl")
  end

  def canonical(value)
    case value
    when Hash then value.map { |k, v| [k.to_s, canonical(v)] }.sort_by(&:first)
    when Array then value.map { |v| canonical(v) }
    else value
    end
  end

  def digest(args)
    OpenSSL::Digest::SHA256.hexdigest(JSON.generate(canonical(args || {})))
  end

  # rubocop:disable Metrics
  def record_call(request, response, body, started)
    env = request.env
    args = body.dig('params', 'arguments')
    args = {} unless args.is_a?(Hash)
    tool = body.dig('params', 'name').to_s[0, 80]
    status = response.status.to_i
    parsed = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end

    outcome =
      if status == 401 then 'unauthorized'
      elsif status == 403 then 'forbidden'
      elsif !parsed.is_a?(Hash) || status != 200 then "http_#{status}"
      elsif parsed['error'] then 'protocol_error'
      elsif parsed.dig('result', 'isError') then 'tool_error'
      else 'ok'
      end

    data = begin
      outcome == 'ok' ? JSON.parse(parsed.dig('result', 'content', 0, 'text').to_s) : nil
    rescue JSON::ParserError
      nil
    end
    data = {} unless data.is_a?(Hash)

    template_id = args['template_id'].presence || (tool == 'icodos_create_contract_template' ? data['id'] : nil)

    entry = {
      'at' => Time.now.utc.iso8601(3),
      'request_id' => request.request_id,
      'user_id' => env['icodos.mcp.user_id'],
      'auth' => env['icodos.mcp.auth'] || 'none',
      'client' => env['icodos.mcp.client'],
      'client_name' => env['icodos.mcp.client_name'],
      'tool' => tool,
      'args_sha256' => digest(args),
      'outcome' => outcome,
      'sent' => [true, false].include?(data['sent']) ? data['sent'] : nil,
      'submission_id' => data['submission_id'],
      'template_id' => template_id.is_a?(Integer) || template_id.to_s.match?(/\A\d+\z/) ? template_id.to_i : nil,
      'ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    }.compact

    write(entry)
  rescue StandardError => e
    Rails.logger.error("[icodos-audit] could not build the audit record (#{e.class}: #{e.message}); tool=#{tool}")
  end
  # rubocop:enable Metrics

  def write(entry)
    FileUtils.mkdir_p(dir, mode: 0o700)

    File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |f|
      f.flock(File::LOCK_EX)
      f.write("#{JSON.generate(entry)}\n")
    end
  rescue StandardError => e
    Rails.logger.error("[icodos-audit] could not write the audit record to #{path} (#{e.class}: #{e.message}); " \
                       "tool=#{entry['tool']} user_id=#{entry['user_id']} outcome=#{entry['outcome']}")
  end

  # Prepended to Mcp::McpBaseController. Notes who called and through which
  # client in the request, which the dispatcher shares with the tool
  # controller, so the record can say it after the call. Reads what the
  # OAuth hook leaves on the controller; changes nothing about who is let in.
  module Identity
    private

    def current_user
      user = super

      icodos_note_caller(user) if user && !request.env.key?('icodos.mcp.user_id')

      user
    end

    def icodos_note_caller(user)
      env = request.env
      env['icodos.mcp.user_id'] = user.id
      principal = instance_variable_get(:@icodos_oauth_principal)

      if principal
        env['icodos.mcp.auth'] = 'oauth'
        env['icodos.mcp.client'] = OpenSSL::Digest::SHA256.hexdigest(principal.client_id.to_s)[0, 12]
        env['icodos.mcp.client_name'] = McpOauth.parse_client(principal.client_id)&.name
      else
        token = request.headers['Authorization'].to_s[/\ABearer\s+(.+)\z/, 1].to_s
        env['icodos.mcp.auth'] = 'static'
        env['icodos.mcp.client'] = "static:#{McpToken.find_by(sha256: Digest::SHA256.hexdigest(token))&.id}"
      end
    rescue StandardError => e
      # The call goes on; the record will say less about who made it.
      Rails.logger.error("[icodos-audit] could not note the caller (#{e.class}: #{e.message})")
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

    unless Mcp::McpBaseController.instance_variable_get(:@_icodos_audit_patched)
      Mcp::McpBaseController.instance_variable_set(:@_icodos_audit_patched, true)
      Mcp::McpBaseController.prepend(IcodosAudit::Identity)
    end
  rescue NameError => e
    # Partial rollback, or an upstream rename of McpController /
    # Mcp::ProtocolController on a version bump. Loud, and it now matters
    # twice: the ICODOS tools are not registered, AND the hidden upstream tools
    # are reachable again, because the code that hides them did not attach.
    Rails.logger.error("[icodos-contracts] could not attach to the MCP controllers (#{e.class}: #{e.message}). " \
                       'Phase E tools are NOT registered and NO upstream tool is refused.')
  end
end

# Boot diagnostic, in the style of Phase D's [mcp-oauth] line. The failure this
# is here to catch is a version bump that silently stops registering the tools —
# from the client side that is indistinguishable from the tools never existing.
Rails.application.config.after_initialize do
  begin
    attached = McpController.ancestors.include?(IcodosContracts::Dispatch) &&
               Mcp::ProtocolController.ancestors.include?(IcodosContracts::ToolsList)

    allowed = IcodosContracts.upstream_allowed
    upstream = IcodosContracts.upstream_tools
    refused = IcodosContracts.refused_tools
    offered = upstream - refused
    unknown = allowed == :all ? [] : allowed - upstream
    unreviewed = upstream - IcodosContracts::REVIEWED_UPSTREAM_TOOLS

    audit = begin
      FileUtils.mkdir_p(IcodosAudit.dir, mode: 0o700)
      File.writable?(IcodosAudit.dir) ? IcodosAudit.dir : "#{IcodosAudit.dir} (NOT WRITABLE)"
    rescue StandardError => e
      "#{IcodosAudit.dir} (NOT WRITABLE: #{e.class})"
    end
    identity = Mcp::McpBaseController.ancestors.include?(IcodosAudit::Identity)

    Rails.logger.info("[icodos-contracts] tool policy: upstream_offered=#{offered.empty? ? 'none' : offered.join(',')} " \
                      "upstream_refused=#{refused.empty? ? 'none' : refused.join(',')} " \
                      "hooks=#{attached ? 'attached' : 'NOT ATTACHED'} " \
                      "audit=#{audit} audit_identity=#{identity ? 'attached' : 'missing'}")

    if unknown.any?
      # A typo in the variable, or upstream renamed a tool. Either way the tool
      # that was meant to be offered is not; nothing is offered by mistake.
      Rails.logger.error("[icodos-contracts] ICODOS_MCP_UPSTREAM_TOOLS names #{unknown.join(', ')}, which match no " \
                         "upstream tool; upstream offers #{upstream.join(', ')}")
    end

    if unreviewed.any?
      # A version bump brought tools nobody here has read. Refused unless the
      # variable names them (or says all).
      Rails.logger.warn("[icodos-contracts] upstream tool(s) not reviewed for this instance: #{unreviewed.join(', ')}; " \
                        "#{(unreviewed & offered).any? ? 'OFFERED because ICODOS_MCP_UPSTREAM_TOOLS allows them' : 'refused'}")
    end

    if ENV.key?('ICODOS_MCP_HIDDEN_TOOLS')
      Rails.logger.error('[icodos-contracts] ICODOS_MCP_HIDDEN_TOOLS is no longer read (since the T1 tool policy); ' \
                         'use ICODOS_MCP_UPSTREAM_TOOLS, an allowlist')
    end

    unless attached
      Rails.logger.error('[icodos-contracts] the MCP hooks are NOT attached: ICODOS tools would answer as unknown ' \
                         'and refused upstream tools are reachable')
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
