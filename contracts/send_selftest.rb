# encoding: utf-8
# frozen_string_literal: true

# ICODOS Phase E — offline self-test for the guards of icodos_send_contract.
#
# Runs without Rails, network or credentials, with any Ruby from 2.6:
#
#   ruby contracts/send_selftest.rb
#
# Covers what can be decided without a database: the preview token (binding,
# expiry, tampering, another user), the fixed-term pattern (plan step 4.4)
# against the document names this instance actually uses, and the scrubbing
# of caller-supplied text in the note to the first signer. The request-level
# behaviour is tested on the scratch stack (ops/staging/t3_tests.py).

require 'json'
require 'openssl'
require 'securerandom'

module Mcp
  class McpBaseController; end
end

require_relative 'send_contract_controller'

C = Mcp::IcodosSendContractController
T = C::PreviewToken
FAILS = []

def check(label, ok, detail = '')
  puts format('  %-52s %s  %s', label, ok ? 'ok  ' : 'FAIL', detail)
  FAILS << label unless ok
end

puts 'preview token'

key = SecureRandom.random_bytes(32)
content = { 'template_id' => 7, 'signers' => [%w[Employer A a@icodos.com], %w[Employee B b@example.org]],
            'filing_folder' => 'X/Y', 'expire_at' => nil, 'email_code' => true,
            'emails' => [['Employer', 'S', "Body\n\nnote"], ['Employee', 'S', 'Body']] }
digest = T.digest(content)
reordered = content.to_a.reverse.to_h
now = 1_800_000_000
token = T.issue(key, 1, digest, now: now)

check 'digest ignores key order', T.digest(reordered) == digest
check 'format', token.match?(T::FORMAT), token[0, 20]
check 'same arguments, same user: ok', T.verify(token, key, 1, digest, now: now + 60)[:status] == :ok
check 'nonce returned', T.verify(token, key, 1, digest, now: now)[:nonce] == token.split('.')[2]
check 'valid at 15 minutes', T.verify(token, key, 1, digest, now: now + 900)[:status] == :ok
check 'expired after 15 minutes', T.verify(token, key, 1, digest, now: now + 901)[:status] == :expired

changed = Marshal.load(Marshal.dump(content))
changed['signers'][1][2] = 'attacker@example.net'
check 'second signer address changed: mismatch', T.verify(token, key, 1, T.digest(changed), now: now)[:status] == :mismatch

changed = Marshal.load(Marshal.dump(content))
changed['emails'][1][2] = 'Body with a link'
check 'message changed: mismatch', T.verify(token, key, 1, T.digest(changed), now: now)[:status] == :mismatch

changed = Marshal.load(Marshal.dump(content))
changed['email_code'] = false
check 'email code switched off: mismatch', T.verify(token, key, 1, T.digest(changed), now: now)[:status] == :mismatch

check 'another user: mismatch', T.verify(token, key, 2, digest, now: now)[:status] == :mismatch
check 'another key: mismatch', T.verify(token, SecureRandom.random_bytes(32), 1, digest, now: now)[:status] == :mismatch

parts = token.split('.')
later = [parts[0], (parts[1].to_i + 3600).to_s, parts[2], parts[3]].join('.')
check 'expiry moved forward: mismatch', T.verify(later, key, 1, digest, now: now)[:status] == :mismatch
other_nonce = [parts[0], parts[1], SecureRandom.hex(16), parts[3]].join('.')
check 'nonce swapped: mismatch', T.verify(other_nonce, key, 1, digest, now: now)[:status] == :mismatch

%w[true 1 pv1 pv1.1.2.3].push('', nil, token.upcase, "#{token}x", token.sub('pv1', 'pv2')).each do |bad|
  check "malformed #{bad.inspect[0, 24]}", T.verify(bad, key, 1, digest, now: now)[:status] == :malformed
end

check 'secure_compare equal', T.secure_compare('abc', 'abc')
check 'secure_compare differs', !T.secure_compare('abc', 'abd')
check 'secure_compare length', !T.secure_compare('abc', 'abcd')

puts 'fixed-term pattern (4.4)'

[
  'Werkstudent / Working Student', 'Praktikant / Intern', 'Internship Contract', 'Thesis Contract Amendment',
  'Werkstudentenvertrag', 'Befristeter Arbeitsvertrag', 'Befristung', 'Fixed-term contract',
  'fixed term employment', 'Contract Extension', 'Verlängerung des Arbeitsvertrags', 'Verlaengerung',
  'Masterarbeit Vereinbarung', 'Abschlussarbeit', 'Praktikumsvertrag', 'Interns 2027',
  '20260727-Max Mustermann-Thesis Contract Amendment-v1.pdf', 'ends due to the time limitation'
].each do |name|
  check "refuses #{name.inspect}", name.unicode_normalize(:nfc).match?(C::FIXED_TERM_PATTERN)
end

[
  'Employer (ICODOS GmbH)', 'Arbeitnehmer / Employee', 'Supervisor', 'Employee', 'Mitarbeiter / Employee',
  'Monthly time declaration November 2026', 'Unbefristeter Arbeitsvertrag', 'unbefristet',
  'Amendment to Employment Contract, Erika Mustermann', 'Internal policy acknowledgement', 'International',
  'VSOP Agreement', 'Permanent contract', 'Chair of the Advisory Board', 'Signed Off Time Reporting Sheets',
  'Arbeitnehmerin / Employee (Participant)', 'Trabajadora / Employee'
].each do |name|
  check "passes #{name.inspect}", !name.unicode_normalize(:nfc).match?(C::FIXED_TERM_PATTERN)
end

puts 'note to the first signer'

ctl = C.allocate
check 'markdown link removed', !ctl.send(:plain, '[click](https://evil.example)').include?('](')
check 'url not auto-linked', !ctl.send(:plain, 'https://evil.example').include?('://')
check 'www not auto-linked', !ctl.send(:plain, 'www.evil.example').include?('www.')
check 'variables neutralised', !ctl.send(:plain, '{submitter.link}').match?(/[{}]/)
check 'html neutralised', !ctl.send(:plain, '<a href=x>y</a>').match?(/[<>]/)
check 'emphasis neutralised', !ctl.send(:plain, '**bold** ~~x~~').match?(/[*~]/)
check 'newline removed', !ctl.send(:plain, "a\nb").include?("\n")
check 'plus address kept', ctl.send(:plain, 'jane+hr@example.org') == 'jane+hr@example.org'
check 'umlaut name kept', ctl.send(:plain, 'Jörg Müller') == 'Jörg Müller'
check 'parentheses kept', ctl.send(:plain, '000014 Max (Max Peter Mustermann)') == '000014 Max (Max Peter Mustermann)'

ordered = [{ 'role' => 'Employer (ICODOS GmbH)', 'name' => 'A', 'email' => 'a@icodos.com' },
           { 'role' => 'Arbeitnehmer / Employee', 'name' => 'Jane Doe', 'email' => 'jane@example.org' }]
note = ctl.send(:first_signer_note, ordered, 'General/Signed Contracts/000099 Jane Doe', nil)
check 'note names the next signer', note.include?('Arbeitnehmer / Employee: Jane Doe, jane@example.org')
check 'note names the filing folder', note.include?('General/Signed Contracts/000099 Jane Doe')
check 'note does not name the first signer', !note.include?('a@icodos.com')

puts 'email code per signer (4.2, D14)'

pair = [{ 'email' => 'a@icodos.com' }, { 'email' => 'jane@private.example' }]
codes = lambda do |policy, arg|
  ENV['ICODOS_CONTRACTS_EMAIL_CODE'] = policy
  c = C.allocate
  c.define_singleton_method(:mcp_params) { arg.nil? ? {} : { 'require_email_code' => arg } }
  c.send(:resolve_email_codes!, pair)
end
check 'default: outside address only', codes.call(nil, nil) == [false, true]
check 'external: outside address only', codes.call('external', nil) == [false, true]
check 'all: everyone', codes.call('all', nil) == [true, true]
check 'off: nobody', codes.call('off', nil) == [false, false]
check 'unknown value falls back to external', codes.call('on', nil) == [false, true]
check 'call says true: everyone', codes.call('off', true) == [true, true]
check 'call says false: nobody', codes.call('all', false) == [false, false]
check 'string "true" refused', (codes.call(nil, 'true') rescue C::InvalidArguments) == C::InvalidArguments
ENV.delete('ICODOS_CONTRACTS_EMAIL_CODE')

puts
if FAILS.empty?
  puts 'all checks passed'
else
  puts "#{FAILS.length} FAILED: #{FAILS.join(', ')}"
  exit 1
end
