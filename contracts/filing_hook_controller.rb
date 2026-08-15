# frozen_string_literal: true

# ICODOS Phase E — file the signed PDF back into SharePoint.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/icodos/filing_hook_controller.rb
#
# Receives DocuSeal's own submission.completed webhook and writes the combined
# signed PDF to the folder recorded on the submission when it was sent.
#
# WHY A WEBHOOK RATHER THAN A HOOK INTO THE MODEL
# It uses DocuSeal's documented webhook contract instead of its internals, so a
# version bump is far less likely to break it silently. It also inherits the
# delivery machinery for free: attempts are recorded as WebhookEvents and are
# visible in the DocuSeal UI, and a non-2xx response is retried with
# exponential backoff up to ten times. Returning an error here is therefore the
# correct way to fail — it will be retried and it will be visible.
#
# The URL is http://app:3000/icodos/hooks/filing — inside the compose network,
# never exposed publicly. SendWebhookRequest only enforces HTTPS and blocks
# localhost when Docuseal.multitenant?, which is false on this instance, so a
# plain internal address is accepted. It is still authenticated: DocuSeal signs
# every webhook and the signature is verified below.
#
# REPLACES the Make scenario, which derived the destination by parsing the
# employee name out of the template name and looking it up in Notion. The
# folder is now recorded at send time by the agent that already knew it, so
# template names are no longer load-bearing and _Inbox stops filling up.

module Icodos
  class FilingHookController < ActionController::API
    # Matched against the tail of a WebhookUrl's url to find which webhook
    # secret to verify against.
    HOOK_PATH = '/icodos/hooks/filing'

    FOLDER_KEY = 'icodos_filing_folder'
    FILED_KEY = 'icodos_filed_path'
    SOURCE_KEY = 'icodos_source_path'

    SIGNED_SUFFIX = ' (signed)'
    MAX_COLLISION_ATTEMPTS = 20

    # rubocop:disable Metrics
    def create
      return head :not_found unless IcodosGraph.enabled?

      raw = request.raw_post

      unless verified_webhook_url(raw)
        Rails.logger.warn("[icodos-contracts] filing hook rejected a request: #{@reject_reason}")

        return head :unauthorized
      end

      payload = JSON.parse(raw)

      # 200 for anything there is legitimately nothing to do about. Retrying
      # those would just fill the webhook log with permanent failures.
      return head :ok unless payload['event_type'] == 'submission.completed'

      submission = Submission.find_by(id: payload.dig('data', 'id'))

      return head :ok if submission.nil? || !submission.completed_at?

      preferences = submission.preferences.to_h
      folder = preferences[FOLDER_KEY]

      if folder.blank?
        # Sent by something other than icodos_send_contract — the pre-Phase-E
        # path. Left to whatever automation already handles it.
        Rails.logger.info("[icodos-contracts] submission #{submission.id} has no filing folder; ignoring")

        return head :ok
      end

      if preferences[FILED_KEY].present?
        # DocuSeal retries on any non-2xx, and a later failure must not file a
        # second copy of an executed contract.
        Rails.logger.info("[icodos-contracts] submission #{submission.id} already filed at " \
                          "#{preferences[FILED_KEY].inspect}; ignoring retry")

        return head :ok
      end

      bytes = combined_pdf(submission)
      target = available_target!(folder, signed_filename(submission))

      IcodosGraph.upload(target, bytes, content_type: 'application/pdf')

      submission.update!(preferences: preferences.merge(FILED_KEY => target))

      Rails.logger.info("[icodos-contracts] filed submission #{submission.id} (#{bytes.bytesize} bytes) " \
                        "to #{target.inspect}")

      head :ok
    rescue JSON::ParserError
      head :bad_request
    rescue StandardError => e
      # Deliberately a 500: DocuSeal will retry with backoff and the failure is
      # recorded as a WebhookEvent, which is where someone would look.
      Rails.logger.error("[icodos-contracts] filing failed: #{e.class}: #{e.message}")

      head :internal_server_error
    end
    # rubocop:enable Metrics

    private

    # Verifies against the secret of whichever WebhookUrl points at this hook.
    # Returns the matching record, or nil. Any signature error is a nil, never
    # an exception, so a bad signature cannot 500 into a retry loop.
    def verified_webhook_url(raw)
      header = request.headers['X-Docuseal-Signature'].presence ||
               request.headers['HTTP_X_DOCUSEAL_SIGNATURE'].presence

      if header.blank?
        @reject_reason = 'no X-Docuseal-Signature header'

        return nil
      end

      # WebhookUrl#url is encrypted non-deterministically, so the column holds
      # ciphertext and cannot be matched with a SQL LIKE — the filter has to
      # happen in Ruby, after decryption. There are only ever a handful of
      # webhook registrations, so loading them is not a concern.
      candidates = WebhookUrl.all.select { |w| w.url.to_s.end_with?(HOOK_PATH) }

      if candidates.empty?
        @reject_reason = "no WebhookUrl registered for #{HOOK_PATH}"

        return nil
      end

      errors = []

      match = candidates.find do |webhook_url|
        WebhookUrls::Signatures.verify(webhook_url.hmac_secret, body: raw, header: header)
      rescue WebhookUrls::Signatures::InvalidSignatureError, WebhookUrls::Signatures::TimestampError => e
        errors << "webhook #{webhook_url.id}: #{e.class.name.split('::').last}"

        false
      end

      if match.nil?
        @reject_reason = "signature did not verify (body #{raw.to_s.bytesize} bytes; #{errors.join(', ')})"
      end

      match
    end

    # The combined PDF is generated on demand and behind a lock, because the
    # webhook can arrive before the document exists. EnsureCombinedGenerated
    # handles the waiting and the concurrency.
    def combined_pdf(submission)
      last_submitter = submission.submitters.select(&:completed_at?).max_by(&:completed_at)

      attachment = Submissions::EnsureCombinedGenerated.call(last_submitter)

      raise "no combined document for submission #{submission.id}" if attachment.nil?

      attachment.download
    end

    # Matches the convention already in the employee folders:
    #   20260814-Devraj Solanki-Working contract amendment-v1 (signed).pdf
    # Derived from the source document the contract was built from, which the
    # send tool records on the template, so the signed copy sits next to its
    # draft under the same name.
    def signed_filename(submission)
      source = submission.template&.preferences.to_h[SOURCE_KEY]

      base =
        if source.present?
          File.basename(source, File.extname(source))
        else
          submission.template_schema&.first&.dig('name').presence ||
            submission.template&.name.presence ||
            "submission-#{submission.id}"
        end

      "#{sanitize_filename(base)}#{SIGNED_SUFFIX}.pdf"
    end

    # The fallbacks above draw on the TEMPLATE NAME, which is free text supplied
    # through an MCP tool argument. A name containing a slash, a colon or a
    # control character would produce a path the allowlist rejects — turning a
    # signed contract into ten failed webhook retries and no filed document.
    # Umlauts and spaces are kept; they are normal in these filenames.
    def sanitize_filename(raw)
      cleaned = raw.to_s
                   .tr('/\\:*?"<>|', '-')
                   .gsub(/[[:cntrl:]]/, '')
                   .gsub(/\s+/, ' ')
                   .strip
                   .delete_prefix('.')
                   .slice(0, 180)
                   .strip

      cleaned.presence || "submission-#{Time.now.to_i}"
    end

    # Never overwrites. A collision means something unexpected has happened —
    # a resend, or two contracts built from one draft — and quietly replacing an
    # executed employment contract is not an acceptable way to handle that.
    def available_target!(folder, filename)
      base = File.basename(filename, '.pdf')
      candidate = "#{folder}/#{filename}"

      return candidate unless IcodosGraph.exists?(candidate)

      (2..MAX_COLLISION_ATTEMPTS).each do |n|
        numbered = "#{folder}/#{base} (#{n}).pdf"

        next if IcodosGraph.exists?(numbered)

        Rails.logger.warn("[icodos-contracts] #{candidate.inspect} already exists; filing as #{numbered.inspect}")

        return numbered
      end

      raise "#{candidate} exists and #{MAX_COLLISION_ATTEMPTS} numbered alternatives are taken"
    end
  end
end
