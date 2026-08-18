# encoding: utf-8
# frozen_string_literal: true

# ICODOS — offline self-test for icodos_reveal.rb.
#
# No Rails, no network, no tenant. Covers the checks that decide whether the API
# key is handed over: auth_time freshness, intent binding, and single-use
# grants. Run after any change:
#
#   ruby reveal/selftest.rb

# --- minimal shims so the module can be loaded outside Rails -----------------

class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present?
    !blank?
  end
end

class NilClass
  def blank?
    true
  end
end

# A Redis stand-in supporting exactly the commands the guard store uses.
module FakeRedis
  module_function

  def store
    @store ||= {}
  end

  def reset!
    @store = {}
  end

  # Set to false to simulate a Redis that does not honour NX — the condition
  # the guard probe exists to catch.
  def honour_nx=(value)
    @honour_nx = value
  end

  def honour_nx
    @honour_nx.nil? ? true : @honour_nx
  end

  def call(*args)
    cmd = args[0].to_s.upcase

    case cmd
    when 'SET'
      key, value = args[1], args[2]
      nx = args.map { |a| a.to_s.upcase }.include?('NX')
      return nil if nx && honour_nx && store.key?(key)

      store[key] = value.to_s
      'OK'
    when 'GETDEL' then store.delete(args[1])
    when 'GET'    then store[args[1]]
    when 'DEL'    then store.delete(args[1]) ? 1 : 0
    when 'INCR'   then store[args[1]] = (store.fetch(args[1], 0).to_i + 1)
    when 'EXPIRE' then 1
    else raise "unexpected redis command #{cmd}"
    end
  end
end

module Sidekiq
  module_function

  def redis
    yield FakeRedis
  end
end

module FakeLogger
  module_function

  def error(_m); end
  def warn(_m); end
  def info(_m); end
end

module Rails
  module_function

  def logger
    FakeLogger
  end
end

require 'securerandom'
require_relative 'icodos_reveal'

FAILS = []

def check(label, ok, detail = '')
  puts format('  %-46s %s  %s', label, ok ? 'ok  ' : 'FAIL', detail)
  FAILS << label unless ok
end

NOW = 1_786_800_000

# --- auth_time freshness -----------------------------------------------------
#
# This is what stands between "Microsoft says this person authenticated just
# now" and "this browser has a cookie". prompt=login is only a request; the
# claim is the evidence, so the boundaries matter.

puts "\nauth_time freshness (max #{IcodosReveal::AUTH_TIME_MAX_AGE}s)\n\n"

check('just now',                IcodosReveal.fresh_auth?(NOW, now: NOW))
check('1s inside the window',    IcodosReveal.fresh_auth?(NOW - (IcodosReveal::AUTH_TIME_MAX_AGE - 1), now: NOW))
check('exactly at the boundary', IcodosReveal.fresh_auth?(NOW - IcodosReveal::AUTH_TIME_MAX_AGE, now: NOW))
check('1s stale -> rejected',    !IcodosReveal.fresh_auth?(NOW - (IcodosReveal::AUTH_TIME_MAX_AGE + 1), now: NOW))
check('an hour stale -> rejected', !IcodosReveal.fresh_auth?(NOW - 3600, now: NOW))
check('absent -> rejected',      !IcodosReveal.fresh_auth?(nil, now: NOW))
check('empty -> rejected',       !IcodosReveal.fresh_auth?('', now: NOW))
check('zero -> rejected',        !IcodosReveal.fresh_auth?(0, now: NOW))
check('negative -> rejected',    !IcodosReveal.fresh_auth?(-1, now: NOW))
check('slight future tolerated', IcodosReveal.fresh_auth?(NOW + 30, now: NOW))
check('far future -> rejected',  !IcodosReveal.fresh_auth?(NOW + 3600, now: NOW))

# --- intent binding ----------------------------------------------------------

puts "\nintent binding\n\n"

intent = IcodosReveal.build_intent(7, now: NOW)

check('matching user, unexpired',   IcodosReveal.intent_valid?(intent, 7, now: NOW))
check('different user -> rejected', !IcodosReveal.intent_valid?(intent, 8, now: NOW))
check('expired -> rejected',        !IcodosReveal.intent_valid?(intent, 7, now: NOW + IcodosReveal::INTENT_TTL + 1))
check('nil intent -> rejected',     !IcodosReveal.intent_valid?(nil, 7, now: NOW))
check('nil user -> rejected',       !IcodosReveal.intent_valid?(intent, nil, now: NOW))
check('string keys survive',        IcodosReveal.intent_valid?({ 'user_id' => 7, 'exp' => NOW + 60 }, 7, now: NOW))

# --- grants ------------------------------------------------------------------

puts "\ngrants\n\n"

FakeRedis.reset!

jti = IcodosReveal.mint_grant!(42)
check('minted', jti.is_a?(String) && jti.length > 20)
check('consumed once by the right user', IcodosReveal.consume_grant!(jti, 42))
check('second use -> rejected',          !IcodosReveal.consume_grant!(jti, 42))

FakeRedis.reset!
jti2 = IcodosReveal.mint_grant!(42)
check('wrong user -> rejected',          !IcodosReveal.consume_grant!(jti2, 43))
check('burned even on mismatch',         !IcodosReveal.consume_grant!(jti2, 42),
      'a mismatched attempt must not leave the grant usable')

check('unknown jti -> rejected',         !IcodosReveal.consume_grant!('made-up', 42))
check('blank jti -> rejected',           !IcodosReveal.consume_grant!('', 42))
check('nil user -> rejected',            !IcodosReveal.consume_grant!(jti2, nil))

FakeRedis.reset!
check('grants are unique', IcodosReveal.mint_grant!(1) != IcodosReveal.mint_grant!(1))

# --- rate limiting -----------------------------------------------------------

puts "\nrate limiting (#{IcodosReveal::RATE_LIMIT}/min)\n\n"

FakeRedis.reset!
results = (1..(IcodosReveal::RATE_LIMIT + 2)).map { IcodosReveal.rate_limited?(99) }

check('first attempts allowed', results.first(IcodosReveal::RATE_LIMIT).none?)
check('over the limit blocked', results.last(2).all?)

FakeRedis.reset!
check('a different user is unaffected', !IcodosReveal.rate_limited?(100))

# --- guard store ------------------------------------------------------------
#
# The store must PROVE it can enforce single use before the feature is offered.
# Rails.cache on this instance is MemoryStore — per-process and lost on restart —
# which is why grants live in Redis instead.

puts "\nguard store\n\n"

FakeRedis.reset!
FakeRedis.honour_nx = true
IcodosReveal.instance_variable_set(:@guard_store_ready, nil)
check('accepts a Redis that enforces NX', IcodosReveal.guard_store_ready?)

FakeRedis.reset!
FakeRedis.honour_nx = false
IcodosReveal.instance_variable_set(:@guard_store_ready, nil)
check('refuses a store that ignores NX', !IcodosReveal.guard_store_ready?,
      'a replayable grant is weaker than the password it replaces')

FakeRedis.honour_nx = true
IcodosReveal.instance_variable_set(:@guard_store_ready, nil)

# REGRESSION: a transient Redis failure must NOT be cached. Redis starts inside
# the app container and is often not listening when Rails finishes booting; an
# earlier version memoised the failure and disabled the feature for the whole
# life of that web process while a fresh console reported it working.
module BrokenRedis
  def self.call(*_args)
    raise 'connection refused'
  end
end

module Sidekiq
  def self.redis
    yield(@override || FakeRedis)
  end

  def self.override_redis(r)
    @override = r
  end
end

IcodosReveal.instance_variable_set(:@guard_store_ready, nil)
Sidekiq.override_redis(BrokenRedis)
check('unreachable Redis -> not ready', !IcodosReveal.guard_store_ready?)

Sidekiq.override_redis(nil)
FakeRedis.reset!
check('recovers once Redis returns', IcodosReveal.guard_store_ready?,
      'a transient boot-time failure must not disable the feature until restart')

puts
if FAILS.empty?
  puts 'reveal selftest: all checks passed'
  exit 0
else
  puts "reveal selftest: #{FAILS.size} FAILURE(S) — #{FAILS.join(', ')}"
  exit 1
end
