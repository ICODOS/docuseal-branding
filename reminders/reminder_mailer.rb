# frozen_string_literal: true

# ICODOS — the reminder email itself.
#
# Overlay repo: https://github.com/ICODOS/docuseal-branding
# Mounted read-only at /app/app/mailers/icodos_reminder_mailer.rb.
#
# SUBCLASSES SubmitterMailer ON PURPOSE. Getting a signature email to actually
# arrive depends on from_address_for_submitter, build_submitter_reply_to,
# maybe_set_custom_domain, the account locale and the message metadata — all of
# which upstream already gets right. Writing a mailer from scratch would mean
# re-deriving every one of those and getting one wrong.
#
# It renders submitter_mailer/invitation_email, so the layout, the signing link
# and the ICODOS branding overrides all apply unchanged.
#
# WORDING. DocuSeal's shipped default for the reminder key is identical to the
# invitation — subject "You are invited to sign a document". As a reminder that
# reads as though the system forgot it had already written, so the subject gets a
# "Reminder:" prefix unless someone has configured their own reminder subject.
# The per-template override (invitation_reminder_email_subject / _body, editable
# in DocuSeal's own template preferences) always wins.

class IcodosReminderMailer < SubmitterMailer
  REMINDER_PREFIX = 'Reminder: '

  def reminder_email(submitter, note: nil, sent_count: 0)
    @current_account = submitter.submission.account
    @submitter = submitter
    @sent_count = sent_count

    template_preferences = submitter.template&.preferences.to_h

    @body = template_preferences['invitation_reminder_email_body'].presence
    @subject = template_preferences['invitation_reminder_email_subject'].presence

    @email_config = AccountConfigs.find_for_account(@current_account,
                                                   AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY)

    @body ||= fetch_config_email_body(@email_config, @submitter)
    @body = prepend_note(@body, note) if note.present?

    assign_message_metadata('submitter_invitation_reminder', @submitter)

    reply_to = build_submitter_reply_to(@submitter, email_config: @email_config)

    maybe_set_custom_domain(@submitter)

    I18n.with_locale(@current_account.locale) do
      mail(
        to: @submitter.friendly_name,
        from: from_address_for_submitter(submitter),
        subject: reminder_subject(build_invite_subject(@subject, @email_config, submitter)),
        reply_to: reply_to,
        template_path: 'submitter_mailer',
        template_name: 'invitation_email'
      )
    end
  end

  private

  # Avoids "Reminder: Reminder:" when someone has already written the word into
  # their own subject.
  def reminder_subject(subject)
    text = subject.to_s

    return text if text.downcase.include?('reminder') || text.downcase.include?('erinnerung')

    "#{REMINDER_PREFIX}#{text}"
  end

  # A per-send note, which Adobe supports and which is the difference between
  # "please sign this" and "needed for the July grant report". Placed above the
  # body so it is the first thing read.
  def prepend_note(body, note)
    "#{note.to_s.strip}\n\n#{body}"
  end
end
