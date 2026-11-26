# frozen_string_literal: true

# ICODOS Phase 5 — what the tracking and correcting tools share.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/lib/icodos_workflow.rb. Zeitwerk maps lib/x.rb to
# X, so this file defines IcodosWorkflow and keeps everything else nested in
# it; a second constant at the top level would stop the app booting.
#
# Three things live here:
#
#   View        how a submission is described to an agent: status, signers
#               in order, whose turn it is, reminders, filing. Used by
#               icodos_pending_signatures and icodos_get_submission, so both
#               say the same thing about the same submission.
#   ActionTool  the confirmation pattern of the send tool, for the three
#               tools that change a submission after it was sent
#               (icodos_set_reminders, icodos_void_submission,
#               icodos_correct_signer): a preview with a preview_token bound
#               to everything shown, a confirmation that needs that token,
#               once, and a repeated confirmation that answers with what was
#               done instead of doing it again.
#   Lifecycle   templates archived once their documents are signed and
#               filed, so the template list stops growing with every
#               document.
#   Retention   documents removed from this server 90 days after the server
#               filed them in SharePoint, which is the record (decision D7).
#   Digest      the weekly summary mail: sent, signed, filed, waiting, and
#               what needs a person.
module IcodosWorkflow
  # On the template: made with reusable true, sent again and again with
  # values filled in per send (a standard time sheet). Never archived by
  # Lifecycle.
  REUSABLE_KEY = 'icodos_reusable'

  # On the submission: the file name of the signed copy, given with the send
  # (reusable templates only). The filing hook prefers it to the template's
  # source file name, which is the same for every send of a reusable template.
  FILING_NAME_KEY = 'icodos_filing_name'

  # On the submission: what the action tools did to it, newest last. The
  # durable half of their replay record (Redis is the fast half) and the
  # history icodos_get_submission shows.
  ACTIONS_KEY = 'icodos_actions'
  MAX_ACTIONS = 50

  # On the template: when Lifecycle archived it, so a person who finds it in
  # the archive can tell why.
  ARCHIVED_BY_KEY = 'icodos_archived_by_lifecycle'

  # On a submission (and a template): when Retention removed its documents.
  PURGED_KEY = 'icodos_documents_purged_at'

  MARKER = 'icodos-phase-e'
  FILED_KEY = 'icodos_filed_path'
  FOLDER_KEY = 'icodos_filing_folder'

  module_function

  def reusable?(template)
    template.present? && template.preferences.to_h[REUSABLE_KEY] == true
  end

  def iso(time)
    time&.utc&.iso8601
  end

  # ------------------------------------------------------------------ View

  module View
    module_function

    # pending, completed, declined, expired or archived. "archived" is what a
    # void is; the action record on the submission says whether a tool did it.
    def status(submission)
      return 'archived' if submission.archived_at?
      return 'completed' if submission.completed_at?
      return 'declined' if submission.submitters.any?(&:declined_at?)
      return 'expired' if submission.expired?

      'pending'
    end

    def roles(submission)
      Array.wrap(submission.template_submitters).each_with_object({}) { |ts, acc| acc[ts['uuid']] = ts }
    end

    # Signers in signing order, viewers marked.
    def ordered_submitters(submission)
      order = Array.wrap(submission.template_submitters).map { |ts| ts['uuid'] }

      submission.submitters.sort_by { |s| [order.index(s.uuid) || order.length, s.id] }
    end

    # rubocop:disable Metrics
    def signers(submission, reminder_state: true)
      by_uuid = roles(submission)
      state = submission.preferences.to_h.dig('icodos_reminder_state', 'per_submitter').to_h

      ordered_submitters(submission).each_with_index.map do |s, i|
        role = by_uuid[s.uuid].to_h
        mine = state[s.uuid].to_h

        entry = {
          order: i + 1,
          role: role['name'],
          name: s.name,
          email: s.email,
          status: s.status,
          viewer: role['is_viewer'] == true ? true : nil,
          invited_at: IcodosWorkflow.iso(s.sent_at),
          opened_at: IcodosWorkflow.iso(s.opened_at),
          signed_at: IcodosWorkflow.iso(s.completed_at),
          declined_at: IcodosWorkflow.iso(s.declined_at),
          email_code: s.preferences.to_h['require_email_2fa'] == true
        }

        if reminder_state
          entry[:reminders_sent] = mine['sent_count'].to_i
          entry[:last_reminder_at] = mine['last_sent_at']
        end

        entry.compact
      end
    end
    # rubocop:enable Metrics

    # The signer(s) whose turn it is: order-aware, viewers and those who
    # signed or declined left out. The same rule the reminder sweep uses, so
    # "waiting on" and "who would be reminded" never disagree.
    def waiting_on(submission)
      return [] unless status(submission) == 'pending'

      IcodosReminderSweep.candidates(submission)
    rescue NameError
      []
    end

    # What the reminder engine will do for this signer, as it would decide it
    # now. The engine is the source; nothing here schedules anything.
    # rubocop:disable Metrics
    def reminders(submission, submitter, now: Time.current)
      return { engine: 'off' } unless IcodosReminders.enabled?

      policy = IcodosReminderSweep.policy_for(submission)
      state = submission.preferences.to_h['icodos_reminder_state'].to_h
      count, last = IcodosReminderSweep.effective_history(submission, submitter)

      info = {
        engine: IcodosReminders.dry_run? ? 'dry run (logs, sends nothing)' : 'live',
        policy: policy.nil? ? 'off' : (policy['preset'] || 'custom'),
        sent: count,
        last_at: IcodosWorkflow.iso(last),
        escalated_at: state['escalated_at']
      }

      return info.compact if policy.nil?

      paused = IcodosReminders.parse_time(policy['paused_until'])

      if paused && paused > now
        info[:paused_until] = IcodosWorkflow.iso(paused)
        info[:next_at] = nil
        info[:note] = 'paused'
      elsif submission.template&.archived_at?
        info[:note] = 'the template is archived; the sweep skips its submissions'
      else
        at = IcodosReminders.next_at(policy: policy, sent_at: submitter.sent_at, sent_count: count,
                                     last_sent_at: last, deadline: policy.dig('before_deadline', 'deadline'),
                                     now: now)
        info[:next_at] = IcodosWorkflow.iso(at)
        info[:note] = at.nil? ? 'no further reminders under this policy' : nil
        info[:note] = 'due at the next sweep (every 15 minutes)' if at && at <= now
      end

      info.compact
    rescue NameError, IcodosReminders::Error => e
      { engine: "unavailable (#{e.class.name})" }
    end
    # rubocop:enable Metrics

    # Where the signed copy goes or went. "server" when the filing hook files
    # it; anything else is filed by the Make scenario or by a person.
    # rubocop:disable Metrics
    def filing(submission)
      prefs = submission.preferences.to_h
      filing = Icodos::FilingHookController::Filing
      dest = filing.destination(submission)

      info = {
        by: dest[:folder] ? 'server (filing hook)' : 'not the server: the Make scenario or a person',
        folder: dest[:folder],
        file_name: dest[:folder] ? filing.signed_filename(submission) : nil,
        filed_path: prefs[FILED_KEY],
        filed: prefs[FILED_KEY].present?
      }

      info[:note] = dest[:skip] if dest[:skip]

      if submission.completed_at? && dest[:folder] && prefs[FILED_KEY].blank?
        info[:note] = 'completed but not filed yet; the hook retries, and the host files it within the hour ' \
                      '(Filing.reconcile)'
      end

      info.compact
    rescue NameError => e
      { by: "unknown (#{e.class.name})" }
    end
    # rubocop:enable Metrics

    def template(submission)
      t = submission.template

      return nil unless t

      { id: t.id, name: t.name, reusable: IcodosWorkflow.reusable?(t) || nil,
        archived: t.archived_at? || nil }.compact
    end

    def actions(submission)
      Array.wrap(submission.preferences.to_h[ACTIONS_KEY]).map do |a|
        a.to_h.slice('at', 'tool', 'action', 'user_id', 'summary')
      end
    end

    # rubocop:disable Metrics
    def summary(submission, now: Time.current)
      waiting = waiting_on(submission)
      created = submission.created_at

      entry = {
        submission_id: submission.id,
        status: status(submission),
        template: template(submission),
        created_at: IcodosWorkflow.iso(created),
        created_by: submission.created_by_user&.email,
        expire_at: IcodosWorkflow.iso(submission.expire_at),
        completed_at: IcodosWorkflow.iso(submission.completed_at)
      }

      if waiting.any?
        entry[:waiting_on] = waiting.map do |s|
          since = s.sent_at || created
          role = roles(submission)[s.uuid].to_h['name']

          { role: role, name: s.name, email: s.email, status: s.status,
            invited_at: IcodosWorkflow.iso(s.sent_at), opened_at: IcodosWorkflow.iso(s.opened_at),
            waiting_days: ((now - since) / 86_400.0).round(1),
            reminders: reminders(submission, s, now: now) }.compact
        end
      end

      signed = submission.submitters.select(&:completed_at?)
      entry[:signed] = signed.map { |s| { name: s.name, at: IcodosWorkflow.iso(s.completed_at) } } if signed.any?

      entry.compact
    end
    # rubocop:enable Metrics
  end

  # ---------------------------------------------------------- ActionTool

  # Included by the three action tools, next to IcodosToolErrors. A tool
  # implements:
  #
  #   load_submission!   the submission, authorized
  #   previewed(sub)     a hash of everything the preview shows; the token
  #                      binds a digest of it
  #   preview_payload    what the preview says (plain hash)
  #   apply!(sub)        does it; returns { summary:, result: }
  #
  # and calls icodos_action(submission). The sequence on a confirmed call:
  #
  #   1. a token is required, and must be one this tool issued
  #   2. the same confirmed call again (same token, same arguments, same
  #      user) answers with what was done, from Redis or, if Redis lost it,
  #      from the record on the submission. Checked BEFORE the token is
  #      compared with the current state, because the action has changed
  #      that state: a correction compared with its own result would read
  #      as "something differs from the preview"
  #   3. the token must match the state and arguments as they are now
  #   4. the nonce is claimed in Redis (SET NX) before anything is done
  #   5. apply!, then the record on the submission, then Redis
  module ActionTool
    InvalidArguments = ::IcodosToolErrors::ToolError

    NEW_PREVIEW = 'Make a new preview and show it to the requester.'

    private

    # The send tool's token, with a key of this tool's own: a token issued
    # by one tool is worthless to another. Resolved when used, not when this
    # file loads, so the load order of lib/ and app/ does not matter.
    def preview_tokens
      Mcp::IcodosSendContractController::PreviewToken
    end

    def icodos_action(submission)
      content = previewed(submission)
      digest = preview_tokens.digest({ 'tool' => tool_name, 'content' => content })

      return render_action_preview(submission, digest) unless mcp_params['confirm'] == true

      token = mcp_params['preview_token'].to_s
      require_token!(token)

      nonce = token.split('.')[2]
      prior = prior_action(submission, nonce)

      return render_replay(submission, prior) if prior

      verify_token!(token, digest)
      claim!(nonce)

      done = nil

      begin
        done = apply!(submission)
      rescue StandardError
        release!(nonce) if @icodos_done.nil? || @icodos_done == 'nothing'
        raise
      end

      record = record_action!(submission, nonce, done)
      finish!(nonce, record)

      render_tool_result({ applied: true, submission_id: submission.id, tool: tool_name }
                           .merge(done[:result] || {}))
    end

    def tool_name
      self.class::SCHEMA[:name]
    end

    def action_key
      Rails.application.key_generator.generate_key("icodos #{tool_name} preview token v1", 32)
    end

    def redis_key(nonce)
      "icodos:#{tool_name}:preview:#{nonce}"
    end

    # The arguments that make a call "the same call", without the two that
    # only confirm it.
    def args_digest
      IcodosAudit.digest(mcp_params.to_h.except('confirm', 'preview_token'))
    end

    def render_action_preview(submission, digest)
      token = preview_tokens.issue(action_key, current_user.id, digest)

      Rails.logger.info("[icodos-contracts] #{tool_name} preview submission=#{submission.id} " \
                        "user_id=#{current_user.id} preview=#{token.split('.')[2][0, 8]}")

      render_tool_result(
        { applied: false, preview: true, submission_id: submission.id, tool: tool_name }
          .merge(preview_payload(submission))
          .merge(preview_token: token,
                 preview_token_expires_at: Time.at(token.split('.')[1].to_i).utc.iso8601,
                 note: 'Nothing has been changed. Show the requester all of the above. If they agree, call ' \
                       'again with exactly the same arguments plus confirm true and this preview_token, before ' \
                       'preview_token_expires_at. The token works once.')
      )
    end

    def require_token!(token)
      if token.blank?
        raise InvalidArguments.new(
          'confirm true needs the preview_token from a preview of exactly these arguments. Nothing was changed.',
          code: 'preview_required',
          hint: 'Call without confirm first, show the preview to the requester, then confirm with its preview_token.'
        )
      end

      return if preview_tokens.const_get(:FORMAT).match?(token)

      raise InvalidArguments.new('preview_token is not a token this tool issued. Nothing was changed.',
                                 code: 'preview_invalid', hint: NEW_PREVIEW)
    end

    # rubocop:disable Metrics
    def verify_token!(token, digest)
      result = preview_tokens.verify(token, action_key, current_user.id, digest)

      case result[:status]
      when :malformed
        raise InvalidArguments.new('preview_token is not a token this tool issued. Nothing was changed.',
                                   code: 'preview_invalid', hint: NEW_PREVIEW)
      when :mismatch
        raise InvalidArguments.new(
          'preview_token does not match: an argument differs from the preview, or the submission changed since ' \
          '(someone signed, opened, or it was corrected), or the token belongs to another preview or user. ' \
          'Nothing was changed.',
          code: 'preview_mismatch', hint: NEW_PREVIEW
        )
      when :expired
        raise InvalidArguments.new(
          "preview_token expired at #{Time.at(result[:exp]).utc.iso8601} (valid 15 minutes). Nothing was changed.",
          code: 'preview_expired', hint: NEW_PREVIEW
        )
      end
    end
    # rubocop:enable Metrics

    # The record of an earlier confirmed call with this nonce: from Redis,
    # else from the submission. Only a call by the same user with the same
    # arguments is that call; any other use of a used token is a mismatch.
    # rubocop:disable Metrics
    def prior_action(submission, nonce)
      stored =
        begin
          ::Sidekiq.redis { |c| c.call('GET', redis_key(nonce)) }
        rescue StandardError => e
          Rails.logger.error("[icodos-contracts] #{tool_name}: preview store unreachable (#{e.class}: #{e.message})")

          raise InvalidArguments.new('the record of used preview tokens (Redis) is not reachable, so nothing was ' \
                                     'changed.', code: 'store_unreachable', retryable: true,
                                                 hint: 'Retry the same call, with the same preview_token, in a minute.')
        end

      record =
        if stored.to_s.start_with?('done:')
          JSON.parse(stored.to_s.delete_prefix('done:'))
        else
          Array.wrap(submission.preferences.to_h[ACTIONS_KEY]).find do |a|
            a['tool'] == tool_name && a['nonce'] == nonce
          end
        end

      if record.nil?
        if stored.to_s.start_with?('pending:')
          raise InvalidArguments.new(
            'another call with this preview_token is being carried out right now. Nothing was changed by this call.',
            code: 'in_progress', retryable: true,
            hint: 'Wait half a minute and repeat the same call; it then answers with what was done.'
          )
        end

        return nil
      end

      return record if record['user_id'] == current_user.id && record['args_sha256'] == args_digest

      raise InvalidArguments.new(
        'this preview_token was already used, for other arguments or by another user. Nothing was changed.',
        code: 'preview_mismatch', hint: NEW_PREVIEW
      )
    end
    # rubocop:enable Metrics

    def claim!(nonce)
      set = ::Sidekiq.redis do |c|
        c.call('SET', redis_key(nonce), "pending:#{current_user.id}", 'NX', 'EX', preview_tokens.const_get(:TTL) + 3600)
      end

      return if set == 'OK'

      raise InvalidArguments.new(
        'another call with this preview_token is being carried out right now. Nothing was changed by this call.',
        code: 'in_progress', retryable: true,
        hint: 'Wait half a minute and repeat the same call; it then answers with what was done.'
      )
    rescue InvalidArguments
      raise
    rescue StandardError => e
      Rails.logger.error("[icodos-contracts] #{tool_name}: preview store unreachable (#{e.class}: #{e.message})")

      raise InvalidArguments.new('the record of used preview tokens (Redis) is not reachable, so nothing was changed.',
                                 code: 'store_unreachable', retryable: true,
                                 hint: 'Retry the same call, with the same preview_token, in a minute.')
    end

    def release!(nonce)
      ::Sidekiq.redis { |c| c.call('DEL', redis_key(nonce)) }
    rescue StandardError
      nil
    end

    # rubocop:disable Metrics
    def record_action!(submission, nonce, done)
      record = {
        'at' => Time.current.utc.iso8601,
        'tool' => tool_name,
        'action' => done[:action].to_s,
        'nonce' => nonce,
        'user_id' => current_user.id,
        'args_sha256' => args_digest,
        'summary' => done[:summary].to_s[0, 500],
        'result' => done[:result] || {}
      }

      submission.reload
      prefs = submission.preferences.to_h
      list = Array.wrap(prefs[ACTIONS_KEY]) + [record]
      submission.update!(preferences: prefs.merge(ACTIONS_KEY => list.last(MAX_ACTIONS)))

      Rails.logger.info("[icodos-contracts] #{tool_name} applied submission=#{submission.id} " \
                        "action=#{record['action']} user_id=#{current_user.id} preview=#{nonce[0, 8]}")

      record
    rescue StandardError => e
      # Done but not recorded on the submission. Redis still makes a repeat a
      # replay; the log line is what a person would look for.
      Rails.logger.error("[icodos-contracts] #{tool_name}: applied to submission #{submission.id} but could not " \
                         "record it (#{e.class}: #{e.message})")

      record
    end
    # rubocop:enable Metrics

    def finish!(nonce, record)
      ::Sidekiq.redis do |c|
        c.call('SET', redis_key(nonce), "done:#{JSON.generate(record)}", 'EX', 7 * 24 * 3600)
      end
    rescue StandardError => e
      Rails.logger.error("[icodos-contracts] #{tool_name}: could not record the result in Redis " \
                         "(#{e.class}: #{e.message}); the record on the submission stands in")
    end

    def render_replay(submission, record)
      Rails.logger.info("[icodos-contracts] #{tool_name} replayed submission=#{submission.id} " \
                        "user_id=#{current_user.id}")

      render_tool_result(
        { applied: true, replayed: true, submission_id: submission.id, tool: tool_name }
          .merge(record['result'].to_h.symbolize_keys)
          .merge(note: "This preview_token was already used at #{record['at']}; this is what was done then. " \
                       'Nothing was changed again.')
      )
    end

    # The submission, if this user may change it.
    def load_submission!
      submission = Submission.accessible_by(current_ability).find(mcp_params['submission_id'])

      authorize!(:update, submission)

      unless IcodosGraph.enabled?
        raise InvalidArguments.new('the contract tools are not enabled on this instance', code: 'disabled')
      end

      submission
    end

    # A confirmed call whose token was used before answers with what was done
    # then. Asked right after the submission is loaded, before any check of
    # its current state: the action changed that state, so a repeated void
    # would otherwise read "not pending" and a repeated correction "nothing
    # to correct", which an agent might try to "fix".
    def replayed?(submission)
      return false unless mcp_params['confirm'] == true

      token = mcp_params['preview_token'].to_s

      return false unless preview_tokens.const_get(:FORMAT).match?(token)

      prior = prior_action(submission, token.split('.')[2])

      return false unless prior

      render_replay(submission, prior)

      true
    end

    def ensure_pending!(submission)
      state = View.status(submission)

      return if state == 'pending'

      raise InvalidArguments.new(
        "submission #{submission.id} is #{state}; only a pending submission can be changed here.",
        code: 'not_pending',
        hint: 'Look at it with icodos_get_submission. A signed document is changed only by a new document.'
      )
    end
  end

  # ------------------------------------------------------------ Lifecycle

  # Contract templates made by icodos_create_contract_template are single
  # use: one draft, one send. Once their documents are signed and filed by
  # the server, or voided, they only lengthen the template list (about 25 a
  # month, nearly all monthly time declarations). Archived, not deleted: an
  # archived template keeps its submissions and documents, can be restored
  # in the web interface, and its signing links already led nowhere.
  #
  # Not before a day has passed since the last of them was completed or
  # voided: the Make scenario completes the Notion page from the same
  # completion webhook, and nothing here should race it. Reusable templates
  # are never archived here, nor templates without a submission (a send may
  # still be coming), nor one with a submission the server does not file.
  module Lifecycle
    MIN_AGE = 24 * 3600

    module_function

    # rubocop:disable Metrics
    def archive_filed_templates(now: Time.current, min_age: MIN_AGE, dry_run: false)
      archived = []

      Template.where(external_id: MARKER, archived_at: nil).find_each do |template|
        next if IcodosWorkflow.reusable?(template)

        submissions = Submission.where(template_id: template.id).to_a

        next if submissions.empty?

        settled = submissions.all? do |s|
          if s.archived_at?
            s.archived_at < now - min_age
          else
            s.completed_at? && s.completed_at < now - min_age && s.preferences.to_h[FILED_KEY].present?
          end
        end

        next unless settled

        archived << template.id

        next if dry_run

        template.update!(archived_at: now,
                         preferences: template.preferences.to_h.merge(ARCHIVED_BY_KEY => now.utc.iso8601))
      rescue StandardError => e
        Rails.logger.error("[icodos-contracts] lifecycle: template #{template.id}: #{e.class}: #{e.message}")
      end

      line = "[icodos-contracts] lifecycle: #{archived.size} template(s) #{dry_run ? 'would be ' : ''}archived " \
             "(signed and filed, or voided, more than #{min_age / 3600} h ago)" \
             "#{archived.any? ? ": #{archived.first(30).join(',')}#{archived.size > 30 ? ',…' : ''}" : ''}"
      Rails.logger.info(line)
      puts line

      archived
    end
    # rubocop:enable Metrics
  end

  # ------------------------------------------------------------ Retention

  # SharePoint is the record: the filing hook puts the signed PDF there, the
  # audit trail inside it. What this server keeps after that (the draft, the
  # signed PDF, each signer's copy, the signature images, the audit trail)
  # is a second copy on an internet-facing host, and the one a compromise of
  # it would expose. Decided on 26 November 2026 (D7): removed 90 days after
  # completion, for documents the server filed itself, and only while the
  # filed copy is still at its recorded path in SharePoint (a file moved or
  # deleted there keeps its documents here, and the log says so).
  #
  # The database records stay: the submission, its signers, the event
  # history, the filing path. The nightly backup keeps its copies for its
  # own retention (12 months locally; the off-site copy never deletes).
  # Documents filed by the Make scenario or by hand are not touched: nothing
  # on this server proves where they went.
  #
  # ICODOS_DOCUMENT_RETENTION_DAYS: a number of days (at least 30), or off.
  module Retention
    DEFAULT_DAYS = 90
    MIN_DAYS = 30
    MAX_PER_RUN = 25
    # When a submission kept its documents because its filed copy was not
    # at the recorded path. Checked again a day later, not every hour.
    KEPT_KEY = 'icodos_retention_kept_at'
    RECHECK = 24 * 3600

    module_function

    def days
      raw = ENV['ICODOS_DOCUMENT_RETENTION_DAYS'].to_s.strip

      return DEFAULT_DAYS if raw.empty?
      return nil if raw.casecmp('off').zero?

      value = Integer(raw, 10)
      value < MIN_DAYS ? MIN_DAYS : value
    rescue ArgumentError
      Rails.logger.error("[icodos-contracts] ICODOS_DOCUMENT_RETENTION_DAYS=#{raw.inspect} is not a number of days; " \
                         "using #{DEFAULT_DAYS}")
      DEFAULT_DAYS
    end

    def describe
      days ? "#{days}d" : 'off'
    end

    # Every submission due, oldest first. The limit applies to removals, not
    # to candidates: a first version cut the list at 25 before the SharePoint
    # check, so 25 submissions whose filed copy had moved would have held
    # every later one back for good.
    def due(now: Time.current)
      return [] unless days

      Submission.where(archived_at: nil).where('completed_at < ?', now - days * 86_400)
                .order(:completed_at).to_a
                .select do |s|
                  prefs = s.preferences.to_h
                  kept = prefs[KEPT_KEY].present? && Time.zone.parse(prefs[KEPT_KEY].to_s)

                  prefs[FILED_KEY].present? && prefs[PURGED_KEY].blank? && !(kept && kept > now - RECHECK)
                end
    end

    # rubocop:disable Metrics
    def purge_filed_documents(now: Time.current, dry_run: false, limit: MAX_PER_RUN)
      purged = []
      kept = []

      due(now: now).each do |submission|
        break if purged.size >= limit

        path = submission.preferences.to_h[FILED_KEY]

        unless IcodosGraph.exists?(path)
          kept << submission.id
          Rails.logger.warn("[icodos-contracts] retention: submission #{submission.id} keeps its documents: the " \
                            "filed copy is no longer at #{path.inspect} in SharePoint")
          submission.update!(preferences: submission.preferences.to_h.merge(KEPT_KEY => now.utc.iso8601)) unless dry_run
          next
        end

        purged << submission.id

        next if dry_run

        purge_submission!(submission, now)
        purge_template_if_settled!(submission.template, now)
      rescue StandardError => e
        kept << submission.id
        Rails.logger.error("[icodos-contracts] retention: submission #{submission.id}: #{e.class}: #{e.message}")
      end

      line = "[icodos-contracts] retention (#{describe}): documents of #{purged.size} submission(s) " \
             "#{dry_run ? 'would be ' : ''}removed#{purged.any? ? " (#{purged.join(',')})" : ''}" \
             "#{kept.any? ? ", #{kept.size} kept (#{kept.join(',')}), see the log" : ''}"
      Rails.logger.info(line)
      puts line

      purged
    end
    # rubocop:enable Metrics

    def purge_submission!(submission, now)
      %i[audit_trail combined_document merged_document preview_merged_document preview_documents documents]
        .each { |name| purge_attached(submission.public_send(name)) }

      submission.submitters.each do |submitter|
        %i[documents attachments preview_documents].each { |name| purge_attached(submitter.public_send(name)) }
      end

      submission.update!(preferences: submission.preferences.to_h.merge(PURGED_KEY => now.utc.iso8601))
    end

    # The draft goes too, once the template is archived (Lifecycle) and
    # every submission of it has had its documents removed. Never the form
    # of a reusable template.
    def purge_template_if_settled!(template, now)
      return if template.nil? || !template.archived_at? || IcodosWorkflow.reusable?(template)
      return if template.preferences.to_h[PURGED_KEY].present?

      others = Submission.where(template_id: template.id).to_a

      return unless others.all? { |s| s.archived_at? || s.preferences.to_h[PURGED_KEY].present? }

      purge_attached(template.documents)
      template.update!(preferences: template.preferences.to_h.merge(PURGED_KEY => now.utc.iso8601))
    end

    def purge_attached(attached)
      attached.purge if attached.attached?
    end
  end

  # --------------------------------------------------------------- Digest

  # One plain-text mail a week, Monday morning, from the host's
  # docuseal-digest.timer: what was sent, signed and filed in the last seven
  # days, what is waiting and on whom, and what needs a person. Recipients
  # in ICODOS_DIGEST_TO (comma-separated); without it the digest is printed,
  # not mailed.
  module Digest
    PERIOD = 7 * 86_400

    module_function

    def recipients
      ENV['ICODOS_DIGEST_TO'].to_s.split(',').map(&:strip).select { |a| a.match?(/\A[^@\s]+@[^@\s]+\z/) }
    end

    # rubocop:disable Metrics
    def build(now: Time.current)
      since = now - PERIOD
      view = View
      all = Submission.includes(:submitters, :template).where('created_at > ? OR completed_at > ? OR ' \
                                                             '(completed_at IS NULL AND archived_at IS NULL)',
                                                             since, since).to_a
      sent = all.select { |s| s.created_at > since }
      signed = all.select { |s| s.completed_at && s.completed_at > since }
      pending = all.select { |s| view.status(s) == 'pending' }
                   .sort_by { |s| s.submitters.filter_map(&:sent_at).min || s.created_at }
      unfiled = Submission.where('completed_at > ? AND completed_at < ?', now - 30 * 86_400, now - 3600).to_a
                          .select { |s| (f = view.filing(s))[:folder].present? && !f[:filed] }
      declined = all.select { |s| s.submitters.any? { |x| x.declined_at && x.declined_at > since } }
      expired = all.select { |s| !s.completed_at? && s.expire_at && s.expire_at.between?(since, now) }
      archived = Template.where('archived_at > ?', since).to_a.count { |t| t.preferences.to_h[ARCHIVED_BY_KEY].present? }
      purged = Submission.where('completed_at < ?', since).to_a.count do |s|
        (at = s.preferences.to_h[PURGED_KEY]).present? && Time.zone.parse(at) > since
      end
      filed = signed.count { |s| s.preferences.to_h[FILED_KEY].present? }

      name = ->(s) { "#{s.template&.name || "submission #{s.id}"} (#{s.id})" }
      lines = []
      lines << "Week to #{now.utc.strftime('%Y-%m-%d %H:%M')} UTC."
      lines << ''
      lines << "Sent: #{sent.size}. Signed: #{signed.size}, of which filed by the server: #{filed}. " \
               "Waiting: #{pending.size}."
      lines << ''

      attention = []
      unfiled.each { |s| attention << "NOT FILED: #{name.call(s)}, completed #{s.completed_at.utc.strftime('%Y-%m-%d')}" }
      declined.each { |s| attention << "DECLINED: #{name.call(s)}" }
      expired.each { |s| attention << "EXPIRED unsigned: #{name.call(s)}" }
      pending.each do |s|
        view.waiting_on(s).each do |w|
          r = view.reminders(s, w, now: now)
          next unless r[:escalated_at] || (w.sent_at && now - w.sent_at > 14 * 86_400)

          attention << "WAITING #{((now - (w.sent_at || s.created_at)) / 86_400).floor} days: #{name.call(s)}, on " \
                       "#{w.name} <#{w.email}>#{r[:escalated_at] ? ', reminders ended (escalated)' : ''}"
        end
      end

      lines << 'Needs a person:'
      lines += attention.any? ? attention.map { |a| "  - #{a}" } : ['  nothing']
      lines << ''
      lines << 'Waiting for a signature (longest first):'

      if pending.empty?
        lines << '  nothing'
      else
        pending.first(40).each do |s|
          w = view.waiting_on(s).first

          if w
            r = view.reminders(s, w, now: now)
            nxt = r[:paused_until] ? 'reminders paused' : (r[:next_at] ? "next reminder #{r[:next_at][0, 10]}" : 'no further reminder')
            lines << "  - #{name.call(s)}: #{w.name} <#{w.email}>, #{((now - (w.sent_at || s.created_at)) / 86_400).floor} " \
                     "days, #{r[:sent].to_i} reminder(s), #{nxt}"
          else
            lines << "  - #{name.call(s)}: nobody invited yet"
          end
        end
        lines << "  … and #{pending.size - 40} more" if pending.size > 40
      end

      lines << ''
      lines << 'Signed this week:'
      lines += signed.empty? ? ['  nothing'] : signed.sort_by(&:completed_at).map do |s|
        f = view.filing(s)
        where = f[:filed] ? "filed: #{f[:filed_path]}" : (f[:folder] ? 'NOT FILED YET' : 'filed by Make or by hand')
        "  - #{name.call(s)}, #{s.completed_at.utc.strftime('%Y-%m-%d')}, #{where}"
      end
      lines << ''
      lines << "Housekeeping: #{archived} template(s) archived after filing, documents of #{purged} submission(s) " \
               "removed after #{Retention.describe} (SharePoint keeps the record)."
      lines << ''
      lines << 'Details of any document: ask Claude with icodos_get_submission and the number in brackets.'

      subject = "DocuSeal week: #{sent.size} sent, #{signed.size} signed, #{pending.size} waiting" \
                "#{attention.any? ? ", #{attention.size} need a person" : ''}"

      { subject: subject, body: lines.join("\n") }
    end
    # rubocop:enable Metrics

    def call(deliver: false, now: Time.current)
      digest = build(now: now)
      to = recipients

      if deliver && to.any?
        DigestMailer.digest(to: to, subject: digest[:subject], body: digest[:body]).deliver_now!
        Rails.logger.info("[icodos-contracts] digest sent to #{to.size} recipient(s): #{digest[:subject]}")
        puts "[icodos-contracts] digest sent to #{to.join(', ')}: #{digest[:subject]}"
      else
        puts digest[:subject]
        puts
        puts digest[:body]
        puts
        puts deliver ? '[icodos-contracts] digest not sent: ICODOS_DIGEST_TO names no recipient' : '(not sent: deliver is false)'
      end

      digest
    end
  end

  # The digest's mailer. ApplicationMailer's interceptor sets the sender and
  # the relay exactly as for every other mail of this instance.
  class DigestMailer < ApplicationMailer
    def digest(to:, subject:, body:)
      mail(to: to, subject: subject) do |format|
        format.text { render plain: body }
      end
    end
  end
end
