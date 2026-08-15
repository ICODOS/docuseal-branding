# encoding: utf-8
# frozen_string_literal: true

# ICODOS Phase E — offline self-test for icodos_graph.rb.
#
# Runs without Rails, without network and without credentials. Covers the two
# things that are cheap to get wrong and expensive to discover in production:
# the path allowlist (the security boundary) and the site/drive lock ordering
# (which deadlocked on first use before the fix on 15 Aug 2026).
#
#   ruby contracts/selftest.rb

P = 'General/09 Legal Documents/10 Contracts/01 Employee contracts'
ENV['ICODOS_CONTRACTS_PATH_PREFIX'] = P

# Deliberately fake — get_json is stubbed below, so these only have to be
# present for URL construction. No real tenant is contacted by this file.
ENV['ICODOS_GRAPH_SITE_HOSTNAME'] = 'example.sharepoint.com'
ENV['ICODOS_GRAPH_SITE_PATH'] = '/sites/SelfTest'

require_relative 'icodos_graph'

FAILS = []

def check(label, ok, detail = '')
  puts format('  %-30s %s  %s', label, ok ? 'ok  ' : 'FAIL', detail)
  FAILS << label unless ok
end

# ---------------------------------------------------------------- allowlist

MUST_REJECT = [
  ['empty',                   ''],
  ['absolute etc',            '/etc/passwd'],
  ['traversal out',           'General/../../etc/passwd'],
  ['traversal to sibling',    "#{P}/../Payroll/salaries.xlsx"],
  ['string-prefix bypass',    "#{P} evil/x.pdf"],
  ['sibling suffix',          "#{P}X/y.pdf"],
  ['colon truncation',        "#{P}/a:b.pdf"],
  ['backslash traversal',     'General\\..\\..\\x.pdf'],
  ['parent of prefix',        'General/09 Legal Documents/10 Contracts'],
  ['wildcard',                "#{P}/*.pdf"],
  ['control char',            "#{P}/a\nb.pdf"],
  ['dot segment',             "#{P}/./x.pdf"],
  ['different top folder',    'Shared/09 Legal Documents/10 Contracts/01 Employee contracts/x.pdf']
].freeze

MUST_ACCEPT = [
  ['prefix itself',           P],
  ['signed contract',         "#{P}/Signed Contracts/000029 Devraj Solanki/x.pdf"],
  ['working draft',           "#{P}/Archive/Working versions of employee contracts/f.pdf"],
  ['umlaut + spaces',         "#{P}/Signed Contracts/000031 Jörg Müller/Änderung.pdf"],
  ['leading slash tolerated', "/#{P}/x.pdf"],
  ['duplicated separators',   "#{P}//Signed Contracts///x.pdf"]
].freeze

puts "\npath allowlist — must reject\n\n"

MUST_REJECT.each do |label, input|
  begin
    got = IcodosGraph.normalize_path!(input)
    check(label, false, "accepted -> #{got.inspect}")
  rescue IcodosGraph::PathError => e
    check(label, true, "rejected (#{e.message})")
  end
end

puts "\npath allowlist — must accept\n\n"

MUST_ACCEPT.each do |label, input|
  begin
    got = IcodosGraph.normalize_path!(input)
    check(label, got.start_with?(P), got)
  rescue StandardError => e
    check(label, false, "rejected a valid path (#{e.message})")
  end
end

# ------------------------------------------------------------- lock ordering

# REGRESSION: site_id and drive_id originally shared one mutex. drive_id takes
# the lock and then calls site_id, which takes it again — Ruby's Mutex is not
# reentrant, so this raised "ThreadError: deadlock; recursive locking" on the
# first resolution in any fresh process. It was never reached in the allowlist
# tests because those never touch Graph, and it only surfaced because a 403
# left @site_id unmemoised. drive_id is the entry point for every download and
# upload, so this would have fired on first real use.

puts "\nsite/drive resolution\n\n"

module IcodosGraph
  class << self
    attr_accessor :stub_error

    def get_json(url, _context = nil)
      raise stub_error if stub_error

      url.include?('/drive') ? { 'id' => 'DRIVE123' } : { 'id' => 'SITE123' }
    end
  end
end

def reset_resolution!
  IcodosGraph.instance_variable_set(:@site_id, nil)
  IcodosGraph.instance_variable_set(:@drive_id, nil)
  IcodosGraph.stub_error = nil
end

# drive_id FIRST, from cold — the exact path that used to deadlock.
reset_resolution!
begin
  got = IcodosGraph.drive_id
  check('drive_id from cold', got == 'DRIVE123', got.to_s)
rescue ThreadError => e
  check('drive_id from cold', false, "DEADLOCK REGRESSION: #{e.message}")
rescue StandardError => e
  check('drive_id from cold', false, "#{e.class}: #{e.message}")
end

# site_id first, then drive_id — the already-warm path.
reset_resolution!
begin
  IcodosGraph.site_id
  check('drive_id when site warm', IcodosGraph.drive_id == 'DRIVE123')
rescue StandardError => e
  check('drive_id when site warm', false, "#{e.class}: #{e.message}")
end

# A failing site lookup must surface the real error, not a lock error — this is
# what a missing Sites.Selected per-site grant looks like in production.
reset_resolution!
IcodosGraph.stub_error = IcodosGraph::GraphError.new('graph 403 accessDenied', status: 403)
begin
  IcodosGraph.drive_id
  check('403 propagates from drive_id', false, 'no error raised')
rescue ThreadError => e
  check('403 propagates from drive_id', false, "masked by lock error: #{e.message}")
rescue IcodosGraph::GraphError => e
  check('403 propagates from drive_id', e.status == 403, e.message)
end

# Memoisation still holds after a success.
reset_resolution!
IcodosGraph.drive_id
IcodosGraph.stub_error = RuntimeError.new('should not be called again')
begin
  check('drive_id memoised', IcodosGraph.drive_id == 'DRIVE123')
rescue StandardError => e
  check('drive_id memoised', false, "re-resolved: #{e.message}")
end

# --------------------------------------------------------- redirect handling

# Graph answers /content with a redirect to a pre-authenticated URL. The
# follow-up carries contract bytes (on upload) and must never carry the bearer
# token, so the target host is checked rather than trusted.

puts "\ncontent redirect handling\n\n"

FakeResp = Struct.new(:status, :headers, :body)

module IcodosGraph
  class << self
    # A .sharepoint.com target now gets a SharePoint-audience token attached,
    # so this must be stubbed or the test would try to reach Entra.
    def access_token(_resource = nil)
      'STUB'
    end

    def connection
      @stub_conn ||= begin
        o = Object.new
        def o.get(url)
          req = Struct.new(:headers, :body).new({}, nil)
          yield req if block_given?
          FakeResp.new(200, {}, "GET #{url} auth=#{req.headers['Authorization'].inspect}")
        end

        def o.put(url)
          req = Struct.new(:headers, :body).new({}, nil)
          yield req if block_given?
          FakeResp.new(201, {}, "PUT #{url} auth=#{req.headers['Authorization'].inspect}")
        end
        o
      end
    end
  end
end

def expect_redirect_error(label, location, method: :get, fragment: nil)
  resp = FakeResp.new(302, { 'location' => location }, '')
  IcodosGraph.follow_content_redirect!(resp, method, 'probe')
  check(label, false, 'no error raised')
rescue IcodosGraph::GraphError => e
  check(label, fragment.nil? || e.message.include?(fragment), e.message)
end

expect_redirect_error('rejects foreign host',  'https://evil.example.com/upload', fragment: 'unexpected host')
expect_redirect_error('rejects plain http',    'http://icodos.sharepoint.com/x',  fragment: 'not https')
expect_redirect_error('rejects missing target', '',                               fragment: 'no Location')
expect_redirect_error('rejects lookalike host', 'https://sharepoint.com.evil.io/x', fragment: 'unexpected host')

# An allowed host is followed, and the method is preserved — a browser-style
# redirect follower would downgrade the upload PUT to a GET and write nothing.
begin
  resp = FakeResp.new(302, { 'location' => 'https://icodos.sharepoint.com/_upload/abc' }, '')
  got = IcodosGraph.follow_content_redirect!(resp, :put, 'probe', body: 'x', content_type: 'text/plain')
  ok = got.status == 201 && got.body.start_with?('PUT') && got.body.include?('auth="Bearer STUB"')
  check('sharepoint host: PUT + token', ok, got.body.to_s)
rescue StandardError => e
  check('sharepoint host: PUT + token', false, "#{e.class}: #{e.message}")
end

# A non-SharePoint allowed host must get NO credential — it is treated as
# genuinely pre-authenticated, and handing a token to a host we do not operate
# is the thing worth not doing.
begin
  resp = FakeResp.new(302, { 'location' => 'https://abc.svc.ms/download/xyz' }, '')
  got = IcodosGraph.follow_content_redirect!(resp, :get, 'probe')
  ok = got.status == 200 && got.body.start_with?('GET') && got.body.include?('auth=nil')
  check('svc.ms host: GET, no token', ok, got.body.to_s)
rescue StandardError => e
  check('svc.ms host: GET, no token', false, "#{e.class}: #{e.message}")
end

puts
if FAILS.empty?
  puts 'selftest: all checks passed'
  exit 0
else
  puts "selftest: #{FAILS.size} FAILURE(S) — #{FAILS.join(', ')}"
  exit 1
end
