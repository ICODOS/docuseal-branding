# frozen_string_literal: true

# ICODOS MCP OAuth 2.1 layer for self-hosted DocuSeal.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/mcp_oauth.rb — no image rebuild, no new gems.
#
# This module makes sign.icodos.com act as BOTH:
#   * an OAuth 2.1 authorization server (Strategy B), and
#   * the OAuth 2.1 resource server guarding /mcp,
# with Microsoft Entra ID doing the actual user authentication via the
# existing SSO overlay (sso/entra_auth_controller.rb), which is not modified.
#
# Why we are the authorization server rather than pointing clients at Entra:
#   * MCP clients MUST send RFC 8707 `resource=https://sign.icodos.com/mcp`.
#     Entra rejects that unless the MCP URL is registered as an Application ID
#     URI on the app registration (AADSTS9010010), and without a custom exposed
#     scope the token Entra returns is audienced at Microsoft Graph, not at us.
#     Accepting such a token would be the token-passthrough / confused-deputy
#     pattern the MCP authorization spec forbids.
#   * Entra has no RFC 7591 dynamic client registration endpoint. We do.
# Net effect: zero Azure changes — same tenant, client id, secret and redirect URI.
#
# Design notes that matter for review:
#   * Everything is STATELESS. Authorization codes, refresh tokens and client
#     registrations are signed/MAC'd artifacts, not database rows. No migration,
#     nothing written to the DocuSeal database, so the blast radius on an
#     instance holding executed contracts is nil.
#   * Three token types, separated by BOTH a `token_use` claim AND a distinct
#     `aud`, so no artifact can be replayed at an endpoint it was not minted for:
#       code    -> aud = token endpoint, token_use = "code",    60s
#       refresh -> aud = token endpoint, token_use = "refresh", 14d absolute
#       access  -> aud = resource URL,   token_use = "access",  1h
#   * Signing key is an RSA private key mounted read-only from outside this
#     repo. It is never committed and never logged.
#
# Env (all optional except MCP_OAUTH_ENABLED):
#   MCP_OAUTH_ENABLED                    "true" turns the whole layer on. Default off.
#   MCP_OAUTH_SIGNING_KEY_PATH           default /app/config/icodos/mcp_oauth_signing_key.pem
#   MCP_OAUTH_PREVIOUS_SIGNING_KEY_PATH  optional, published in JWKS during rotation
#   MCP_OAUTH_ISSUER                     default derived from Docuseal.default_url_options
#   MCP_OAUTH_RESOURCE                   default "<issuer>/mcp"
#   MCP_OAUTH_ALLOWED_REDIRECT_HOSTS     comma separated; default claude.ai,claude.com (loopback NOT included)
#   MCP_OAUTH_ACCESS_TOKEN_TTL           seconds, default 3600
#   MCP_OAUTH_REFRESH_TOKEN_TTL          seconds, default 1209600 (14 days, absolute — rotation does not extend)
module McpOauth
  # Any token/client artifact we refuse. Deliberately carries no detail that
  # would help an attacker distinguish failure modes.
  class Error < StandardError; end

  # Raised only when the token itself was cryptographically fine but the
  # DocuSeal account behind it may not authenticate. Surfaces the same wording
  # the SSO overlay uses so the two paths behave identically.
  class AccountBlocked < Error; end

  ARCHIVED_MESSAGE =
    'Your account has been archived. Contact your administrator to restore access.'

  SIGNING_ALG = 'RS256'
  JWT_LEEWAY  = 60

  CODE_TTL            = 60
  DEFAULT_ACCESS_TTL  = 3600
  DEFAULT_REFRESH_TTL = 14 * 24 * 60 * 60
  MAX_ACCESS_TTL      = 24 * 60 * 60
  MAX_REFRESH_TTL     = 90 * 24 * 60 * 60

  TOKEN_USE_ACCESS  = 'access'
  TOKEN_USE_REFRESH = 'refresh'
  TOKEN_USE_CODE    = 'code'
  # Carries the already-validated authorization request across the consent
  # screen. Not a credential: redeeming it still requires a live DocuSeal
  # session and a valid Rails CSRF token. Signed so the browser cannot tamper
  # with the redirect_uri, scope or PKCE challenge between GET and POST, and
  # kept out of the session cookie so a long client_id can never overflow it.
  TOKEN_USE_AUTHZ_REQUEST = 'authz_request'
  AUTHZ_REQUEST_TTL = 600

  SCOPE_MCP     = 'mcp'
  SCOPE_OFFLINE = 'offline_access'

  # Scopes the authorization server will grant.
  SUPPORTED_SCOPES = [SCOPE_MCP, SCOPE_OFFLINE].freeze
  # Scopes advertised in protected resource metadata. Per the MCP spec,
  # `offline_access` is deliberately NOT advertised here — refresh tokens are a
  # client concern, not a requirement of this resource.
  RESOURCE_SCOPES = [SCOPE_MCP].freeze

  DEFAULT_KEY_PATH = '/app/config/icodos/mcp_oauth_signing_key.pem'

  # Loopback (localhost / 127.0.0.1 / ::1) is deliberately NOT in the default.
  # A loopback redirect_uri means "hand the authorization code to a process on
  # the user's own machine", and any local process can bind a port and claim to
  # be a legitimate client — so combined with open dynamic registration it is a
  # one-click consent-phishing route to an admin-equivalent grant. The hosted
  # Claude surfaces (claude.ai / Desktop / mobile / Cowork) all use the
  # claude.ai callback, so nothing we need is lost. Add loopback back via
  # MCP_OAUTH_ALLOWED_REDIRECT_HOSTS only if a local MCP client actually needs it.
  DEFAULT_ALLOWED_REDIRECT_HOSTS = %w[claude.ai claude.com].freeze

  CLIENT_ID_PREFIX = 'icd1'
  CLIENT_ID_MAC_CONTEXT = 'icodos-mcp-oauth/client-id/v1'

  GRANT_TYPES = %w[authorization_code refresh_token].freeze

  # A registered redirect_uri may carry a query string, but not one that would
  # collide with the parameters we append to it — otherwise the client receives
  # a duplicated `code`/`state`/`iss` and first-vs-last-wins parsing decides
  # which one it acts on.
  RESERVED_REDIRECT_QUERY_KEYS = %w[code state error error_description iss].freeze

  # These bounds exist for a specific reason, not as arbitrary hygiene.
  # A client_id embeds its registered redirect_uris, and /oauth/authorize hands
  # the whole authorize URL to the SSO overlay as a `return_to` that lands in
  # Rails' 4 KB cookie session. Generous limits here overflow that cookie and
  # turn into a 500. Keep the product of these small.
  MAX_CLIENT_ID_LENGTH    = 1024
  MAX_REDIRECT_URIS       = 3
  MAX_REDIRECT_URI_LENGTH = 256
  MAX_REGISTRATION_BYTES  = 8192
  MAX_STATE_LENGTH        = 256
  MAX_CLIENT_NAME_LENGTH  = 120
  # Hard ceiling on the authorize URL we are willing to round-trip through the
  # session cookie. Legitimate registrations produce ~400 bytes.
  MAX_AUTHORIZE_URL_BYTES = 1500

  # The JWKS loader re-reads key material when a token names an unknown `kid`,
  # which is attacker-reachable: any Bearer JWT with a random kid gets there.
  # Debounced so a flood cannot become a mutex-serialised disk read plus RSA
  # parse (and a log line) per request. A real key rotation is picked up within
  # this window, and a container restart picks it up immediately.
  KEY_RELOAD_DEBOUNCE = 60

  # RFC 7636: verifier is 43-128 chars of unreserved; S256 challenge is
  # unpadded base64url of a SHA-256 digest, therefore exactly 43 chars.
  PKCE_VERIFIER_RE  = /\A[A-Za-z0-9\-._~]{43,128}\z/
  PKCE_CHALLENGE_RE = /\A[A-Za-z0-9\-_]{43}\z/

  # A JWS compact serialization and nothing else. Used only to decide whether
  # it is worth attempting OAuth verification at all — DocuSeal's own static
  # MCP tokens are 43 chars of base58 and contain no dots. This never relaxes
  # any validation; anything that fails this check could not be a valid JWT.
  JWS_SHAPE_RE = /\A[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\z/

  KEY_MUTEX = Mutex.new

  Principal = Struct.new(:user, :client_id, :scope, :jti, keyword_init: true)
  Client    = Struct.new(:client_id, :redirect_uris, :grant_types, :name, :issued_at, keyword_init: true)

  module_function

  # ---------------------------------------------------------------- configuration

  # False unless the operator opted in AND the signing key is actually usable.
  # A missing or broken key degrades to "OAuth off, static Bearer tokens keep
  # working" rather than 500s across /mcp. The boot warning in the initializer
  # makes the misconfiguration visible.
  def enabled?
    return false unless ENV['MCP_OAUTH_ENABLED'].to_s.strip.casecmp('true').zero?
    return false unless replay_guard_functional?
    return false unless audiences_distinct?

    signing_key.present?
  rescue Error => e
    unless @key_warning_logged
      @key_warning_logged = true
      Rails.logger.error("[mcp-oauth] MCP_OAUTH_ENABLED=true but the signing key is unusable (#{e.message}). " \
                         'The OAuth layer stays OFF; static Bearer MCP tokens are unaffected.')
    end

    false
  end

  # Single-use enforcement for authorization codes, refresh tokens and consent
  # tokens all rest on `Rails.cache.write(..., unless_exist: true)` returning
  # false the second time. A NullStore returns true unconditionally, which would
  # silently turn every replay check into a no-op. Refuse to enable rather than
  # run with the guard quietly disabled.
  def replay_guard_functional?
    return @replay_guard_functional unless @replay_guard_functional.nil?

    probe = "mcp_oauth:guard_probe:#{SecureRandom.hex(8)}"
    first  = Rails.cache.write(probe, true, unless_exist: true, expires_in: 60)
    second = Rails.cache.write(probe, true, unless_exist: true, expires_in: 60)
    Rails.cache.delete(probe)

    @replay_guard_functional = (first == true && second == false)

    unless @replay_guard_functional
      Rails.logger.error(
        "[mcp-oauth] the configured Rails cache store (#{Rails.cache.class}) does not honour " \
        'write(unless_exist: true), so authorization codes and refresh tokens could not be enforced as ' \
        'single-use. Refusing to enable the OAuth layer. Static Bearer MCP tokens are unaffected.'
      )
    end

    @replay_guard_functional
  end

  # The three token types are kept apart by `token_use` AND by a distinct `aud`.
  # A misconfigured MCP_OAUTH_RESOURCE that collided with one of our endpoint
  # URLs would collapse that second layer, so treat it as a fatal misconfiguration.
  def audiences_distinct?
    auds = [resource, token_endpoint, authorization_endpoint]
    return true if auds.uniq.length == auds.length

    unless @audience_warning_logged
      @audience_warning_logged = true
      Rails.logger.error(
        "[mcp-oauth] MCP_OAUTH_RESOURCE (#{resource}) collides with an OAuth endpoint URL. That would remove the " \
        'audience separation between access tokens, authorization codes and refresh tokens. Refusing to enable.'
      )
    end

    false
  end

  def issuer
    @issuer ||= (ENV['MCP_OAUTH_ISSUER'].presence || default_origin).to_s.strip.chomp('/')
  end

  def resource
    @resource ||= (ENV['MCP_OAUTH_RESOURCE'].presence || "#{issuer}/mcp").to_s.strip.chomp('/')
  end

  def authorization_endpoint
    "#{issuer}/oauth/authorize"
  end

  def token_endpoint
    "#{issuer}/oauth/token"
  end

  def registration_endpoint
    "#{issuer}/oauth/register"
  end

  def jwks_uri
    "#{issuer}/oauth/jwks.json"
  end

  def protected_resource_metadata_url
    "#{issuer}/.well-known/oauth-protected-resource"
  end

  # Both TTLs are clamped. Without a ceiling, a typo in .env
  # (MCP_OAUTH_ACCESS_TOKEN_TTL=36000000) would silently mint a multi-year
  # bearer token that no mechanism short of a key rotation can withdraw.
  def access_token_ttl
    clamped_ttl('MCP_OAUTH_ACCESS_TOKEN_TTL', DEFAULT_ACCESS_TTL, MAX_ACCESS_TTL)
  end

  def refresh_token_ttl
    clamped_ttl('MCP_OAUTH_REFRESH_TOKEN_TTL', DEFAULT_REFRESH_TTL, MAX_REFRESH_TTL)
  end

  def clamped_ttl(env_key, default, ceiling)
    value = positive_int(ENV.fetch(env_key, nil), default)
    return value if value <= ceiling

    @ttl_warnings ||= {}
    unless @ttl_warnings[env_key]
      @ttl_warnings[env_key] = true
      Rails.logger.warn("[mcp-oauth] #{env_key}=#{value} exceeds the #{ceiling}s ceiling; clamping to #{ceiling}.")
    end

    ceiling
  end

  def allowed_redirect_hosts
    @allowed_redirect_hosts ||=
      begin
        raw = ENV['MCP_OAUTH_ALLOWED_REDIRECT_HOSTS'].to_s.split(',').map { |h| h.strip.downcase }.reject(&:empty?)
        (raw.presence || DEFAULT_ALLOWED_REDIRECT_HOSTS).freeze
      end
  end

  def default_origin
    opts     = Docuseal.default_url_options
    protocol = opts[:protocol].to_s.sub(%r{://\z}, '').presence || 'https'
    origin   = "#{protocol}://#{opts[:host]}"
    port     = opts[:port]
    origin += ":#{port}" if port.present? && !%w[80 443].include?(port.to_s)
    origin
  end

  def positive_int(raw, fallback)
    value = raw.to_s.strip
    return fallback unless value.match?(/\A\d+\z/)

    value.to_i.positive? ? value.to_i : fallback
  end

  # ------------------------------------------------------------------------ keys

  # Fast path without the mutex once memoized — this is on every /mcp request
  # and every token mint, and the mutex would otherwise serialise all of them.
  def signing_key
    @signing_key || KEY_MUTEX.synchronize do
      @signing_key ||= begin
        key = load_key!(signing_key_path)
        # Record the mtime we loaded, so reload_keys! can no-op on a kid flood
        # against an unchanged file.
        @loaded_key_mtime = key_file_mtime
        key
      end
    end
  end

  def previous_signing_key
    path = ENV['MCP_OAUTH_PREVIOUS_SIGNING_KEY_PATH'].to_s.strip
    return nil if path.empty?
    # `@previous_key_failed` memoizes the NEGATIVE result too. Without it an
    # unusable previous-key file is re-read and re-parsed on every single call,
    # because `@x ||= nil` never memoizes.
    return nil if @previous_key_failed

    @previous_signing_key || KEY_MUTEX.synchronize do
      @previous_signing_key ||= begin
        load_key!(path)
      rescue Error => e
        @previous_key_failed = true
        Rails.logger.error("[mcp-oauth] previous signing key unusable (#{e.message}); ignoring it")
        nil
      end
    end
  end

  def signing_key_path
    ENV['MCP_OAUTH_SIGNING_KEY_PATH'].presence || DEFAULT_KEY_PATH
  end

  def load_key!(path)
    raise Error, 'signing key file missing' unless File.exist?(path)

    key = OpenSSL::PKey::RSA.new(File.read(path))
    raise Error, 'signing key is not a private key' unless key.private?
    raise Error, 'signing key shorter than 2048 bits' if key.n.num_bits < 2048

    key
  rescue OpenSSL::PKey::RSAError
    raise Error, 'signing key is not a readable RSA PEM'
  rescue SystemCallError
    raise Error, 'signing key file not readable'
  end

  # Drop memoized key material so a rotated key file is picked up without a
  # container restart.
  #
  # Reached from the JWKS loader on a `kid` miss, which is ATTACKER-CONTROLLED:
  # any unauthenticated request to /mcp carrying a JWS with a random `kid` gets
  # here, and /mcp has no rate limiting. Unguarded, each such request would cost
  # a mutex-serialised disk read plus a 3072-bit RSA parse plus two RFC 7638
  # thumbprints plus a log line — a cheap remote amplification against a
  # single-process Puma, and unbounded attacker-driven log growth.
  #
  # Two guards, both required:
  #   * a cache-based debounce, so at most one reload per KEY_RELOAD_DEBOUNCE
  #     seconds regardless of request volume;
  #   * an mtime check, so a flood of unknown kids against an unchanged key file
  #     does no work at all and logs nothing.
  # A genuine rotation is still picked up within the debounce window, and a
  # container restart picks it up immediately.
  def reload_keys!
    return unless Rails.cache.write('mcp_oauth:key_reload', true, unless_exist: true,
                                                                 expires_in: KEY_RELOAD_DEBOUNCE)

    current_mtime = key_file_mtime
    return if current_mtime && current_mtime == @loaded_key_mtime

    KEY_MUTEX.synchronize do
      @signing_key = nil
      @previous_signing_key = nil
      @previous_key_failed = nil
      @client_id_keys = nil
      @current_kid = nil
      @loaded_key_mtime = current_mtime
    end

    Rails.logger.info('[mcp-oauth] signing key file changed on disk; reloaded key material')
  end

  def key_file_mtime
    File.mtime(signing_key_path).to_f
  rescue SystemCallError
    nil
  end

  def key_set
    [signing_key, previous_signing_key].compact
  end

  def current_kid
    @current_kid ||= JWT::JWK.new(signing_key.public_key).kid
  end

  def public_jwks
    key_set.map do |key|
      JWT::JWK.new(key.public_key).export.merge(use: 'sig', alg: SIGNING_ALG)
    end
  end

  # ---------------------------------------------------------------- client ids
  #
  # A client_id is a compact MAC'd blob, not a database row:
  #   icd1.<base64url(json)>.<base64url(HMAC-SHA256)>
  # It carries the registered redirect_uris, so /oauth/authorize can validate a
  # redirect_uri without any stored state. The MAC key is derived from the RSA
  # signing key, which means rotating the signing key invalidates every
  # registered client — they simply re-register via DCR on the next connect.

  def client_id_keys
    @client_id_keys ||= key_set.map do |key|
      OpenSSL::HMAC.digest('SHA256', key.to_der, CLIENT_ID_MAC_CONTEXT)
    end
  end

  def register_client(redirect_uris:, name:, grant_types:, now: Time.now.to_i)
    payload = {
      'u' => redirect_uris,
      'n' => sanitize_client_name(name),
      'g' => grant_types,
      't' => now
    }
    body   = b64(JSON.generate(payload))
    signed = "#{CLIENT_ID_PREFIX}.#{body}"

    "#{signed}.#{b64(OpenSSL::HMAC.digest('SHA256', client_id_keys.first, signed))}"
  end

  # A client_name is attacker-chosen (registration is open) and is rendered as
  # the requesting party on the consent screen. ERB escaping stops it being
  # markup, but bidi overrides and zero-width characters would still let it be
  # shaped to look like something it is not, so strip anything non-printable.
  def sanitize_client_name(name)
    # Control characters, bidi overrides (U+202A-U+202E, U+2066-U+2069),
    # zero-width joiners/spaces (U+200B-U+200F) and the BOM (U+FEFF) are all
    # stripped: they cannot become markup, but they can be used to shape a name
    # so it reads as something it is not.
    cleaned = name.to_s.unicode_normalize(:nfkc)
                  .gsub(/[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/, '')
                  .gsub(/\s+/, ' ')
                  .strip

    cleaned.empty? ? 'Unnamed MCP client' : cleaned[0, MAX_CLIENT_NAME_LENGTH]
  rescue ArgumentError, Encoding::CompatibilityError
    'Unnamed MCP client'
  end

  # Returns a Client or nil. nil means "no such client" — callers must map that
  # to invalid_client and MUST NOT redirect anywhere on the strength of it.
  def parse_client(client_id)
    raw = client_id.to_s
    return nil if raw.empty? || raw.bytesize > MAX_CLIENT_ID_LENGTH

    prefix, body, mac = raw.split('.', 3)
    return nil unless prefix == CLIENT_ID_PREFIX && body.present? && mac.present?

    # MAC is verified BEFORE the body is base64-decoded and JSON-parsed, so
    # unauthenticated input never reaches the parser.
    signed = "#{prefix}.#{body}"
    valid  = client_id_keys.any? do |k|
      ActiveSupport::SecurityUtils.secure_compare(b64(OpenSSL::HMAC.digest('SHA256', k, signed)), mac)
    end
    return nil unless valid

    data = JSON.parse(Base64.urlsafe_decode64(body))
    return nil unless data.is_a?(Hash)

    # Re-filtering through valid_redirect_uri? means narrowing the host allowlist
    # retroactively invalidates client_ids that were registered under the old one.
    uris = Array(data['u']).map(&:to_s).select { |u| valid_redirect_uri?(u) }
    return nil if uris.empty?

    grants = Array(data['g']).map(&:to_s) & GRANT_TYPES
    return nil if grants.empty?

    Client.new(client_id: raw, redirect_uris: uris.freeze, grant_types: grants.freeze,
               name: sanitize_client_name(data['n']), issued_at: data['t'].to_i)
  rescue ArgumentError, JSON::ParserError
    nil
  end

  # -------------------------------------------------------------- redirect uris

  def valid_redirect_uri?(raw)
    value = raw.to_s
    return false if value.empty? || value.length > MAX_REDIRECT_URI_LENGTH
    return false if value.match?(/[[:space:]]/)

    uri = URI.parse(value)
    return false unless uri.absolute?
    return false unless uri.fragment.nil?
    return false if uri.userinfo.present?

    host = normalize_host(uri.host)
    return false if host.empty?
    return false unless allowed_redirect_hosts.include?(host)

    # A registered redirect_uri may carry a query string, but not one whose keys
    # collide with the parameters we append on the way back — otherwise the
    # client receives a duplicated code/state/iss and its first-vs-last-wins
    # parsing decides which value it acts on.
    if uri.query.present?
      keys = URI.decode_www_form(uri.query).map { |k, _| k.downcase }
      return false if keys.any? { |k| RESERVED_REDIRECT_QUERY_KEYS.include?(k) }
    end

    case uri.scheme
    when 'https' then true
    when 'http'  then loopback_host?(host) # RFC 8252 native-client loopback only
    else false
    end
  rescue URI::InvalidURIError, ArgumentError
    false
  end

  # URI.parse keeps the brackets on an IPv6 literal ("[::1]"), so normalise them
  # away for allowlist comparison. Without this an `::1` allowlist entry can
  # never match anything.
  def normalize_host(host)
    host.to_s.downcase.delete_prefix('[').delete_suffix(']')
  end

  def loopback_host?(host)
    %w[localhost 127.0.0.1 ::1].include?(normalize_host(host))
  end

  # Exact string match, except for RFC 8252 loopback redirects where the port is
  # chosen at runtime by the native client and must be ignored.
  #
  # The PRESENTED value is re-validated first. Without that, the loopback branch
  # below compared only scheme/host/path/query, so a registration of
  # `http://localhost/cb` would also match `http://user:pw@localhost:9/cb` and
  # `http://localhost/cb#frag` — values `valid_redirect_uri?` would have refused.
  def redirect_uri_registered?(client, given)
    value = given.to_s
    return false if value.empty?
    return false unless valid_redirect_uri?(value)

    client.redirect_uris.any? do |registered|
      next true if registered == value

      loopback_equivalent?(registered, value)
    end
  end

  def loopback_equivalent?(registered, given)
    r = URI.parse(registered)
    g = URI.parse(given)
    return false unless loopback_host?(r.host) && loopback_host?(g.host)
    return false unless r.userinfo.nil? && g.userinfo.nil?
    return false unless g.fragment.nil?

    r.scheme == g.scheme && normalize_host(r.host) == normalize_host(g.host) &&
      r.path == g.path && r.query == g.query
  rescue URI::InvalidURIError
    false
  end

  # ---------------------------------------------------------------------- scopes

  # Grant = requested ∩ supported. Unknown scope values are dropped rather than
  # rejected (RFC 6749 §3.3 allows the AS to narrow), but a grant that ends up
  # without `mcp` is refused by the caller as invalid_scope.
  def normalize_scope(requested)
    values = requested.to_s.split(/\s+/).map(&:strip).reject(&:empty?).uniq
    return [SCOPE_MCP] if values.empty?

    SUPPORTED_SCOPES & values
  end

  # ------------------------------------------------------------- token issuance

  def issue_access_token(user:, client_id:, scope:, now: Time.now.to_i)
    encode(
      {
        'iss' => issuer,
        'aud' => resource,
        'sub' => user.uuid,
        # No email claim: resolution uses `sub` (users.uuid) only, so carrying the
        # address would just put PII in a bearer token for no functional gain.
        'docuseal_user_id' => user.id,
        'client_id' => client_id,
        'scope' => scope,
        'token_use' => TOKEN_USE_ACCESS,
        'jti' => SecureRandom.uuid,
        'iat' => now,
        'nbf' => now,
        'exp' => now + access_token_ttl
      },
      typ: 'at+jwt'
    )
  end

  # `expires_at` is the absolute end of the grant, fixed at first consent.
  # Rotation issues a fresh token with the SAME exp, so a leaked refresh token
  # cannot be walked forward indefinitely.
  def issue_refresh_token(user:, client_id:, scope:, expires_at:, now: Time.now.to_i)
    encode(
      {
        'iss' => issuer,
        'aud' => token_endpoint,
        'sub' => user.uuid,
        'client_id' => client_id,
        'scope' => scope,
        'token_use' => TOKEN_USE_REFRESH,
        'jti' => SecureRandom.uuid,
        'iat' => now,
        'nbf' => now,
        'exp' => expires_at
      }
    )
  end

  def issue_code(user:, client_id:, redirect_uri:, code_challenge:, resource_value:, scope:, now: Time.now.to_i)
    encode(
      {
        'iss' => issuer,
        'aud' => token_endpoint,
        'sub' => user.uuid,
        'client_id' => client_id,
        'redirect_uri' => redirect_uri,
        'code_challenge' => code_challenge,
        'code_challenge_method' => 'S256',
        'resource' => resource_value,
        'scope' => scope,
        'token_use' => TOKEN_USE_CODE,
        'jti' => SecureRandom.uuid,
        'iat' => now,
        'nbf' => now,
        'exp' => now + CODE_TTL
      }
    )
  end

  def issue_authz_request(user:, client_id:, redirect_uri:, code_challenge:, resource_value:, scope:, state:,
                          now: Time.now.to_i)
    encode(
      {
        'iss' => issuer,
        'aud' => authorization_endpoint,
        'sub' => user.uuid,
        'client_id' => client_id,
        'redirect_uri' => redirect_uri,
        'code_challenge' => code_challenge,
        'resource' => resource_value,
        'scope' => scope,
        'state' => state,
        'token_use' => TOKEN_USE_AUTHZ_REQUEST,
        'jti' => SecureRandom.uuid,
        'iat' => now,
        'nbf' => now,
        'exp' => now + AUTHZ_REQUEST_TTL
      }
    )
  end

  def encode(claims, typ: 'JWT')
    # Derive the kid from the very key object we are signing with, rather than
    # reading the memoized `current_kid` separately. A concurrent reload_keys!
    # straddling the two reads could otherwise emit a token whose kid names the
    # new key while the signature came from the old one.
    key = signing_key

    JWT.encode(claims, key, SIGNING_ALG, { 'kid' => JWT::JWK.new(key.public_key).kid, 'typ' => typ })
  end

  # ---------------------------------------------------------- token verification
  #
  # Every verify_* flag is on and `algorithms` is pinned to RS256 only, which is
  # what blocks both alg=none and HMAC substitution (the jwt gem raises
  # JWT::IncorrectAlgorithm before it ever looks at the signature). Do not add
  # algorithms here and do not pass `false` as the third argument anywhere.
  # `required_claims` matters and is not belt-and-braces: the jwt gem's
  # expiration and not-before checks return early when the claim is ABSENT, so
  # without this a token carrying no `exp` at all verifies successfully and never
  # expires. Only this instance's private key can sign, so that is not reachable
  # today — but it means a future mint path that forgot `exp` would produce an
  # immortal token, and this makes that structurally impossible.
  REQUIRED_CLAIMS = %w[iss aud sub exp nbf iat jti token_use].freeze

  def verify_token!(token, expected_use:, expected_aud:)
    payload, header = JWT.decode(
      token.to_s,
      nil,
      true,
      algorithms: [SIGNING_ALG],
      iss: issuer,
      aud: expected_aud,
      verify_iss: true,
      verify_aud: true,
      verify_expiration: true,
      verify_not_before: true,
      verify_iat: true,
      required_claims: REQUIRED_CLAIMS,
      leeway: JWT_LEEWAY,
      jwks: jwks_loader
    )

    raise Error, 'unexpected token_use' unless payload.is_a?(Hash) && payload['token_use'] == expected_use
    raise Error, 'missing jti' if payload['jti'].to_s.empty?
    raise Error, 'missing sub' if payload['sub'].to_s.empty?

    [payload, header]
  rescue JWT::DecodeError => e
    raise Error, "token rejected (#{e.class})"
  end

  def jwks_loader
    lambda do |options|
      reload_keys! if options[:kid_not_found]

      { keys: public_jwks }
    end
  end

  # Single-use enforcement for authorization codes and rotated refresh tokens.
  # Returns true the first time a jti is seen, false on replay.
  #
  # Backed by Rails.cache, which on this deployment is a per-process MemoryStore
  # (`write(..., unless_exist: true)` is atomic within the process, and Puma runs
  # single-process here). It is therefore best-effort: it is lost on container
  # restart, and it would not be shared if WEB_CONCURRENCY were ever set above 1
  # — the initializer warns at boot if that happens. Replay is additionally
  # bounded by the 60s code lifetime, PKCE, and redirect_uri binding.
  def consume_jti!(jti, ttl:)
    consume_decision!(jti, true, ttl: ttl) == :first
  end

  # Same single-use guarantee as consume_jti!, but it records WHAT the answer was.
  # Returns :first when this call won the race, otherwise the value stored by
  # whoever won.
  #
  # This exists so a duplicate consent submission can be told "you already
  # approved this, it completed" rather than "authorization failed, nothing was
  # granted". The latter is what a second click on Allow used to produce, and it
  # is actively misleading: on that path the authorization had in fact succeeded
  # a fraction of a second earlier.
  def consume_decision!(jti, decision, ttl:)
    return :replay if jti.to_s.empty?

    key = "mcp_oauth:jti:#{Digest::SHA256.hexdigest(jti.to_s)}"
    return :first if Rails.cache.write(key, decision, unless_exist: true, expires_in: [ttl.to_i, 60].max)

    stored = Rails.cache.read(key)
    stored.nil? ? :replay : stored
  end

  # -------------------------------------------------- resource-server validation

  # Resolve the DocuSeal user an OAuth access token acts as, or nil if this is
  # not a valid OAuth access token. Raises AccountBlocked when the token was
  # cryptographically valid but the account may not authenticate, so the /mcp
  # hook can return the same wording the SSO overlay uses.
  def authenticate_request(request)
    return nil unless enabled?

    token = bearer_token(request)
    return nil if token.nil? || !token.match?(JWS_SHAPE_RE)

    payload, = verify_token!(token, expected_use: TOKEN_USE_ACCESS, expected_aud: resource)

    scopes = payload['scope'].to_s.split(/\s+/)
    unless scopes.include?(SCOPE_MCP)
      Rails.logger.warn('[mcp-oauth] access token carries no mcp scope')
      return nil
    end

    user = User.find_by(uuid: payload['sub'].to_s)
    if user.nil?
      Rails.logger.warn('[mcp-oauth] access token subject matches no DocuSeal user')
      return nil
    end

    unless user.active_for_authentication?
      # Archived users are not silently reactivated — same rule as the SSO overlay.
      Rails.logger.warn("[mcp-oauth] user_id=#{user.id} not active_for_authentication (archived?)")
      raise AccountBlocked, ARCHIVED_MESSAGE
    end

    Rails.logger.info(
      "[mcp-oauth] /mcp authorized user_id=#{user.id} client=#{payload['client_id'].to_s[0, 12]} scope=#{scopes.join(',')}"
    )

    Principal.new(user: user, client_id: payload['client_id'].to_s, scope: scopes.join(' '), jti: payload['jti'].to_s)
  rescue AccountBlocked
    raise
  rescue Error => e
    Rails.logger.warn("[mcp-oauth] bearer token not accepted: #{e.message}")
    nil
  end

  def bearer_token(request)
    request.headers['Authorization'].to_s[/\ABearer\s+(.+)\z/, 1]
  end

  # RFC 9728 §5.1 challenge. The MCP spec also asks for a `scope` hint so the
  # client requests least privilege on the first attempt.
  def challenge_header
    %(Bearer resource_metadata="#{protected_resource_metadata_url}", scope="#{SCOPE_MCP}")
  end

  # -------------------------------------------------------------------- metadata

  def protected_resource_metadata
    {
      resource: resource,
      authorization_servers: [issuer],
      bearer_methods_supported: ['header'],
      scopes_supported: RESOURCE_SCOPES,
      resource_name: 'ICODOS DocuSeal MCP',
      resource_documentation: 'https://github.com/ICODOS/docuseal-branding'
    }
  end

  def authorization_server_metadata
    {
      issuer: issuer,
      authorization_endpoint: authorization_endpoint,
      token_endpoint: token_endpoint,
      registration_endpoint: registration_endpoint,
      jwks_uri: jwks_uri,
      scopes_supported: SUPPORTED_SCOPES,
      response_types_supported: ['code'],
      response_modes_supported: ['query'],
      grant_types_supported: %w[authorization_code refresh_token],
      token_endpoint_auth_methods_supported: ['none'],
      code_challenge_methods_supported: ['S256'],
      authorization_response_iss_parameter_supported: true,
      resource_indicators_supported: true,
      service_documentation: 'https://github.com/ICODOS/docuseal-branding'
    }
  end

  def b64(bytes)
    Base64.urlsafe_encode64(bytes, padding: false)
  end

  # ------------------------------------------------------------- /mcp auth hook
  #
  # Prepended onto Mcp::McpBaseController from config/initializers/zz_mcp_oauth.rb.
  # That controller is the single auth choke point for /mcp: McpController is an
  # ActionController::Metal that only dispatches, and all six MCP controllers
  # (protocol + five tools) inherit McpBaseController.
  module ControllerHook
    private

    # PRECEDENCE, deliberate and load-bearing:
    #   1. The upstream static DocuSeal MCP token (`mcp_tokens.sha256`) — one
    #      indexed lookup, byte-identical behaviour to before Phase D. Trying it
    #      first is what guarantees the existing personal-token path cannot
    #      regress no matter what the OAuth code does.
    #   2. Only on a miss, an OAuth 2.1 access token issued by this instance.
    # A credential can only ever satisfy one of the two: DocuSeal tokens are 43
    # chars of base58 with no dots, OAuth tokens are JWS compact serializations.
    def user_from_api_key
      return @icodos_api_key_user if @icodos_api_key_resolved

      @icodos_api_key_resolved = true
      @icodos_api_key_user =
        begin
          static_user = super

          if static_user
            static_user
          else
            principal = McpOauth.authenticate_request(request)
            @icodos_oauth_principal = principal
            principal&.user
          end
        rescue McpOauth::AccountBlocked => e
          @icodos_oauth_denied_message = e.message
          nil
        end
    end

    # Upstream renders 401 {"error":"Not authenticated"} with no challenge.
    # RFC 9728 / the MCP spec need a WWW-Authenticate pointing at the protected
    # resource metadata, otherwise Claude never discovers the authorization
    # server. The body is left untouched so nothing depending on it breaks.
    def authenticate_user!
      return if current_user

      response.headers['WWW-Authenticate'] = McpOauth.challenge_header if McpOauth.enabled?

      if @icodos_oauth_denied_message
        render json: { error: @icodos_oauth_denied_message }, status: :unauthorized
      else
        super
      end
    end
  end
end
