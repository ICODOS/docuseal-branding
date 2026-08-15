# frozen_string_literal: true

# ICODOS Phase E — Microsoft Graph client for SharePoint contract filing.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_graph.rb.
#
# Reads employment-contract drafts from, and writes signed contracts back to,
# the ICODOS SharePoint library. App-only (client credentials) with a
# certificate assertion — there is no user in this flow and no client secret
# anywhere in the configuration.
#
# WHY A CERTIFICATE AND NOT A SECRET
# The Entra app holding this credential has the Sites.Selected application
# permission, so the credential ALONE is sufficient to read every employment
# contract. A client secret would live in /opt/docuseal/.env, which the secret
# rotation procedure copies to .env.bak-secret-* files on the host. A
# certificate keeps the private key in a single 0400 file owned by uid 2000,
# the same shape as the Phase D signing key.
#
# WHAT CONSTRAINS THIS CLIENT
# Sites.Selected scopes to a SITE, not a folder, so the Graph credential can
# reach anything in sites/ICODOSGmbH. The only thing keeping this client inside
# the employee-contracts tree is #normalize_path! below. Treat it as the
# security boundary of Phase E, not as input tidying — the paths it validates
# arrive from an MCP tool argument, which is model-generated text derived from
# Notion pages, email and documents ICODOS does not fully control.
#
# ROLLBACK: set ICODOS_CONTRACTS_ENABLED=false in /opt/docuseal/.env and
# `docker compose up -d`. #enabled? goes false, the MCP tools stop being
# registered, and nothing here is ever called. To remove the code as well,
# delete the whole "Phase E" mount block from docker-compose.yml.

module IcodosGraph
  class Error < StandardError; end

  # Configuration is absent or unusable. Never retried.
  class ConfigError < Error; end

  # Entra refused to issue a token. Usually the certificate or consent.
  class AuthError < Error; end

  # A path failed validation. Deliberately distinct from GraphError so callers
  # can tell "you asked for something you may not have" from "Graph said no".
  class PathError < Error; end

  # Graph answered with a non-success status.
  class GraphError < Error
    attr_reader :status, :graph_code

    def initialize(message, status: nil, graph_code: nil)
      super(message)
      @status = status
      @graph_code = graph_code
    end
  end

  GRAPH_ROOT = 'https://graph.microsoft.com/v1.0'
  LOGIN_ROOT = 'https://login.microsoftonline.com'

  SIGNING_ALG = 'RS256'
  ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'

  # Entra rejects assertions with a long lifetime. 5 minutes is the documented
  # maximum that is universally accepted.
  ASSERTION_TTL = 300

  # Renew this many seconds before the token actually expires, so a request
  # that starts just under the wire does not arrive just over it.
  TOKEN_SKEW = 120

  DEFAULT_KEY_PATH  = '/app/config/icodos/graph_filing_key.pem'
  DEFAULT_CERT_PATH = '/app/config/icodos/graph_filing_cert.pem'

  # Graph's simple upload (PUT .../content) tops out at 4 MiB; past that it
  # needs a resumable upload session. Executed employment contracts are far
  # below this, so rather than carry an upload-session implementation that
  # would never run in anger — and would therefore never be tested — this
  # raises. If it ever fires, that is the signal to add one.
  MAX_UPLOAD_BYTES = 4 * 1024 * 1024

  # Guards against a hostile or corrupted document being pulled into DocuSeal.
  MAX_DOWNLOAD_BYTES = 32 * 1024 * 1024

  OPEN_TIMEOUT = 8
  READ_TIMEOUT = 30

  # Graph answers /content with a redirect to a short-lived pre-authenticated
  # URL rather than streaming bytes itself — for downloads by design, and for
  # uploads depending on how SharePoint routes the write. Faraday does not
  # follow redirects without middleware, so both are handled explicitly below.
  REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

  # The redirect target is where contract bytes get sent or fetched, so it is
  # checked rather than trusted. Two separate risks:
  #   1. Forwarding the bearer token to another host would leak a credential
  #      that can read every contract — so the follow-up request carries no
  #      Authorization header at all. The target URL is pre-authenticated.
  #   2. Even unauthenticated, following an arbitrary redirect on an UPLOAD
  #      would post contract content to whatever host was named. Hence the
  #      host allowlist.
  ALLOWED_REDIRECT_SUFFIXES = %w[
    .sharepoint.com
    .svc.ms
    .microsoft.com
    .office.com
    .officeapps.live.com
  ].freeze

  # Path segments that must never appear. Backslash and colon matter
  # specifically because Graph addresses drive items as
  # /root:/{path}:/content — a colon in `path` would terminate the address
  # early and silently retarget the request at a different item.
  FORBIDDEN_PATH_CHARS = /[\\:*?"<>|]|[[:cntrl:]]/

  KEY_MUTEX = Mutex.new
  TOKEN_MUTEX = Mutex.new

  # Site and drive get SEPARATE mutexes because #drive_id needs #site_id, and
  # Ruby's Mutex is not reentrant — one shared mutex deadlocks the first time a
  # process resolves the drive before the site, which is every fresh process,
  # because #drive_root is the entry point for download/upload/list.
  # Lock order is only ever drive -> site and never the reverse, so no cycle.
  SITE_MUTEX = Mutex.new
  DRIVE_MUTEX = Mutex.new

  module_function

  # -------------------------------------------------------------- configuration

  # False unless the operator opted in AND every piece of configuration this
  # client needs is present and usable. Mirrors McpOauth.enabled?: a broken
  # configuration degrades to "Phase E off, the rest of DocuSeal unaffected"
  # rather than 500s, and the boot diagnostic makes it visible.
  def enabled?
    return false unless ENV['ICODOS_CONTRACTS_ENABLED'].to_s.strip.casecmp('true').zero?

    config!
    private_key.present? && certificate.present?
  rescue Error => e
    unless @config_warning_logged
      @config_warning_logged = true
      Rails.logger.error("[icodos-contracts] ICODOS_CONTRACTS_ENABLED=true but the configuration is unusable " \
                         "(#{e.message}). Phase E stays OFF; the rest of DocuSeal is unaffected.")
    end

    false
  end

  # Raises rather than returning false, so callers get the specific reason.
  def config!
    missing = REQUIRED_ENV.reject { |k| ENV[k].to_s.strip.present? }

    raise ConfigError, "missing #{missing.join(', ')}" if missing.any?

    true
  end

  REQUIRED_ENV = %w[
    ICODOS_GRAPH_TENANT_ID
    ICODOS_GRAPH_CLIENT_ID
    ICODOS_GRAPH_SITE_HOSTNAME
    ICODOS_GRAPH_SITE_PATH
    ICODOS_CONTRACTS_PATH_PREFIX
  ].freeze

  # Written as conventional method definitions rather than the endless form.
  # DocuSeal's own source uses Ruby 3.1 syntax so the container would accept
  # either, but this keeps the file parseable by older Rubies and therefore
  # syntax-checkable outside the container — which matters, because a parse
  # error here fails the initializer at boot on a host that is awkward to reach.
  def tenant_id
    ENV.fetch('ICODOS_GRAPH_TENANT_ID').strip
  end

  def client_id
    ENV.fetch('ICODOS_GRAPH_CLIENT_ID').strip
  end

  def site_hostname
    ENV.fetch('ICODOS_GRAPH_SITE_HOSTNAME').strip
  end

  def key_path
    ENV['ICODOS_GRAPH_KEY_PATH'].presence || DEFAULT_KEY_PATH
  end

  def cert_path
    ENV['ICODOS_GRAPH_CERT_PATH'].presence || DEFAULT_CERT_PATH
  end

  # Graph wants the server-relative site path with a leading slash and no
  # trailing one: "/sites/ICODOSGmbH".
  def site_path
    '/' + ENV.fetch('ICODOS_GRAPH_SITE_PATH').strip.delete_prefix('/').delete_suffix('/')
  end

  # The one folder subtree this client may touch. Normalised the same way as
  # every path it validates, so a trailing slash or duplicated separator in the
  # .env cannot open a gap between prefix and check.
  def path_prefix
    @path_prefix ||= collapse(ENV.fetch('ICODOS_CONTRACTS_PATH_PREFIX'))
  end

  # ----------------------------------------------------------------------- keys

  def private_key
    @private_key || KEY_MUTEX.synchronize { @private_key ||= load_key!(key_path) }
  end

  def certificate
    @certificate || KEY_MUTEX.synchronize { @certificate ||= load_cert!(cert_path) }
  end

  def load_key!(path)
    raise ConfigError, 'graph key file missing' unless File.exist?(path)

    key = OpenSSL::PKey::RSA.new(File.read(path))
    raise ConfigError, 'graph key is not a private key' unless key.private?
    raise ConfigError, 'graph key shorter than 2048 bits' if key.n.num_bits < 2048

    key
  rescue OpenSSL::PKey::RSAError
    raise ConfigError, 'graph key is not a readable RSA PEM'
  rescue SystemCallError
    raise ConfigError, 'graph key file not readable'
  end

  def load_cert!(path)
    raise ConfigError, 'graph certificate file missing' unless File.exist?(path)

    cert = OpenSSL::X509::Certificate.new(File.read(path))

    # A lapsed certificate produces an opaque AADSTS700027 from Entra. Say so
    # here instead, where the message can name the actual problem.
    raise ConfigError, "graph certificate expired #{cert.not_after.iso8601}" if cert.not_after < Time.now

    cert
  rescue OpenSSL::X509::CertificateError
    raise ConfigError, 'graph certificate is not a readable PEM'
  rescue SystemCallError
    raise ConfigError, 'graph certificate file not readable'
  end

  # Entra identifies which uploaded certificate signed an assertion by the
  # base64url SHA-1 thumbprint of the DER form, in the `x5t` JOSE header.
  # SHA-1 is not a security choice here — it is what the protocol specifies.
  def x5t
    @x5t ||= Base64.urlsafe_encode64(OpenSSL::Digest::SHA1.digest(certificate.to_der), padding: false)
  end

  # ---------------------------------------------------------------------- token

  # TWO audiences, not one.
  #
  # Graph handles metadata, listings and uploads. It does NOT serve file
  # content: GET .../content answers 302 and redirects to SharePoint, as does
  # @microsoft.graph.downloadUrl. Those URLs are served by Office 365 SharePoint
  # Online, which rejects a Graph token and asks for one issued for itself:
  #
  #   www-authenticate: Bearer realm="<tenant>", client_id="00000003-0000-0ff1-ce00-000000000000"
  #
  # The embedded `tempauth` parameter is not honoured in the ICODOS tenant, so
  # the follow-up request has to carry a real SharePoint-audience token. That
  # token is issued by the same client credentials but needs the SharePoint
  # Sites.Selected application role, separate from the Graph one — without it
  # the token arrives with roles: nil and SharePoint answers 401 with an HTML
  # sign-in page.
  def graph_resource
    'https://graph.microsoft.com'
  end

  def sharepoint_resource
    "https://#{site_hostname}"
  end

  def access_token(resource = graph_resource)
    TOKEN_MUTEX.synchronize do
      @tokens ||= {}
      entry = @tokens[resource]

      return entry[:token] if entry && Time.now.to_i < (entry[:expires_at] - TOKEN_SKEW)

      token, expires_at = request_token!(resource)
      @tokens[resource] = { token: token, expires_at: expires_at }

      token
    end
  end

  def token_endpoint
    "#{LOGIN_ROOT}/#{tenant_id}/oauth2/v2.0/token"
  end

  def client_assertion(now: Time.now.to_i)
    JWT.encode(
      {
        aud: token_endpoint,
        iss: client_id,
        sub: client_id,
        jti: SecureRandom.uuid,
        nbf: now - 10,
        exp: now + ASSERTION_TTL
      },
      private_key,
      SIGNING_ALG,
      { 'x5t' => x5t, 'typ' => 'JWT' }
    )
  end

  def request_token!(resource)
    resp = connection.post(token_endpoint) do |req|
      req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
      req.body = URI.encode_www_form(
        client_id: client_id,
        scope: "#{resource}/.default",
        grant_type: 'client_credentials',
        client_assertion_type: ASSERTION_TYPE,
        client_assertion: client_assertion
      )
    end

    body = parse_json(resp.body)

    unless resp.status == 200 && body['access_token'].present?
      # AADSTS codes are the only actionable part and they are not secret;
      # the response body can carry correlation ids but no credentials.
      raise AuthError, "token request for #{resource} failed (#{resp.status}): " \
                       "#{body['error']} #{body['error_description'].to_s[0, 300]}"
    end

    [body['access_token'], Time.now.to_i + body.fetch('expires_in', 3600).to_i]
  end

  # Decodes the roles claim without verifying the signature — this is a local
  # sanity check on our OWN token for diagnostics, not a trust decision, and
  # the token is never accepted from anywhere but Entra over TLS.
  def token_roles(resource)
    payload = access_token(resource).split('.')[1].to_s
    JSON.parse(Base64.urlsafe_decode64(payload + ('=' * ((4 - payload.length % 4) % 4))))['roles']
  rescue StandardError
    nil
  end

  # ------------------------------------------------------------- path handling

  # THE SECURITY BOUNDARY. Returns a path guaranteed to sit inside
  # path_prefix, or raises. Everything reaching Graph goes through here.
  #
  # Deliberately allowlist-shaped: normalise first, then require the result to
  # start with the configured prefix. Blocklisting traversal patterns alone
  # would be one encoding trick away from failing.
  def normalize_path!(raw)
    raise PathError, 'path is blank' if raw.to_s.strip.empty?

    path = collapse(raw)

    raise PathError, 'path contains a forbidden character' if path.match?(FORBIDDEN_PATH_CHARS)

    segments = path.split('/')

    raise PathError, 'path contains a relative segment' if segments.any? { |s| s == '..' || s == '.' }
    raise PathError, 'path contains an empty segment' if segments.any?(&:empty?)

    # Prefix match on SEGMENTS, not on the string. A string comparison would
    # accept ".../01 Employee contracts evil/x.pdf" as being inside
    # ".../01 Employee contracts".
    prefix_segments = path_prefix.split('/')

    unless segments.first(prefix_segments.length) == prefix_segments
      raise PathError, 'path is outside the permitted contracts folder'
    end

    path
  end

  # Strip leading/trailing separators and collapse runs of them. Does not
  # resolve traversal — that is rejected outright rather than resolved away,
  # so a caller cannot smuggle intent through normalisation.
  def collapse(raw)
    raw.to_s.strip.tr('\\', '/').squeeze('/').delete_prefix('/').delete_suffix('/')
  end

  # Graph addresses drive items as /root:/{path}:/content. Each segment is
  # percent-encoded individually so that separators survive and spaces,
  # umlauts and the like are encoded rather than breaking the URL.
  def encode_path(path)
    path.split('/').map { |s| ERB::Util.url_encode(s) }.join('/')
  end

  # ---------------------------------------------------------------- resolution

  # The composite site id (hostname,siteCollectionId,webId). Resolved once from
  # hostname + server-relative path so that no id has to be pasted into .env,
  # where it would silently rot if the site were ever moved or renamed.
  def site_id
    @site_id || SITE_MUTEX.synchronize do
      @site_id ||= begin
        body = get_json("#{GRAPH_ROOT}/sites/#{site_hostname}:#{site_path}")
        body.fetch('id')
      end
    end
  end

  # The default document library of that site.
  #
  # site_id is resolved BEFORE taking DRIVE_MUTEX, not inside it. Holding a
  # lock across an unrelated HTTP call is worth avoiding on its own, and here
  # it also keeps the two locks from ever being held simultaneously.
  def drive_id
    return @drive_id if @drive_id

    site = site_id

    DRIVE_MUTEX.synchronize do
      @drive_id ||= get_json("#{GRAPH_ROOT}/sites/#{site}/drive").fetch('id')
    end
  end

  def drive_root
    "#{GRAPH_ROOT}/drives/#{drive_id}/root"
  end

  # Server-relative path of the document library, decoded — e.g.
  # "/sites/ICODOSGmbH/Shared Documents". Read from the drive's webUrl rather
  # than hardcoded, because the library's URL name ("Shared Documents") is not
  # its display name ("Documents") and differs between tenants and languages.
  def drive_web_path
    return @drive_web_path if @drive_web_path

    body = get_json("#{GRAPH_ROOT}/drives/#{drive_id}")

    @drive_web_path = URI::DEFAULT_PARSER.unescape(URI.parse(body.fetch('webUrl')).path)
  end

  # SharePoint REST address for a file's bytes.
  #
  # Used instead of Graph's /content because Graph does not serve content: it
  # redirects to _layouts/15/download.aspx, which in this tenant rejects a
  # bearer token of either audience and answers 401 with an HTML sign-in page.
  # SharePoint's own REST endpoint accepts the SharePoint-audience token.
  def odata_content_path(path)
    server_relative = "#{drive_web_path}/#{path}"

    # OData string literals escape a single quote by doubling it. Names like
    # "O'Brien" are otherwise a syntax error, and a plausible one here.
    literal = server_relative.gsub("'", "''")

    encoded = literal.split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')

    "#{site_path}/_api/web/GetFileByServerRelativeUrl('#{encoded}')/$value"
  end

  # -------------------------------------------------------------------- files

  # Returns the raw bytes of a file. Path is validated before use.
  def download(raw_path)
    path = normalize_path!(raw_path)

    resp = connection.get("https://#{site_hostname}#{odata_content_path(path)}") do |req|
      req.headers['Authorization'] = "Bearer #{access_token(sharepoint_resource)}"
      req.headers['Accept'] = 'application/octet-stream'
    end

    resp = follow_content_redirect!(resp, :get, path) if REDIRECT_STATUSES.include?(resp.status)

    raise_graph_error!(resp, path) unless resp.status == 200

    body = resp.body.to_s

    raise GraphError.new("file at #{path} exceeds #{MAX_DOWNLOAD_BYTES} bytes") if body.bytesize > MAX_DOWNLOAD_BYTES

    body
  end

  # Writes bytes to a path, creating or replacing. Path is validated before use.
  def upload(raw_path, content, content_type: 'application/pdf')
    path = normalize_path!(raw_path)
    bytes = content.to_s

    if bytes.bytesize > MAX_UPLOAD_BYTES
      raise GraphError.new("upload to #{path} is #{bytes.bytesize} bytes, over the #{MAX_UPLOAD_BYTES} simple-upload limit")
    end

    resp = authorized(:put, "#{drive_root}:/#{encode_path(path)}:/content") do |req|
      req.headers['Content-Type'] = content_type
      req.body = bytes
    end

    if REDIRECT_STATUSES.include?(resp.status)
      resp = follow_content_redirect!(resp, :put, path, body: bytes, content_type: content_type)
    end

    raise_graph_error!(resp, path) unless [200, 201].include?(resp.status)

    parse_json(resp.body)
  end

  # Lists a folder. Used by the check script and for verifying a filing folder
  # exists before a send, so a contract is never sent that cannot later be filed.
  def list(raw_path)
    path = normalize_path!(raw_path)

    body = get_json("#{drive_root}:/#{encode_path(path)}:/children?$select=name,size,folder,file", path)

    body.fetch('value', [])
  end

  # Deletes a file. Graph handles deletes itself — no SharePoint redirect — so
  # the Graph token is sufficient. Used by the check probe to clean up after
  # itself; Phase E's normal operation never deletes anything.
  def delete(raw_path)
    path = normalize_path!(raw_path)

    resp = authorized(:delete, "#{drive_root}:/#{encode_path(path)}")

    raise_graph_error!(resp, path) unless [200, 204].include?(resp.status)

    true
  end

  # True for a file OR a folder. Asks for the drive item itself rather than its
  # children, so it works for both — an earlier version listed children, which
  # only ever worked for folders and would have raised on a file.
  def exists?(raw_path)
    path = normalize_path!(raw_path)

    resp = authorized(:get, "#{drive_root}:/#{encode_path(path)}?$select=id")

    return true if resp.status == 200
    return false if resp.status == 404

    raise_graph_error!(resp, path)
  end

  # ------------------------------------------------------------------- plumbing

  def connection
    @connection ||= Faraday.new do |f|
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
    end
  end

  def authorized(method, url, &block)
    connection.public_send(method, url) do |req|
      req.headers['Authorization'] = "Bearer #{access_token}"
      req.headers['Accept'] = 'application/json'
      block&.call(req)
    end
  end

  # Re-issues a /content request against the pre-authenticated URL Graph
  # redirects to, preserving the HTTP method — a browser-style redirect
  # follower would turn the upload PUT into a GET and silently fail to write.
  #
  # Deliberately does NOT forward the Authorization header. Only one hop is
  # followed; a redirect chain is treated as a failure rather than walked.
  def follow_content_redirect!(resp, method, context, body: nil, content_type: nil)
    location = resp.headers['location'].to_s

    raise GraphError.new("graph #{resp.status} for #{context} with no Location header",
                         status: resp.status) if location.empty?

    uri = begin
      URI.parse(location)
    rescue URI::Error
      raise GraphError.new("graph redirect for #{context} had an unparseable Location", status: resp.status)
    end

    unless uri.scheme == 'https'
      raise GraphError.new("graph redirect for #{context} was not https", status: resp.status)
    end

    host = uri.host.to_s.downcase

    unless ALLOWED_REDIRECT_SUFFIXES.any? { |suffix| host.end_with?(suffix) }
      raise GraphError.new("graph redirect for #{context} pointed at an unexpected host (#{host})",
                           status: resp.status)
    end

    # A SharePoint host needs a SharePoint-audience token — the Graph token is
    # rejected there, and so is the tempauth in the URL. Anything else (the
    # .svc.ms CDN, for example) is treated as genuinely pre-authenticated and
    # gets no credential, because sending one to a host we do not control is
    # the failure mode worth avoiding.
    followed = connection.public_send(method, uri.to_s) do |req|
      req.headers['Authorization'] = "Bearer #{access_token(sharepoint_resource)}" if host.end_with?('.sharepoint.com')
      req.headers['Content-Type'] = content_type if content_type
      req.body = body if body
    end

    if REDIRECT_STATUSES.include?(followed.status)
      raise GraphError.new("graph redirect chain for #{context} did not terminate", status: followed.status)
    end

    followed
  end

  def get_json(url, context = nil)
    resp = authorized(:get, url)

    raise_graph_error!(resp, context) unless resp.status == 200

    parse_json(resp.body)
  end

  def parse_json(body)
    JSON.parse(body.to_s.presence || '{}')
  rescue JSON::ParserError
    {}
  end

  # Graph error bodies name the failure precisely; the useful part is the code.
  # 403 in particular has one overwhelmingly likely cause here and it is worth
  # naming, because the Sites.Selected per-site grant is invisible in the Azure
  # Portal and is the step most often missed.
  def raise_graph_error!(resp, context = nil)
    body = parse_json(resp.body)
    code = body.dig('error', 'code')
    message = body.dig('error', 'message').to_s[0, 300]

    hint =
      case resp.status
      when 403 then ' — check the Sites.Selected per-site grant for this app (it is not visible in the Azure Portal)'
      when 404 then ' — check ICODOS_CONTRACTS_PATH_PREFIX, including its leading folder'
      else ''
      end

    raise GraphError.new("graph #{resp.status} #{code} for #{context || 'request'}: #{message}#{hint}",
                         status: resp.status, graph_code: code)
  end
end
