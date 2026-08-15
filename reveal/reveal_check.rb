# frozen_string_literal: true

# ICODOS — smoke check for the SSO API-key reveal.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_reveal_check.rb.
#
# NOTE ON THE FILENAME: Zeitwerk maps lib/icodos_reveal_check.rb to the constant
# IcodosRevealCheck. Naming these two out of step does not degrade — it raises
# at boot and the container will not start. That cost 45 seconds of downtime on
# 15 August 2026.
#
# Run after any enable, restart or DocuSeal version bump:
#
#   docker compose exec app bin/rails runner \
#     'require "icodos_reveal_check"; IcodosRevealCheck.call'
#
# The failure this exists to catch is a version bump that quietly detaches the
# prepend or leaves a stale view override. From a user's side that looks like a
# password box they have no password for — not like a broken deployment.

module IcodosRevealCheck
  VIEW_PATH = '/app/app/views/reveal_access_token/show.html.erb'
  VIEW_MARKER = 'ICODOS override'

  module_function

  def call
    @failed = false

    puts "\nICODOS — SSO API key reveal check\n\n"

    step('feature enabled') do
      raise "#{IcodosReveal::ENV_FLAG} is not true, or a precondition failed" unless IcodosReveal.enabled?

      "auth_time<=#{IcodosReveal::AUTH_TIME_MAX_AGE}s grant=#{IcodosReveal::GRANT_TTL}s " \
        "rate=#{IcodosReveal::RATE_LIMIT}/min"
    end

    step('SSO configured') do
      raise 'Entra SSO is not configured' unless defined?(::Sso) && ::Sso.configured?

      # Stated as what it means, not as a flag to be mentally inverted. An
      # earlier version printed break_glass=true when break-glass was OFF.
      "enforced=#{::Sso.enforced?}, password login " \
        "#{::Sso.password_login_allowed? ? 'ALLOWED (break-glass or not enforced)' : 'blocked'}"
    end

    # Rails.cache here is MemoryStore — per-process and lost on restart — which
    # is exactly why grants do not live in it.
    step('guard store is Redis and atomic') do
      raise 'guard store not ready' unless IcodosReveal.guard_store_ready?

      version = ::Sidekiq.redis { |c| c.call('INFO', 'server') }.to_s[/redis_version:([0-9.]+)/, 1]

      "redis #{version} (Rails.cache is #{Rails.cache.class.name.split('::').last}, deliberately unused)"
    end

    step('grant is single-use') do
      jti = IcodosReveal.mint_grant!(0)

      raise 'a fresh grant was not accepted' unless IcodosReveal.consume_grant!(jti, 0)
      raise 'a consumed grant was accepted twice' if IcodosReveal.consume_grant!(jti, 0)

      jti2 = IcodosReveal.mint_grant!(0)

      raise 'a grant was accepted for the wrong user' if IcodosReveal.consume_grant!(jti2, 999)
      raise 'a mismatched attempt left the grant usable' if IcodosReveal.consume_grant!(jti2, 0)

      'mint, consume, replay and cross-user all behaved'
    end

    step('controller patch attached') do
      unless RevealAccessTokenController.ancestors.include?(IcodosReveal::RevealAccessTokenPatch)
        raise 'the prepend is NOT attached — users would see a password box they cannot fill'
      end

      'prepended'
    end

    # A stale override renders an old layout with no error anywhere, so it is
    # asserted rather than assumed.
    step('view override in place') do
      raise "#{VIEW_PATH} is missing" unless File.exist?(VIEW_PATH)

      contents = File.read(VIEW_PATH)

      raise 'the mounted view is not the ICODOS override' unless contents.include?(VIEW_MARKER)

      unless contents.include?('IcodosReveal::PURPOSE')
        raise 'the override is present but no longer links to the re-authentication flow'
      end

      "#{contents.lines.count} lines, override marker found"
    end

    step('re-auth URL carries the freshness parameters') do
      uri = Sso::EntraAuthController::OidcClient.new.authorization_uri(
        state: 'probe', nonce: 'probe', code_challenge: 'probe',
        redirect_uri: 'https://example.invalid/cb', scope: 'openid',
        prompt: 'login', max_age: 0
      )

      raise 'prompt=login missing' unless uri.include?('prompt=login')
      raise 'max_age missing — Entra would not return auth_time' unless uri.include?('max_age=0')

      'prompt=login and max_age=0'
    end

    puts "\n#{@failed ? 'FAILED — see above' : 'All checks passed.'}\n\n"

    !@failed
  end

  def step(label)
    detail = yield
    puts format('  %-42s ok    %s', label, detail)
  rescue StandardError => e
    @failed = true
    puts format('  %-42s FAIL  %s: %s', label, e.class.name.split('::').last, e.message)
  end
end
