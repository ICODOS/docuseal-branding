# frozen_string_literal: true

# ICODOS MCP OAuth 2.1 — route registration, log hygiene, boot diagnostics, and
# the /mcp authentication hook.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/config/initializers/zz_mcp_oauth.rb.
#
# Loaded with a zz_ prefix for the same reason as zz_sso_entra.rb: late enough
# that the classes we touch exist. It sorts before zz_sso_entra.rb, so nothing
# here may reference the `Sso` module at load time (only at request time).
#
# IMPORTANT: nothing in this file may reference McpOauth (or any other autoloaded
# constant) at load time. config/initializers/* runs BEFORE Rails sets up the
# main Zeitwerk autoloader, so `lib/mcp_oauth.rb` is not resolvable yet — even a
# `defined?`-style probe raises NameError there. Every reference below is inside
# `routes.append` (which resolves controllers from strings, lazily), `to_prepare`,
# or `after_initialize`, all of which run after the autoloader is ready.
#
# config/routes.rb is NOT patched — routes are added with
# Rails.application.routes.append, the same pattern the SSO overlay uses.
#
# ROLLBACK: set MCP_OAUTH_ENABLED=false (or remove it) in /opt/docuseal/.env and
# `docker compose up -d`. Every endpoint below returns 404 and the /mcp hook
# becomes a no-op, leaving the static Bearer token path byte-identical to before
# Phase D. To remove the code as well, delete the whole "Phase D" mount block
# from docker-compose.yml — all of it, not parts of it, since the routes here
# name controllers that would then be missing.

# Never let an OAuth artifact reach the Rails log, even if a future change
# accidentally passes one through a controller. zz_sso_entra.rb adds an
# overlapping set later; the reject keeps this idempotent.
Rails.application.config.filter_parameters +=
  %i[
    code code_verifier code_challenge client_secret client_assertion assertion
    access_token refresh_token id_token authorization_request
  ].reject { |key| Rails.application.config.filter_parameters.include?(key) }

Rails.application.routes.append do
  # RFC 9728. Both the path-inserted and the root form are served: clients probe
  # the path-inserted one first, and the 401 challenge also points at the root one.
  get '/.well-known/oauth-protected-resource',
      to: 'sso/oauth_api#protected_resource_metadata', as: :mcp_oauth_protected_resource
  get '/.well-known/oauth-protected-resource/mcp',
      to: 'sso/oauth_api#protected_resource_metadata', as: :mcp_oauth_protected_resource_mcp

  # RFC 8414. MCP clients try this before OpenID Connect discovery, and
  # Anthropic's connector documentation names this path explicitly, so the
  # OpenID Connect alias is deliberately not served — we do not issue id_tokens
  # and would rather not publish a document claiming that we do.
  get '/.well-known/oauth-authorization-server',
      to: 'sso/oauth_api#authorization_server_metadata', as: :mcp_oauth_as_metadata

  # Matches /oauth/jwks.json via the implicit (.:format) segment.
  get  '/oauth/jwks',      to: 'sso/oauth_api#jwks',      as: :mcp_oauth_jwks
  post '/oauth/register',  to: 'sso/oauth_api#register',  as: :mcp_oauth_register
  post '/oauth/token',     to: 'sso/oauth_api#token',     as: :mcp_oauth_token

  get  '/oauth/authorize', to: 'sso/oauth#authorize',     as: :mcp_oauth_authorize
  post '/oauth/authorize', to: 'sso/oauth#decide',        as: :mcp_oauth_decide
end

# Extend the single authentication choke point for /mcp.
#
# McpController is an ActionController::Metal that only dispatches; all six MCP
# controllers (Mcp::ProtocolController plus the five in
# McpController::TOOL_CONTROLLERS) inherit Mcp::McpBaseController, whose
# #user_from_api_key resolves the acting user and whose #authenticate_user!
# renders the 401. Those are the two methods McpOauth::ControllerHook overrides.
#
# Runs in to_prepare, which Rails executes BEFORE eager loading
# (:run_prepare_callbacks precedes :eager_load! in the finisher hooks), so the
# prepend lands on the parent before any of the six subclasses are defined and is
# therefore visible to all of them.
#
# Applied unconditionally, not gated on McpOauth.enabled?, so that flipping
# MCP_OAUTH_ENABLED needs nothing but the container restart that
# `docker compose up -d` already performs. When the flag is off the hook is a
# no-op: it falls straight through to the upstream static-token lookup and adds
# no WWW-Authenticate header.
Rails.application.config.to_prepare do
  begin
    unless Mcp::McpBaseController.instance_variable_get(:@_icodos_mcp_oauth_patched)
      Mcp::McpBaseController.instance_variable_set(:@_icodos_mcp_oauth_patched, true)
      Mcp::McpBaseController.prepend(McpOauth::ControllerHook)
    end
  rescue NameError => e
    # Partial rollback (initializer mounted, lib/mcp_oauth.rb not) or an upstream
    # rename of Mcp::McpBaseController. Fail closed and loud: /mcp keeps working
    # with static Bearer tokens only, and OAuth tokens are simply never accepted.
    Rails.logger.error(
      "[mcp-oauth] could not install the /mcp authentication hook (#{e.class}: #{e.message.to_s[0, 120]}). " \
      'OAuth access tokens will NOT be accepted at /mcp. Static Bearer tokens are unaffected.'
    )
  end
end

Rails.application.config.after_initialize do
  begin
    if ENV['MCP_OAUTH_ENABLED'].to_s.strip.casecmp('true').zero?
      if McpOauth.enabled?
        Rails.logger.info(
          "[mcp-oauth] enabled. issuer=#{McpOauth.issuer} resource=#{McpOauth.resource} " \
          "kid=#{McpOauth.current_kid[0, 12]} access_ttl=#{McpOauth.access_token_ttl}s " \
          "refresh_ttl=#{McpOauth.refresh_token_ttl}s redirect_hosts=#{McpOauth.allowed_redirect_hosts.join(',')}"
        )

        # Upstream config/puma.rb runs a cluster when EITHER of these is set, and
        # each worker then gets its own MemoryStore.
        clustered = ENV['WEB_CONCURRENCY'].to_i > 1 || ENV['WEB_CONCURRENCY_AUTO'] == 'true'

        if clustered
          Rails.logger.warn(
            '[mcp-oauth] Puma is configured to run a worker cluster (WEB_CONCURRENCY / ' \
            'WEB_CONCURRENCY_AUTO). Rails.cache is a per-process MemoryStore here, so the single-use guard ' \
            'for authorization codes, consent tokens and rotated refresh tokens is no longer shared between ' \
            'workers. Authorization codes stay bound by PKCE, redirect_uri and a 60s lifetime, but replay ' \
            'detection is weakened. Use a shared cache store, or keep Puma single-process.'
          )
        end
      end
      # The signing-key, cache-store and audience-collision failures each log
      # their own error from McpOauth.enabled?; calling it above is what surfaces
      # them at boot rather than on the first request.
    else
      Rails.logger.info(
        '[mcp-oauth] disabled (MCP_OAUTH_ENABLED is not "true"). /mcp accepts static Bearer tokens only.'
      )
    end
  rescue NameError => e
    Rails.logger.error(
      "[mcp-oauth] lib/mcp_oauth.rb is not available (#{e.class}). The OAuth layer is inactive; " \
      '/mcp continues to accept static Bearer tokens only.'
    )
  end
end
