#!/usr/bin/env bash
#
# Refresh the ICODOS DocuSeal overlay on the server and restart the stack.
#
# Run it from /opt/docuseal on sign.icodos.com, naming the exact commit:
#   SHA=<full 40-character commit id>
#   curl -fsSL "https://raw.githubusercontent.com/ICODOS/docuseal-branding/$SHA/deploy.sh" | DEPLOY_SHA="$SHA" bash
# or, if the repo is already checked out somewhere, run this file with
# DEPLOY_SHA set.
#
# WHY A COMMIT ID AND NOT A BRANCH
# This script runs as root and what it installs is mounted into the app, so
# whoever decides which code it fetches decides what runs on the server. A
# branch name is a pointer that anyone with push access can move, between the
# moment a change was read and the moment it is deployed. A commit id cannot be
# moved: it names one tree, the one that was reviewed. The same goes for the
# URL above. Fetched from a branch it would be whatever the branch holds at
# that second; fetched from a commit id it is the file as reviewed.
# The deployed id is written to .deployed_sha, so "what is running" has an
# answer that does not depend on memory.
#
# What it does, in order:
#   1. refuses to run without DEPLOY_SHA, or outside a directory that has .env
#      and secrets/
#   2. dumps the database, because DocuSeal runs migrations on boot and they
#      are not reversed by putting the old image tag back
#   3. copies EVERY overlay directory, not just branding/
#   4. checks that every bind-mount source in docker-compose.yml exists and is
#      a file; Docker silently creates a DIRECTORY in place of a missing source
#      and the dependent feature then disables itself with no error anywhere
#   5. brings the stack up, recreating the app container even when only overlay
#      files changed, and waits for the health gate: /up answers inside the
#      container and through the proxy, and the boot log since the container
#      started has the line of every feature and no error marker
#   6. proves the running container sees the overlay files just copied, by
#      comparing checksums on the host and inside the container, and only then
#      records the commit id in .deployed_sha
#
# If step 4, 5 or 6 fails, the overlay and compose file that were in place
# before are put back and the app is recreated on them, without being asked.
# The run still ends with exit 1 and .deployed_sha unchanged. Migrations the
# new version ran are not reversed by that; the dump of step 2 is.
#
# Settings, all optional:
#   SKIP_DB_BACKUP=1      skip step 2
#   BOOT_TIMEOUT=180      seconds the health gate waits
#   HEALTH_URL=<url>      /up through the proxy; default https://$HOST/up from
#                         .env; "none" skips that part
#   DEPLOY_BOOT_LINES     the expected boot lines, extended regular
#                         expressions separated by ";"; default: the four
#                         features this instance runs, see BOOT_LINES below
#   DEPLOY_REPO_URL       fetch from another copy of the repository, for
#                         testing this script against a local one; the commit
#                         id rule applies unchanged
#
# WHY EVERYTHING RUNS INSIDE main()
# Piped into bash, as above, the script IS bash's stdin, and bash reads it one
# command at a time. Any command in it that reads stdin swallows the rest of
# the script. `docker compose exec -T` does, so on 2026-11-20 a deploy stopped
# silently right after the database dump and exited 0, with nothing refreshed
# and nothing restarted. Defining main() first makes bash read the whole file
# before running any of it, and a truncated download becomes a syntax error
# instead of half a deploy. Every docker call also gets </dev/null, so the
# fix does not depend on that one property.
#
# WHY STEP 5 FORCES A RECREATE
# `docker compose up -d` recreates a container only when its compose
# configuration changes. The overlay is bind-mounted file by file, and file
# CONTENTS are not part of that configuration, so a deploy that changes only
# overlay code leaves the app container "Running" on the previous files: step 3
# replaces them with new inodes, and the old ones stay mounted until the
# container is recreated. Rails caches classes in production as well, so
# nothing would pick the change up without a restart either. Step 6 is the
# proof that this worked, rather than a log line that suggests it.
#
# WHY A HEALTH GATE AND NOT A SLEEP
# Until 2026-11-25 step 5 slept 45 seconds, printed the boot lines and left
# reading them to whoever ran it. Every overlay class is eager-loaded, so a
# renamed upstream base class or a syntax error stops Rails from booting, and
# the script still went on to step 6, which compares files, not behaviour.
# The site was then down until someone noticed and deployed the previous id
# by hand. A feature that disables itself at boot (a missing key, a hook that
# did not attach) logs one line and leaves the site up, which is worse,
# because nothing looks wrong. The gate waits for the evidence instead, and
# rolls back when it does not come.

set -euo pipefail

REPO_URL="${DEPLOY_REPO_URL:-https://github.com/ICODOS/docuseal-branding.git}"
DEPLOY_SHA="${DEPLOY_SHA:-}"
OVERLAY_DIRS=(branding sso mcp contracts reveal reminders)
BACKUP_DIR="${BACKUP_DIR:-/var/backups/docuseal}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
# One line per feature, written once at boot by each initializer. "disabled"
# is a valid state for a feature, but not on this instance: a deploy that
# turns one off without meaning to must not count as healthy.
BOOT_LINES="${DEPLOY_BOOT_LINES:-\[sso\] configured=true;\[mcp-oauth\] enabled\.;\[icodos-contracts\] enabled\.;\[icodos-reminders\] enabled,}"
# Logged by the initializers when a patch did not attach, and by Rails or
# Zeitwerk when a class cannot be loaded. Any of them ends the wait at once.
BOOT_ERRORS='NOT attached|could not attach|FATAL|Zeitwerk|NameError|password_strategy=ON'

die() { printf '\n[deploy] FAILED: %s\n' "$1" >&2; exit 1; }
say() { printf '[deploy] %s\n' "$1"; }

health_url() {
  local host
  if [ -n "${HEALTH_URL:-}" ]; then
    printf '%s' "$HEALTH_URL"
    return
  fi
  host="$(sed -n 's/^HOST=//p' .env | tail -1 | tr -d "\"' \r")"
  [ -n "$host" ] && printf 'https://%s/up' "$host"
}

# Step 5. Returns 0 once the app is healthy. On failure it returns 1 with the
# reason in GATE_REASON. Gives up early when the boot log shows an error
# marker or the container restarts, because waiting longer cannot help then.
health_gate() {
  local deadline=$((SECONDS + BOOT_TIMEOUT)) url cid restarts0="" restarts started log missing p code
  local pats=()
  IFS=';' read -ra pats <<< "$BOOT_LINES"
  url="$(health_url)"
  GATE_REASON=""

  while :; do
    GATE_REASON=""
    cid="$(docker compose ps -q app </dev/null 2>/dev/null || true)"
    if [ -z "$cid" ]; then
      GATE_REASON="there is no app container"
    else
      restarts="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)"
      [ -n "$restarts0" ] || restarts0="$restarts"
      if [ "$restarts" != "$restarts0" ]; then
        GATE_REASON="the app container restarted $((restarts - restarts0)) time(s), so Rails is crashing at boot"
        return 1
      fi
      started="$(docker inspect -f '{{.State.StartedAt}}' "$cid")"
      log="$(docker compose logs app --no-color --since "$started" </dev/null 2>&1 || true)"
      if printf '%s\n' "$log" | grep -qE "$BOOT_ERRORS"; then
        GATE_REASON="the boot log shows: $(printf '%s\n' "$log" | grep -E "$BOOT_ERRORS" | head -1 | cut -c1-200)"
        return 1
      fi
      if [ "$(docker inspect -f '{{.State.Running}}' "$cid")" != true ]; then
        GATE_REASON="the app container is not running"
      elif ! docker compose exec -T app wget -q -O /dev/null http://127.0.0.1:3000/up </dev/null >/dev/null 2>&1; then
        GATE_REASON="/up does not answer inside the app container"
      else
        missing=""
        for p in "${pats[@]}"; do
          printf '%s\n' "$log" | grep -qE "$p" || missing="$missing '$p'"
        done
        if [ -n "$missing" ]; then
          GATE_REASON="boot line(s) missing:$missing"
        elif [ -n "$url" ] && [ "$url" != none ]; then
          code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url" || true)"
          [ "$code" = 200 ] || GATE_REASON="$url answers HTTP $code"
        fi
      fi
    fi

    [ -z "$GATE_REASON" ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      GATE_REASON="$GATE_REASON (after ${BOOT_TIMEOUT}s)"
      return 1
    fi
    sleep 5
  done
}

# Puts back the overlay and compose file saved before step 3, recreates the
# app on them and checks that the result is healthy. Always ends the run.
rollback() {
  local why="$1" d
  printf '\n[deploy] %s\n' "$why" >&2
  [ -n "${prev:-}" ] && [ -f "$prev/docker-compose.yml" ] \
    || die "and there is no previous overlay to put back. The stack is in the state shown above."
  say "ROLLING BACK to the overlay that was in place before (${prev_sha:-commit not recorded})"
  for d in "${OVERLAY_DIRS[@]}"; do
    rm -rf "./$d"
    [ -d "$prev/$d" ] && cp -a "$prev/$d" "./$d"
  done
  cp -a "$prev/docker-compose.yml" ./docker-compose.yml
  if [ "${2:-}" = "files-only" ]; then
    die "$why Nothing had been restarted; the previous files are back in place. .deployed_sha is unchanged."
  fi
  docker compose up -d </dev/null || true
  docker compose up -d --no-deps --force-recreate app </dev/null || true
  if health_gate; then
    die "deploy of $DEPLOY_SHA was rolled back: $why
       The previous overlay is running and passed the health gate. .deployed_sha is unchanged.
       Database migrations, if the new version ran any, were not reversed. The dump from before this run: ${dump:-none (SKIP_DB_BACKUP)}"
  fi
  die "deploy of $DEPLOY_SHA failed, AND the rollback did not pass the health gate: $GATE_REASON
       Look now: docker compose logs app --since 10m
       The dump from before this run: ${dump:-none (SKIP_DB_BACKUP)}"
}

# Prints "host_path container_path" for every overlay bind mount, that is every
# mount whose source sits in one of OVERLAY_DIRS. Secrets are left out on
# purpose: their contents are not deployed by this script, and the keys are
# readable only by the container's own user.
overlay_mounts() {
  local src dst
  while IFS=' ' read -r src dst; do
    case " ${OVERLAY_DIRS[*]} " in
      *" ${src%%/*} "*) printf '%s %s\n' "$src" "$dst" ;;
    esac
  done < <(sed -nE 's#^[[:space:]]*-[[:space:]]+\./([^:]+):([^:]+):ro[[:space:]]*$#\1 \2#p' docker-compose.yml)
}

# Step 6. The checksum of every overlay file on the host must match the file
# the running container has mounted at the same place.
verify_overlay_live() {
  local srcs=() dsts=() src dst host_sums live_sums stale=0 i=0 h l

  while IFS=' ' read -r src dst; do
    srcs+=("$src")
    dsts+=("$dst")
  done < <(overlay_mounts)

  VERIFY_REASON=""
  [ "${#srcs[@]}" -gt 0 ] || { VERIFY_REASON="found no overlay bind mounts in docker-compose.yml to verify."; return 1; }

  host_sums="$(sha256sum "${srcs[@]}" | awk '{print $1}')" \
    || { VERIFY_REASON="could not checksum the overlay files on the host."; return 1; }
  live_sums="$(docker compose exec -T app sha256sum "${dsts[@]}" </dev/null | awk '{print $1}')" \
    || { VERIFY_REASON="could not read the overlay files inside the app container."; return 1; }

  while IFS= read -r h && IFS= read -r l <&3; do
    if [ "$h" != "$l" ]; then
      printf '  STALE     %s\n' "${srcs[$i]}"
      stale=$((stale + 1))
    fi
    i=$((i + 1))
  done < <(printf '%s\n' "$host_sums") 3< <(printf '%s\n' "$live_sums")

  [ "$i" = "${#srcs[@]}" ] || { VERIFY_REASON="compared $i of ${#srcs[@]} overlay files; the container returned a short list."; return 1; }

  [ "$stale" = "0" ] || { VERIFY_REASON="the running app container does not see $stale of the overlay files just deployed (listed above)."; return 1; }

  say "the running app container sees all ${#srcs[@]} overlay files as deployed."
}

main() {
  # --- 1. what, and where ----------------------------------------------------
  case "$DEPLOY_SHA" in
    "") die "DEPLOY_SHA is not set. Name the commit to deploy, in full:
       git ls-remote $REPO_URL main
       prints the current one. Read what it contains before deploying it." ;;
  esac
  printf '%s' "$DEPLOY_SHA" | grep -qE '^[0-9a-f]{40}$' \
    || die "DEPLOY_SHA must be a full 40-character commit id, not a branch, a tag or a short id. Got: $DEPLOY_SHA"

  [ -f .env ] || die "no .env in $(pwd). Run this from /opt/docuseal."
  [ -d secrets ] || die "no secrets/ in $(pwd). Run this from /opt/docuseal."
  command -v docker >/dev/null || die "docker is not on PATH."

  # --- 2. database dump ------------------------------------------------------
  if [ "${SKIP_DB_BACKUP:-0}" = "1" ]; then
    say "skipping the database dump (SKIP_DB_BACKUP=1)."
  else
    # The dump holds names, private addresses and password hashes, so it is
    # written for root alone. The umask is set in a subshell on purpose: set
    # for the whole script it would also apply to the overlay files copied in
    # step 3, and the app, which runs as uid 2000, could no longer read them.
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    dump="$BACKUP_DIR/docuseal-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
    say "dumping the database to $dump"
    ( umask 077; docker compose exec -T postgres pg_dump -U postgres docuseal </dev/null | gzip > "$dump" ) \
      || die "pg_dump failed. Migrations run on boot and are not reversible; fix this before deploying."
    [ -s "$dump" ] || die "the dump is empty: $dump"
    say "dump is $(du -h "$dump" | cut -f1)."
  fi

  # --- 3. refresh the overlay ------------------------------------------------
  # Global, not local: the EXIT trap runs after main has returned.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # Fetched by id, not cloned by branch: `git clone --branch` cannot take a
  # commit id, and a branch is exactly what this must not depend on.
  say "fetching $REPO_URL at $DEPLOY_SHA"
  git init --quiet "$tmp/repo" </dev/null || die "git init failed."
  git -C "$tmp/repo" remote add origin "$REPO_URL" </dev/null || die "git remote add failed."
  git -C "$tmp/repo" fetch --quiet --depth 1 origin "$DEPLOY_SHA" </dev/null \
    || die "could not fetch $DEPLOY_SHA. Is it a commit in $REPO_URL, and pushed?"
  git -C "$tmp/repo" -c advice.detachedHead=false checkout --quiet FETCH_HEAD </dev/null \
    || die "checkout failed."

  got="$(git -C "$tmp/repo" rev-parse HEAD </dev/null)"
  [ "$got" = "$DEPLOY_SHA" ] \
    || die "asked for $DEPLOY_SHA but the checkout is $got. Nothing was changed."

  for d in "${OVERLAY_DIRS[@]}"; do
    [ -d "$tmp/repo/$d" ] || die "commit $DEPLOY_SHA has no $d/ directory."
  done

  # What is in place now, so that any failure from here on can put it back.
  prev="$tmp/prev"
  prev_sha="$(cat .deployed_sha 2>/dev/null || true)"
  mkdir -p "$prev"
  for d in "${OVERLAY_DIRS[@]}"; do
    [ -d "./$d" ] && cp -a "./$d" "$prev/$d"
  done
  [ -f docker-compose.yml ] && cp -a docker-compose.yml "$prev/docker-compose.yml"

  for d in "${OVERLAY_DIRS[@]}"; do
    rm -rf "./$d"
    cp -r "$tmp/repo/$d" "./$d"
    say "refreshed $d/"
  done
  cp "$tmp/repo/docker-compose.yml" ./docker-compose.yml
  say "refreshed docker-compose.yml"

  # --- 4. preflight: every bind-mount source must be an existing FILE ---------
  # secrets/ is gitignored and lives only here, so a missing key shows up at
  # this step rather than as a feature that quietly stopped working.
  missing=0
  while IFS= read -r src; do
    if [ ! -e "$src" ]; then
      printf '  MISSING   %s\n' "$src"; missing=1
    elif [ -d "$src" ]; then
      printf '  DIRECTORY %s  (Docker created this in place of a missing file)\n' "$src"; missing=1
    fi
  done < <(grep -oE '^[[:space:]]*-[[:space:]]+\./[^:]+' docker-compose.yml | sed 's/^[[:space:]]*-[[:space:]]*//')

  [ "$missing" = "0" ] || rollback "the bind-mount sources listed above are missing or are directories.
       Generate the missing secrets (see README, 'The signing key' and the
       Phase E certificate block), remove any stray directory under secrets/,
       then run this again." files-only
  say "all bind-mount sources are present and are files."

  # --- 5. up -----------------------------------------------------------------
  image="$(grep -oE 'image: docuseal/docuseal:[^[:space:]]+' docker-compose.yml | head -1)"
  say "starting the stack with ${image#image: }"

  before="$(docker compose ps -q app </dev/null || true)"
  docker compose up -d </dev/null || rollback "docker compose up failed (output above)."
  after="$(docker compose ps -q app </dev/null || true)"

  # Same container id means compose saw no configuration change and left the
  # app running on the previous overlay files. See the header.
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    say "the app container was not recreated (its configuration did not change), so it is still running the previous overlay files; recreating it"
    docker compose up -d --no-deps --force-recreate app </dev/null || rollback "recreating the app container failed (output above)."
  fi

  say "waiting up to ${BOOT_TIMEOUT}s for the health gate: /up inside and through the proxy, and the boot line of every feature"
  health_gate || rollback "the new overlay did not pass the health gate: $GATE_REASON"
  say "health gate passed. Boot lines:"
  docker compose logs app --no-color --since "$(docker inspect -f '{{.State.StartedAt}}' "$(docker compose ps -q app </dev/null)")" </dev/null 2>&1 \
    | grep -E '\[sso\]|\[mcp-oauth\]|\[icodos-contracts\]|\[icodos-reveal\]|\[icodos-reminders\]|Migrating' | cut -c1-240 || true

  # --- 6. prove it ----------------------------------------------------------
  verify_overlay_live || rollback "$VERIFY_REASON"

  # Written last, so the file never names a commit that is not the one running.
  [ -f .deployed_sha ] && cp .deployed_sha .deployed_sha.prev
  printf '%s\n' "$DEPLOY_SHA" > .deployed_sha
  say "recorded $DEPLOY_SHA in .deployed_sha"

  say "done. Now run the acceptance checks in the version bump runbook."
}

# Keep this the last line. Nothing may run before bash has read the whole file.
main "$@"
