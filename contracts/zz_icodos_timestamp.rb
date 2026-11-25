# frozen_string_literal: true

# ICODOS: an RFC 3161 timestamp that is either right or absent, never broken.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/config/initializers/zz_icodos_timestamp.rb.
#
# With a timestamp server set under Settings -> E-Signature, DocuSeal asks that
# server for a token over each signature value and embeds it in the signature
# (HexaPDF, unsigned attribute id-aa-timeStampToken). That is what lets a
# viewer show the signing time as proven by a third party rather than asserted
# by this server's clock.
#
# Upstream's handler (lib/submissions/timestamp_handler.rb, 3.4.0) has two
# properties that this file replaces:
#
# 1. Any failure is written into the document. #sign rescues StandardError and
#    returns OpenSSL::ASN1::GeneralizedTime.new(Time.now.utc).to_der, a bare
#    time value, which HexaPDF then embeds where the token belongs. A timeout,
#    a DNS failure or a refused connection therefore produces a signed PDF
#    whose timestamp attribute is not a token at all. Measured on a scratch
#    copy on 25 November 2026: HexaPDF's own verifier raises on that file, and
#    OpenSSL cannot decode the attribute. The contract reads as broken to a
#    counterparty, which is worse than no timestamp, and nothing tells anyone.
#
# 2. The fallback after a comma covers only an HTTP error status. A network
#    failure on the first server goes straight to the rescue above, so the
#    second server is never asked. Measured the same day: first server
#    unreachable, fallback configured, bare time value embedded.
#
# Here, each configured server is asked in turn, on any failure. A response
# counts only if it is a granted token over exactly this signature, carrying
# the nonce we sent, signed by a time-stamping certificate that the system
# trust store accepts (OpenSSL's TS_RESP_verify). If no server gives one, the
# signature is made WITHOUT a timestamp attribute, as it was before a server
# was configured, the error is logged, and the time and reason are written to
# #{WORKDIR}/icodos_timestamp_failure.json, which the host's health job turns
# into an alert. The file holds server addresses and error classes, no
# document data.
#
# What is sent to the timestamp server: a SHA-256 digest of the signature
# value and a random nonce. No document content, no names.
#
# Inert while no timestamp server is configured: upstream builds its handler
# only when one is.
#
# Rechecked on every version bump: Submissions::TimestampHandler#sign(io,
# byte_range) and HexaPDF's SignedDataCreator#create_unsigned_attrs(signature)
# are the two seams. If either is gone the boot log says "NOT attached", which
# deploy.sh's health gate treats as a failed boot.

module IcodosTimestamp
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  FAILURE_FILE = File.join(ENV.fetch('WORKDIR', '/data/docuseal'), 'icodos_timestamp_failure.json')

  # Raised by the handler when no server produced a usable token; caught in
  # SignedDataCreator, where it means "sign without the attribute".
  Unavailable = Class.new(StandardError)

  module_function

  def store
    @store ||= OpenSSL::X509::Store.new.tap(&:set_default_paths)
  end

  # One server, one attempt. Returns the DER of a verified TimeStampToken or
  # raises with a reason.
  def fetch_token(url, imprint)
    req = OpenSSL::Timestamp::Request.new
    req.algorithm = 'SHA256'
    req.message_imprint = imprint
    req.cert_requested = true
    req.nonce = SecureRandom.random_number(2**63)

    uri = Addressable::URI.parse(url.strip)
    conn = Faraday.new(uri.origin) do |c|
      c.options.open_timeout = OPEN_TIMEOUT
      c.options.read_timeout = READ_TIMEOUT
      c.request :authorization, :basic, uri.user, uri.password if uri.password.present?
    end
    response = conn.post(uri.request_uri, req.to_der, 'content-type' => 'application/timestamp-query')
    raise "HTTP #{response.status}" unless response.status == 200 && response.body.present?

    ts = OpenSSL::Timestamp::Response.new(response.body)
    raise "not granted (PKIStatus #{ts.status.to_i})" unless ts.status.to_i <= 1 && ts.token

    # Checks the imprint, the nonce, the token's signature and the signer's
    # chain and time-stamping key usage. Raises on any mismatch.
    ts.verify(req, store, ts.token.certificates || [])
    ts.token.to_der
  end

  def without_credentials(url)
    uri = Addressable::URI.parse(url.to_s.strip)
    uri.user = nil
    uri.password = nil
    uri.to_s
  rescue StandardError
    '(unparseable address)'
  end

  def record_failure(error)
    Rails.logger.error("[icodos-timestamp] FAILED, this signature is made WITHOUT a timestamp: #{error.message}")
    previous = begin
      JSON.parse(File.read(FAILURE_FILE))
    rescue StandardError
      {}
    end
    data = { 'at' => Time.now.utc.iso8601, 'reason' => error.message[0, 500],
             'count' => previous['count'].to_i + 1 }
    tmp = "#{FAILURE_FILE}.#{Process.pid}.#{Thread.current.object_id}"
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, FAILURE_FILE)
  rescue StandardError => e
    Rails.logger.error("[icodos-timestamp] could not record the failure (#{e.class}: #{e.message})")
  end

  # Prepended to Submissions::TimestampHandler.
  module Handler
    def sign(io, byte_range)
      digest = OpenSSL::Digest.new('SHA256')
      io.pos = byte_range[0]
      digest << io.read(byte_range[1])
      io.pos = byte_range[2]
      digest << io.read(byte_range[3])
      imprint = digest.digest

      errors = []
      [tsa_url, tsa_fallback_url].compact_blank.each do |url|
        return IcodosTimestamp.fetch_token(url, imprint)
      rescue StandardError => e
        errors << "#{IcodosTimestamp.without_credentials(url)}: #{e.class}: #{e.message.to_s[0, 160]}"
      end
      raise IcodosTimestamp::Unavailable, errors.join(' | ')
    end
  end

  # Prepended to HexaPDF::DigitalSignature::Signing::SignedDataCreator.
  module SignedData
    private

    def create_unsigned_attrs(signature)
      super
    rescue IcodosTimestamp::Unavailable => e
      IcodosTimestamp.record_failure(e)
      nil
    end
  end
end

Rails.application.config.to_prepare do
  begin
    handler = Submissions::TimestampHandler
    creator = HexaPDF::DigitalSignature::Signing::SignedDataCreator

    unless handler.method_defined?(:sign) && creator.private_method_defined?(:create_unsigned_attrs)
      raise NameError, 'Submissions::TimestampHandler#sign or SignedDataCreator#create_unsigned_attrs is gone'
    end

    handler.prepend(IcodosTimestamp::Handler) unless handler.ancestors.include?(IcodosTimestamp::Handler)
    creator.prepend(IcodosTimestamp::SignedData) unless creator.ancestors.include?(IcodosTimestamp::SignedData)
  rescue NameError => e
    Rails.logger.error("[icodos-timestamp] guard NOT attached (#{e.message}). With a timestamp server set, a " \
                       'server failure embeds a bare time value instead of a token.')
  end
end

Rails.application.config.after_initialize do
  attached = Submissions::TimestampHandler.ancestors.include?(IcodosTimestamp::Handler) &&
             HexaPDF::DigitalSignature::Signing::SignedDataCreator.ancestors.include?(IcodosTimestamp::SignedData)
  if attached
    Rails.logger.info('[icodos-timestamp] guard attached: every configured server is tried, a token is ' \
                      'verified before use, no token means no timestamp attribute')
  else
    Rails.logger.error('[icodos-timestamp] guard NOT attached')
  end
rescue StandardError => e
  Rails.logger.error("[icodos-timestamp] guard NOT attached (#{e.class}: #{e.message})")
end
