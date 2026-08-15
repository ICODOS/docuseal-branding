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

module FakeCache
  module_function

  def store
    @store ||= {}
  end

  def reset!
    @store = {}
  end

  def write(key, value, opts = {})
    return false if opts[:unless_exist] && store.key?(key)

    store[key] = value
    true
  end

  def read(key)
    store[key]
  end

  def delete(key)
    store.delete(key)
  end

  def increment(key, amount = 1)
    store[key] = store.fetch(key, 0) + amount
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

  def cache
    FakeCache
  end

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

FakeCache.reset!

jti = IcodosReveal.mint_grant!(42)
check('minted', jti.is_a?(String) && jti.length > 20)
check('consumed once by the right user', IcodosReveal.consume_grant!(jti, 42))
check('second use -> rejected',          !IcodosReveal.consume_grant!(jti, 42))

FakeCache.reset!
jti2 = IcodosReveal.mint_grant!(42)
check('wrong user -> rejected',          !IcodosReveal.consume_grant!(jti2, 43))
check('burned even on mismatch',         !IcodosReveal.consume_grant!(jti2, 42),
      'a mismatched attempt must not leave the grant usable')

check('unknown jti -> rejected',         !IcodosReveal.consume_grant!('made-up', 42))
check('blank jti -> rejected',           !IcodosReveal.consume_grant!('', 42))
check('nil user -> rejected',            !IcodosReveal.consume_grant!(jti2, nil))

FakeCache.reset!
check('grants are unique', IcodosReveal.mint_grant!(1) != IcodosReveal.mint_grant!(1))

# --- rate limiting -----------------------------------------------------------

puts "\nrate limiting (#{IcodosReveal::RATE_LIMIT}/min)\n\n"

FakeCache.reset!
results = (1..(IcodosReveal::RATE_LIMIT + 2)).map { IcodosReveal.rate_limited?(99) }

check('first attempts allowed', results.first(IcodosReveal::RATE_LIMIT).none?)
check('over the limit blocked', results.last(2).all?)

FakeCache.reset!
check('a different user is unaffected', !IcodosReveal.rate_limited?(100))

# --- single-use enforceability ----------------------------------------------

puts "\ncache guard\n\n"

FakeCache.reset!
IcodosReveal.instance_variable_set(:@single_use_enforceable, nil)
check('honours unless_exist', IcodosReveal.single_use_enforceable?)

module BrokenCache
  def self.write(k, v, _o = {}); FakeCache.store[k] = v; true; end   # ignores unless_exist
  def self.read(k); FakeCache.store[k]; end
  def self.delete(k); FakeCache.store.delete(k); end
end

module Rails
  def self.cache
    @override || FakeCache
  end

  def self.override_cache(c)
    @override = c
  end
end

Rails.override_cache(BrokenCache)
IcodosReveal.instance_variable_set(:@single_use_enforceable, nil)
check('refuses a cache that ignores unless_exist', !IcodosReveal.single_use_enforceable?,
      'a replayable grant is weaker than the password it replaces')
Rails.override_cache(nil)

puts
if FAILS.empty?
  puts 'reveal selftest: all checks passed'
  exit 0
else
  puts "reveal selftest: #{FAILS.size} FAILURE(S) — #{FAILS.join(', ')}"
  exit 1
end
