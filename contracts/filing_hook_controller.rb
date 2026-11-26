# frozen_string_literal: true

# ICODOS Phase E — file the signed PDF back into SharePoint.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/controllers/icodos/filing_hook_controller.rb
#
# Receives DocuSeal's own submission.completed webhook and writes the combined
# signed PDF to the folder recorded on the submission when it was sent, or,
# for a contract template sent some other way, on the template.
#
# WHY A WEBHOOK RATHER THAN A HOOK INTO THE MODEL
# It uses DocuSeal's documented webhook contract instead of its internals, so a
# version bump is far less likely to break it silently. It also inherits the
# delivery machinery for free: attempts are recorded as WebhookEvents and are
# visible in the DocuSeal UI, and a non-2xx response is retried with
# exponential backoff up to ten times. Returning an error here is therefore the
# correct way to fail — it will be retried and it will be visible. After the
# tenth attempt DocuSeal stops; Filing.reconcile, run hourly by the host, does
# not.
#
# The URL is http://app:3000/icodos/hooks/filing — inside the compose network.
# The proxy refuses the path from outside. SendWebhookRequest only enforces
# HTTPS and blocks localhost when Docuseal.multitenant?, which is false on this
# instance, so a plain internal address is accepted. It is still
# authenticated: DocuSeal signs every webhook and the signature is verified
# below, against the registration with exactly this URL, and the submission
# must belong to that registration's account.
#
# REPLACES the Make scenario for contract templates made by the create tool,
# which derived the destination by parsing the employee name out of the
# template name and looking it up in Notion. The folder is recorded at
# creation by the agent that already knew it. Make skips every template with
# the ICODOS marker, so a submission of such a template is filed here unless
# the template is a copy of another; a copy is left to a person (see
# Filing.destination).

module Icodos
  class FilingHookController < ActionController::API
    HOOK_PATH = '/icodos/hooks/filing'

    # The one registration whose secret may authenticate a delivery. Exact,
    # not "ends with the path": any admin can register a webhook, and an
    # address of their choosing that merely ended in this path used to be
    # accepted as the filing hook's own.
    DEFAULT_HOOK_URL = "http://app:3000#{HOOK_PATH}"

    FOLDER_KEY = 'icodos_filing_folder'
    FILED_KEY = 'icodos_filed_path'
    SOURCE_KEY = 'icodos_source_path'
    # The name a filing attempt chose, recorded BEFORE the upload.
    TARGET_KEY = 'icodos_filing_target'
    # Set by icodos_create_contract_template to the template's own id, so a
    # copy, which inherits it, can be told from the original.
    TEMPLATE_ID_KEY = 'icodos_template_id'
    # Set by icodos_send_contract on a send of a reusable template: the name
    # of the signed copy (IcodosWorkflow::FILING_NAME_KEY).
    FILING_NAME_KEY = 'icodos_filing_name'
    MARKER = 'icodos-phase-e'

    SIGNED_SUFFIX = ' (signed)'
    MAX_COLLISION_ATTEMPTS = 20
    LOCK_TTL = 300

    # Submissions completed before this were checked by hand when the
    # template fallback and the reconciliation arrived; only later ones are
    # filed by Filing.reconcile. ICODOS_FILING_RECONCILE_SINCE overrides it.
    RECONCILE_SINCE = '2026-11-26T00:00:00Z'

    class Busy < StandardError; end

    def self.hook_url
      ENV['ICODOS_FILING_HOOK_URL'].to_s.strip.presence || DEFAULT_HOOK_URL
    end

    # rubocop:disable Metrics
    def create
      return head :not_found unless IcodosGraph.enabled?

      raw = request.raw_post
      webhook_url = verified_webhook_url(raw)

      unless webhook_url
        Rails.logger.warn("[icodos-contracts] filing hook rejected a request: #{@reject_reason}")

        return head :unauthorized
      end

      payload = JSON.parse(raw)

      # 200 for anything there is legitimately nothing to do about. Retrying
      # those would just fill the webhook log with permanent failures.
      return head :ok unless payload.is_a?(Hash) && payload['event_type'] == 'submission.completed'

      submission = Submission.find_by(id: payload.dig('data', 'id'))

      return head :ok if submission.nil? || !submission.completed_at?

      # A registration speaks for its own account only. DocuSeal delivers an
      # account's events to that account's registrations, so a mismatch is a
      # request this hook did not get from DocuSeal.
      if submission.account_id != webhook_url.account_id
        Rails.logger.warn("[icodos-contracts] filing hook rejected a request: submission #{submission.id} is not " \
                          "in the account of webhook #{webhook_url.id}")

        return head :unauthorized
      end

      Filing.call(submission)

      head :ok
    rescue JSON::ParserError
      head :bad_request
    rescue Busy => e
      # Another request is filing this submission right now. 409 is a non-2xx,
      # so DocuSeal tries again later, by which time it is filed or free.
      Rails.logger.info("[icodos-contracts] #{e.message}")

      head :conflict
    rescue StandardError => e
      # Deliberately a 500: DocuSeal will retry with backoff and the failure is
      # recorded as a WebhookEvent, which is where someone would look.
      Rails.logger.error("[icodos-contracts] filing failed: #{e.class}: #{e.message}")

      head :internal_server_error
    end
    # rubocop:enable Metrics

    private

    # Verifies against the secret of the registration with exactly the hook's
    # URL. Returns the matching record, or nil. Any signature error is a nil,
    # never an exception, so a bad signature cannot 500 into a retry loop.
    def verified_webhook_url(raw)
      header = request.headers['X-Docuseal-Signature'].presence ||
               request.headers['HTTP_X_DOCUSEAL_SIGNATURE'].presence

      if header.blank?
        @reject_reason = 'no X-Docuseal-Signature header'

        return nil
      end

      # WebhookUrl#url is encrypted non-deterministically, so the column holds
      # ciphertext and cannot be matched in SQL — the filter has to happen in
      # Ruby, after decryption. There are only ever a handful of webhook
      # registrations, so loading them is not a concern.
      url = self.class.hook_url
      candidates = WebhookUrl.all.select { |w| w.url.to_s == url }

      if candidates.empty?
        @reject_reason = "no WebhookUrl registered for #{url}"

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

    # The filing itself, apart from the request, so that Filing.reconcile and
    # an operator at the Rails console run exactly what the hook runs:
    #
    #   Icodos::FilingHookController::Filing.call(Submission.find(id))
    #   Icodos::FilingHookController::Filing.reconcile
    module Filing
      module_function

      # Where the signed PDF of a completed submission belongs:
      # { folder:, via: } or { skip: reason }.
      #
      # 1. The folder on the submission, written by icodos_send_contract.
      # 2. Else, for a template made by the create tool (it carries the
      #    marker), the folder on the template. Such a template sent from the
      #    web interface used to be filed by nobody: the submission carries no
      #    folder, so this hook ignored it, and the Make scenario skips the
      #    marker. Make files everything else, so nothing else is touched here.
      # 3. Never for a copy of such a template. A copy inherits the original's
      #    folder and file name, which belong to the original's employee.
      def destination(submission)
        folder = submission.preferences.to_h[FOLDER_KEY]

        return { folder: folder, via: 'submission' } if folder.present?

        template = submission.template

        return { skip: 'not an ICODOS contract template' } unless template&.external_id == MARKER

        template_prefs = template.preferences.to_h

        return { skip: "template #{template.id} records no filing folder" } if template_prefs[FOLDER_KEY].blank?

        if (original = copy_of(template))
          return { skip: "template #{template.id} is a copy of template #{original}; its filing folder and file " \
                         'name belong to the original', person: true }
        end

        { folder: template_prefs[FOLDER_KEY], via: 'template (sent outside icodos_send_contract)' }
      end

      def copy_of(template)
        original = template.preferences.to_h[TEMPLATE_ID_KEY]

        original.present? && original.to_i != template.id ? original.to_i : nil
      end

      # Files one completed submission. :filed, :already_filed or :skipped;
      # raises when it could not, so the hook answers 500 and DocuSeal retries.
      def call(submission)
        dest = destination(submission)

        if dest[:skip]
          log = dest[:person] ? :warn : :info
          Rails.logger.public_send(log, "[icodos-contracts] submission #{submission.id} not filed here: #{dest[:skip]}")

          return :skipped
        end

        with_lock(submission.id) do
          submission.reload

          if submission.preferences.to_h[FILED_KEY].present?
            # DocuSeal retries on any non-2xx, and a later failure must not
            # file a second copy of an executed contract.
            Rails.logger.info("[icodos-contracts] submission #{submission.id} already filed at " \
                              "#{submission.preferences.to_h[FILED_KEY].inspect}; ignoring retry")

            return :already_filed
          end

          bytes = combined_pdf(submission)

          if bytes.bytesize > IcodosGraph::MAX_UPLOAD_BYTES
            raise "the signed PDF of submission #{submission.id} is #{bytes.bytesize} bytes, over the " \
                  "#{IcodosGraph::MAX_UPLOAD_BYTES} bytes the filing upload takes; file it by hand"
          end

          target = place!(submission, dest[:folder], bytes)

          record!(submission, FILED_KEY => target)

          Rails.logger.info("[icodos-contracts] filed submission #{submission.id} (#{bytes.bytesize} bytes) " \
                            "to #{target.inspect} via #{dest[:via]}")

          :filed
        end
      end

      # Uploads under a name recorded on the submission BEFORE the upload,
      # and never over an existing file. Graph's simple upload replaces by
      # default, and the record used to be written only after it:
      #
      #   - a response lost after a successful upload made the retry find the
      #     name taken and file a second copy beside it;
      #   - two submissions built from one draft, completing together, both
      #     saw the name free, and the second upload replaced the first's
      #     executed contract.
      #
      # Now the recorded name is reused by a retry. A file already there is
      # compared byte for byte: if it is this submission's PDF, the earlier
      # upload went through and is recorded; if not, the name went to someone
      # else and the next free one is chosen. The upload itself asks Graph to
      # fail rather than replace, for the moment between the check and the
      # write.
      def place!(submission, folder, bytes)
        filename = signed_filename(submission)

        MAX_COLLISION_ATTEMPTS.times do
          target = submission.preferences.to_h[TARGET_KEY].presence

          unless target
            target = available_target!(folder, filename)
            record!(submission, TARGET_KEY => target)
          end

          case write_or_recognise(target, bytes)
          when :written
            return target
          when :ours
            Rails.logger.info("[icodos-contracts] submission #{submission.id}: #{target.inspect} already holds " \
                              'its signed PDF (an earlier upload whose answer was lost); recording it')

            return target
          else
            Rails.logger.warn("[icodos-contracts] submission #{submission.id}: #{target.inspect} was taken by " \
                              'another file; choosing the next free name')
            record!(submission, TARGET_KEY => nil)
          end
        end

        raise "no free name for #{filename} in #{folder} after #{MAX_COLLISION_ATTEMPTS} attempts"
      end

      def write_or_recognise(target, bytes)
        return same_bytes?(target, bytes) ? :ours : :taken if IcodosGraph.exists?(target)

        IcodosGraph.upload(target, bytes, content_type: 'application/pdf', conflict: 'fail')

        :written
      rescue IcodosGraph::GraphError => e
        raise unless e.status == 409

        same_bytes?(target, bytes) ? :ours : :taken
      end

      def same_bytes?(target, bytes)
        IcodosGraph.download(target).to_s.b == bytes.to_s.b
      end

      def record!(submission, changes)
        submission.update!(preferences: submission.preferences.to_h.merge(changes).compact)
      end

      # One filing per submission at a time, across processes: the hook, a
      # retry that overlaps a slow first attempt, and the reconciliation.
      def with_lock(id)
        key = "icodos:filing:lock:#{id}"
        token = SecureRandom.hex(8)
        held = ::Sidekiq.redis { |c| c.call('SET', key, token, 'NX', 'EX', LOCK_TTL) } == 'OK'

        raise Busy, "submission #{id} is being filed by another request; try again later" unless held

        yield
      ensure
        if held
          begin
            ::Sidekiq.redis do |c|
              c.call('EVAL', "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) " \
                             'else return 0 end', 1, key, token)
            end
          rescue StandardError
            nil # expires by itself after LOCK_TTL
          end
        end
      end

      # Completed, unfiled submissions that belong here, filed now. Run hourly
      # by the host (docuseal-filing.timer). DocuSeal gives up after ten
      # attempts over about 34 hours, and a submission it never delivered at
      # all (a registration missing for a while) would otherwise wait forever.
      # settle leaves room for the webhook to do it first.
      def reconcile(settle: 15 * 60)
        since = Time.zone.parse(ENV['ICODOS_FILING_RECONCILE_SINCE'].to_s.strip.presence || RECONCILE_SINCE)
        due = Submission.where(archived_at: nil)
                        .where('completed_at > ? AND completed_at < ?', since, Time.current - settle)
                        .to_a
                        .select { |s| s.preferences.to_h[FILED_KEY].blank? && destination(s)[:folder] }

        filed = 0
        failed = []

        due.each do |submission|
          filed += 1 if call(submission) == :filed
        rescue StandardError => e
          failed << submission.id
          Rails.logger.error("[icodos-contracts] reconcile: submission #{submission.id}: #{e.class}: #{e.message}")
        end

        line = "[icodos-contracts] filing reconcile: #{due.size} due, #{filed} filed, #{failed.size} failed" \
               "#{failed.any? ? " (#{failed.join(',')})" : ''}"
        Rails.logger.info(line)
        puts line

        archive_settled_templates

        failed.empty?
      end

      # Templates whose documents are signed and filed (or voided) for a day
      # are archived, so the template list stops growing with every document
      # (IcodosWorkflow::Lifecycle), and documents the server filed are
      # removed from it after the retention period (IcodosWorkflow::Retention,
      # decision D7). Hourly, with the reconciliation. A failure is logged and
      # never fails the filing run, whose exit status the health job reads.
      # ICODOS_TEMPLATE_LIFECYCLE=off and ICODOS_DOCUMENT_RETENTION_DAYS=off
      # stop them.
      def archive_settled_templates
        unless ENV['ICODOS_TEMPLATE_LIFECYCLE'].to_s.strip.casecmp('off').zero?
          begin
            IcodosWorkflow::Lifecycle.archive_filed_templates
          rescue StandardError, NameError => e
            Rails.logger.error("[icodos-contracts] lifecycle failed: #{e.class}: #{e.message}")
          end
        end

        IcodosWorkflow::Retention.purge_filed_documents
      rescue StandardError, NameError => e
        Rails.logger.error("[icodos-contracts] retention failed: #{e.class}: #{e.message}")
      end

      # The combined PDF is generated on demand and behind a lock, because the
      # webhook can arrive before the document exists. EnsureCombinedGenerated
      # handles the waiting and the concurrency, and returns the stored file
      # on every later call, so a retry uploads the same bytes.
      def combined_pdf(submission)
        last_submitter = submission.submitters.select(&:completed_at?).max_by(&:completed_at)

        attachment = Submissions::EnsureCombinedGenerated.call(last_submitter)

        raise "no combined document for submission #{submission.id}" if attachment.nil?

        attachment.download
      end

      # Matches the convention already in the employee folders:
      #   20260814-Jane Doe-Working contract amendment-v1 (signed).pdf
      # Derived from the source document the contract was built from, which the
      # create tool records on the template, so the signed copy sits next to its
      # draft under the same name. The Make scenario finds the Notion contract
      # page by this same name, so it is never changed for a one-off template.
      #
      # A reusable template (a standard time sheet sent every month) has one
      # draft for every send; its sends carry their own name (filing_name of
      # icodos_send_contract), recorded on the submission, which wins.
      def signed_filename(submission)
        given = submission.preferences.to_h[FILING_NAME_KEY]

        base =
          if given.present?
            given
          else
            signed_filename_base(submission.template, fallback: submission.template_schema&.first&.dig('name')) ||
              "submission-#{submission.id}"
          end

        "#{sanitize_filename(base)}#{SIGNED_SUFFIX}.pdf"
      end

      def signed_filename_base(template, fallback: nil)
        source = template&.preferences.to_h[SOURCE_KEY]

        return File.basename(source, File.extname(source)) if source.present?

        fallback.presence || template&.name.presence
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
end
