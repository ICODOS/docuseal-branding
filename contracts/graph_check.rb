# frozen_string_literal: true

# ICODOS Phase E — Graph connectivity check.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_graph_check.rb.
#
# This is the verification for Phase E0. Every step of the Entra setup can look
# correct in the Azure Portal while the app still has access to nothing —
# Sites.Selected in particular shows a green tick after admin consent and grants
# access to no site at all until a separate per-site grant is made, which the
# Portal cannot display. The only honest test is an app-only token reading a
# real file, which is what this does.
#
# Read-only by default. Pass --write to additionally create and delete a probe
# file, which is the only way to confirm the "write" role rather than "read".
#
#   docker compose exec app bin/rails runner \
#     'require "icodos_graph_check"; IcodosGraphCheck.call'
#
#   docker compose exec app bin/rails runner \
#     'require "icodos_graph_check"; IcodosGraphCheck.call(write: true)'

module IcodosGraphCheck
  # Space and umlaut are deliberate — see the write probe below.
  PROBE_NAME = 'icodos phase-e probe Ätzend.txt'

  module_function

  def call(write: false)
    @failed = false

    puts "\nICODOS Phase E — Graph check\n\n"

    step('configuration present') do
      IcodosGraph.config!
      "tenant=#{IcodosGraph.tenant_id} client=#{IcodosGraph.client_id}"
    end

    step('private key loads') do
      key = IcodosGraph.private_key
      "RSA #{key.n.num_bits} bits from #{IcodosGraph.key_path}"
    end

    step('certificate loads') do
      cert = IcodosGraph.certificate
      thumb = OpenSSL::Digest::SHA1.hexdigest(cert.to_der).upcase
      "expires #{cert.not_after.utc.iso8601}, thumbprint #{thumb}"
    end

    # If this fails the cause is almost always the certificate: either it was
    # never uploaded to the app registration, or a different one was.
    step('app-only token issues') do
      token = IcodosGraph.access_token
      "acquired, #{token.length} chars"
    end

    # File CONTENT is served by SharePoint, not Graph, and needs a second token
    # with its own application role. Without it the token still issues — it just
    # arrives with no roles, and SharePoint answers 401 with an HTML sign-in
    # page that looks nothing like a permissions problem. Checked explicitly so
    # that failure is named rather than diagnosed.
    step('sharepoint token has roles') do
      roles = IcodosGraph.token_roles(IcodosGraph.sharepoint_resource)

      if roles.nil? || roles.empty?
        raise 'no roles in the SharePoint token — add the SharePoint Online (not Graph) ' \
              'Sites.Selected application permission and grant admin consent'
      end

      roles.join(', ')
    end

    # First call that actually touches SharePoint. A 403 here means admin
    # consent landed but the per-site grant did not.
    step('site resolves') do
      IcodosGraph.site_id
    end

    step('drive resolves') do
      IcodosGraph.drive_id
    end

    # Every configured tree, not just the first — a prefix added to .env but
    # misspelled would otherwise sit there looking fine until someone used it.
    step('permitted folders are readable') do
      IcodosGraph.path_prefixes.map do |prefix|
        entries = IcodosGraph.list(prefix)

        "#{prefix.split('/').last} (#{entries.length})"
      end.join(', ')
    end

    # The path allowlist is the security boundary, so prove it rejects rather
    # than assuming it does. These must all raise PathError.
    step('path allowlist rejects escapes') do
      cases = [
        'General/../../etc/passwd',
        '/etc/passwd',
        "#{IcodosGraph.path_prefix}/../Payroll/salaries.xlsx",
        "#{IcodosGraph.path_prefix} evil/x.pdf",
        "#{IcodosGraph.path_prefix}/a:b.pdf"
      ]

      leaked = cases.reject do |c|
        begin
          IcodosGraph.normalize_path!(c)
          false
        rescue IcodosGraph::PathError
          true
        end
      end

      raise "allowlist accepted #{leaked.inspect}" if leaked.any?

      "#{cases.length}/#{cases.length} rejected"
    end

    # The failure this is here to catch is a DocuSeal version bump that stops
    # the prepends attaching. From an MCP client that is indistinguishable from
    # the tools never having existed — no error, they are simply absent.
    step('mcp tools registered') do
      unless McpController.ancestors.include?(IcodosContracts::Dispatch)
        raise 'dispatch hook not attached to McpController — tools/call would fall through to upstream'
      end

      unless Mcp::ProtocolController.ancestors.include?(IcodosContracts::ToolsList)
        raise 'tools_list hook not attached — the tools would not be advertised'
      end

      names = IcodosContracts.schemas.map { |s| s[:name] }

      raise 'no ICODOS tool schemas resolved' if names.empty?

      names.join(', ')
    end

    step('filing route reachable') do
      route = Rails.application.routes.routes.map { |r| r.path.spec.to_s }.grep(%r{icodos/hooks/filing}).first

      raise 'POST /icodos/hooks/filing is not routed' if route.nil?

      route
    end

    step('filing webhook registered') do
      hooks = WebhookUrl.all.select { |w| w.url.to_s.end_with?(Icodos::FilingHookController::HOOK_PATH) }

      if hooks.empty?
        raise 'no WebhookUrl points at the filing hook — signed PDFs would never be filed by Phase E'
      end

      unless hooks.any? { |w| w.events.include?('submission.completed') }
        raise 'the filing webhook is registered but not subscribed to submission.completed'
      end

      others = WebhookUrl.all.reject { |w| w.url.to_s.end_with?(Icodos::FilingHookController::HOOK_PATH) }
                         .select { |w| w.events.include?('submission.completed') }

      note = others.any? ? " (also: #{others.length} other submission.completed subscriber — parallel run)" : ''

      "#{hooks.length} registered#{note}"
    end

    step('first-signer domain guard') do
      controller = Mcp::IcodosSendContractController.new
      domains = controller.send(:first_signer_domains)

      raise 'no first-signer domains configured — any address could countersign' if domains.empty?

      domains.join(', ')
    end

    if write
      # Round-trips a file whose name carries a space and an umlaut, because
      # employee folders and German document names do too, and the path has to
      # survive Graph's drive-item addressing AND SharePoint's OData literal.
      path = "#{IcodosGraph.path_prefix}/#{PROBE_NAME}"
      payload = "phase-e probe #{Time.now.utc.iso8601}\n"

      step('write probe: upload') do
        IcodosGraph.upload(path, payload, content_type: 'text/plain')
        "wrote #{payload.bytesize} bytes"
      end

      step('write probe: read back') do
        readback = IcodosGraph.download(path)
        raise "read back #{readback.bytesize} bytes, expected #{payload.bytesize}" if readback != payload

        'byte-identical'
      end

      step('write probe: cleanup') do
        IcodosGraph.delete(path)
        'probe removed'
      end
    else
      puts "\n  Skipped the write probe. Re-run with write: true to confirm the"
      puts '  "write" role rather than just "read".'
    end

    puts "\n#{@failed ? 'FAILED — see above' : 'All checks passed.'}\n\n"

    !@failed
  end

  def step(label)
    detail = yield
    puts format('  %-34s ok    %s', label, detail)
  rescue StandardError => e
    @failed = true
    puts format('  %-34s FAIL  %s: %s', label, e.class.name.split('::').last, e.message)
  end
end
