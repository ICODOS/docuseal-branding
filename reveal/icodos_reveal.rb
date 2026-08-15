# frozen_string_literal: true

# ICODOS — reveal the DocuSeal API key with a fresh Entra sign-in instead of a
# password.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_reveal.rb.
#
# WHY THIS EXISTS
# Upstream gates the API key behind current_user.valid_password?. SSO-provisioned
# users are created with password: SecureRandom.hex(16) — a value nobody ever
# sees — so that check can never succeed for them, and SSO_ENFORCE blocks the
# "Forgot password?" flow that would otherwise let them set one. The key is
# therefore unreachable for every user except the break-glass admin.
#
# WHAT THE PASSWORD PROMPT WAS FOR, AND WHAT THIS MUST PRESERVE
# The API key is a long-lived bearer credential with full account access. The
# prompt exists so that a live session is NOT sufficient to walk away with it:
# an attacker holding a stolen cookie, or sitting at an unlocked laptop, has to
# prove identity again. The requirement is therefore *fresh proof of identity at
# the moment of reveal*, not "is this request authenticated".
#
# A replacement that merely checks current_user is present would look equivalent
# and be a straight downgrade. This one:
#
#   1. sends prompt=login and max_age=0, and then VERIFIES the auth_time claim —
#      prompt is a request to the IdP, only the claim is evidence;
#   2. requires the re-authenticated Microsoft identity to match the DocuSeal
#      user already signed in, so a bystander cannot authenticate as themselves
#      to unlock someone else's session;
#   3. issues a single-use grant with a two-minute life.
#
# ROLLBACK: unset ICODOS_SSO_REVEAL_ENABLED in /opt/docuseal/.env and
# `docker compose up -d`. The upstream password dialog returns unchanged.

module IcodosReveal
  class Error < StandardError; end

  ENV_FLAG = 'ICODOS_SSO_REVEAL_ENABLED'

  # Marks an /auth/entra round trip as a re-authentication for the API key
  # rather than a sign-in.
  PURPOSE = 'reveal_api_key'

  # How recently Microsoft must have actually authenticated the person. Entra
  # returns auth_time only when max_age is sent, which is why both are used.
  AUTH_TIME_MAX_AGE = 120

  # Clock skew allowance for an auth_time in the future.
  AUTH_TIME_FUTURE_SKEW = 60

  # Life of the grant between callback and reveal.
  GRANT_TTL = 120

  # How long the whole round trip may take before the intent is stale.
  INTENT_TTL = 300

  # Reveal attempts allowed per user per minute.
  RATE_LIMIT = 5

  CACHE_PREFIX = 'icodos_reveal:grant:'
  RATE_PREFIX  = 'icodos_reveal:rate:'

  module_function

  # False unless the operator opted in, SSO is actually configured, and the
  # cache can enforce single use. Fails closed on every count: the whole point
  # of the feature is a security control, so it must not quietly degrade into a
  # weaker one. When false, the upstream password dialog is served untouched.
  def enabled?
    return false unless ENV[ENV_FLAG].to_s.strip.casecmp('true').zero?

    unless defined?(::Sso) && ::Sso.configured?
      warn_once(:unconfigured,
                "#{ENV_FLAG}=true but Entra SSO is not configured; the password dialog stays in place")
      return false
    end

    single_use_enforceable?
  rescue StandardError => e
    warn_once(:enabled_error, "could not determine reveal availability (#{e.class}: #{e.message})")

    false
  end

  # Same probe as Phase D's replay guard: a cache store that ignores
  # unless_exist cannot make a grant single-use, and a replayable grant is a
  # materially weaker control than the password it replaces.
  def single_use_enforceable?
    return @single_use_enforceable unless @single_use_enforceable.nil?

    probe = "#{CACHE_PREFIX}probe:#{SecureRandom.hex(8)}"
    first  = Rails.cache.write(probe, true, unless_exist: true, expires_in: 60)
    second = Rails.cache.write(probe, true, unless_exist: true, expires_in: 60)
    Rails.cache.delete(probe)

    @single_use_enforceable = (first == true && second == false)

    unless @single_use_enforceable
      Rails.logger.error(
        "[icodos-reveal] the configured cache store (#{Rails.cache.class}) does not honour " \
        'write(unless_exist: true), so a reveal grant could not be enforced as single-use. ' \
        'Refusing to enable SSO reveal; the password dialog stays in place.'
      )
    end

    @single_use_enforceable
  end

  def grant_key(jti)
    "#{CACHE_PREFIX}#{jti}"
  end

  def mint_grant!(user_id)
    raise Error, 'no user for grant' if user_id.blank?

    jti = SecureRandom.urlsafe_base64(32)

    stored = Rails.cache.write(grant_key(jti), user_id.to_i, unless_exist: true, expires_in: GRANT_TTL)

    raise Error, 'could not store reveal grant' unless stored

    jti
  end

  # Consumes unconditionally — a failed match still burns the grant, so a
  # mismatched or guessed jti cannot be retried against a different session.
  def consume_grant!(jti, user_id)
    return false if jti.blank? || user_id.blank?

    stored = Rails.cache.read(grant_key(jti))
    Rails.cache.delete(grant_key(jti))

    stored.present? && stored.to_i == user_id.to_i
  end

  # auth_time is seconds since the epoch, per OIDC. Absent means the IdP did not
  # confirm when it last authenticated the person, which is not good enough here.
  def fresh_auth?(auth_time, now: Time.now.to_i)
    seconds = auth_time.to_i

    return false if seconds <= 0
    return false if seconds > now + AUTH_TIME_FUTURE_SKEW

    (now - seconds) <= AUTH_TIME_MAX_AGE
  end

  def intent_valid?(intent, user_id, now: Time.now.to_i)
    return false if intent.blank? || user_id.blank?

    intent = intent.with_indifferent_access if intent.respond_to?(:with_indifferent_access)

    return false if intent['exp'].to_i < now
    return false if intent['user_id'].to_i != user_id.to_i

    true
  end

  def build_intent(user_id, now: Time.now.to_i)
    { 'user_id' => user_id.to_i, 'exp' => now + INTENT_TTL }
  end

  # Deliberately per-user rather than a controller-level rate_limit macro, which
  # would throttle every Entra sign-in rather than just reveal attempts.
  def rate_limited?(user_id)
    key = "#{RATE_PREFIX}#{user_id}:#{Time.now.to_i / 60}"

    Rails.cache.write(key, 0, unless_exist: true, expires_in: 120)

    Rails.cache.increment(key, 1).to_i > RATE_LIMIT
  rescue StandardError => e
    # A broken counter must not become an open door.
    Rails.logger.error("[icodos-reveal] rate limiting unavailable (#{e.class}); refusing the attempt")

    true
  end

  def warn_once(key, message)
    @warned ||= {}

    return if @warned[key]

    @warned[key] = true

    Rails.logger.error("[icodos-reveal] #{message}")
  end

  # Prepended onto RevealAccessTokenController.
  #
  # Lives in THIS file rather than its own: Zeitwerk maps lib/foo.rb to the
  # constant Foo, so a separate lib/icodos_reveal_patch.rb would have to define
  # IcodosRevealPatch, not IcodosReveal::RevealAccessTokenPatch. Getting that
  # wrong does not degrade gracefully — it raises at boot and the app will not
  # start at all. Defining it alongside its parent namespace avoids the trap.
  #
  # Deliberately small. It sets two instance variables the overridden
  # reveal_access_token/show view branches on, and otherwise defers to upstream —
  # including the whole password path, which stays available for accounts that
  # have a real password.
  #
  # #create is NOT touched, so upstream's rate limiting and valid_password?
  # check remain exactly as shipped.
  module RevealAccessTokenPatch
    def show
      if IcodosReveal.enabled?
        @icodos_reveal_available = true
        @icodos_reveal_token = consume_icodos_reveal_grant
      end

      super
    end

    private

    # Returns the API key if this request carries a valid, unused grant.
    #
    # The grant is consumed whether or not it matches, so a guessed or replayed
    # jti gets exactly one attempt. The session binding means holding the jti
    # alone is not enough — it has to arrive in the browser session it was
    # minted for.
    def consume_icodos_reveal_grant
      jti = session.delete(Sso::EntraAuthController::SESSION_REVEAL_GRANT_KEY)

      return nil if jti.blank? || current_user.nil?

      unless IcodosReveal.consume_grant!(jti, current_user.id)
        Rails.logger.warn("[icodos-reveal] rejected grant for user_id=#{current_user.id} (expired, used or mismatched)")

        return nil
      end

      # Worth an audit line: this is the moment a long-lived credential with
      # full account access becomes visible. Upstream logs nothing here.
      Rails.logger.info("[icodos-reveal] API key revealed to user_id=#{current_user.id} after Entra re-authentication")

      current_user.access_token.token
    rescue StandardError => e
      Rails.logger.error("[icodos-reveal] grant consumption failed (#{e.class}: #{e.message})")

      nil
    end
  end
end
