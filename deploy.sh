#!/usr/bin/env bash
#
# Refresh the ICODOS DocuSeal overlay on the server and restart the stack.
#
# Run it from /opt/docuseal on sign.icodos.com:
#   curl -fsSL https://raw.githubusercontent.com/ICODOS/docuseal-branding/main/deploy.sh | bash
# or, if the repo is already checked out somewhere, just run this file.
#
# What it does, in order:
#   1. refuses to run outside a directory that has .env and secrets/
#   2. dumps the database, because DocuSeal runs migrations on boot and they
#      are not reversed by putting the old image tag back
#   3. copies EVERY overlay directory, not just branding/
#   4. checks that every bind-mount source in docker-compose.yml exists and is
#      a file; Docker silently creates a DIRECTORY in place of a missing source
#      and the dependent feature then disables itself with no error anywhere
#   5. brings the stack up, recreating the app container even when only overlay
#      files changed, and prints the boot diagnostics
#   6. proves the running container sees the overlay files just copied, by
#      comparing checksums on the host and inside the container
#
# Escape hatches:
#   SKIP_DB_BACKUP=1   skip step 2
#   REPO_REF=some-branch   deploy something other than main
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

set -euo pipefail

REPO_URL="https://github.com/ICODOS/docuseal-branding.git"
REPO_REF="${REPO_REF:-main}"
OVERLAY_DIRS=(branding sso mcp contracts reveal reminders)
BACKUP_DIR="${BACKUP_DIR:-/var/backups/docuseal}"

die() { printf '\n[deploy] FAILED: %s\n' "$1" >&2; exit 1; }
say() { printf '[deploy] %s\n' "$1"; }

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

  [ "${#srcs[@]}" -gt 0 ] || die "found no overlay bind mounts in docker-compose.yml to verify."

  host_sums="$(sha256sum "${srcs[@]}" | awk '{print $1}')" \
    || die "could not checksum the overlay files on the host."
  live_sums="$(docker compose exec -T app sha256sum "${dsts[@]}" </dev/null | awk '{print $1}')" \
    || die "could not read the overlay files inside the app container. Is it running? Check 'docker compose ps'."

  while IFS= read -r h && IFS= read -r l <&3; do
    if [ "$h" != "$l" ]; then
      printf '  STALE     %s\n' "${srcs[$i]}"
      stale=$((stale + 1))
    fi
    i=$((i + 1))
  done < <(printf '%s\n' "$host_sums") 3< <(printf '%s\n' "$live_sums")

  [ "$i" = "${#srcs[@]}" ] || die "compared $i of ${#srcs[@]} overlay files; the container returned a short list."

  [ "$stale" = "0" ] || die "the running app container does not see $stale of the overlay files just deployed
       (listed above). Run 'docker compose up -d --no-deps --force-recreate app'
       and run this script again to check."

  say "the running app container sees all ${#srcs[@]} overlay files as deployed."
}

main() {
  # --- 1. where are we -------------------------------------------------------
  [ -f .env ] || die "no .env in $(pwd). Run this from /opt/docuseal."
  [ -d secrets ] || die "no secrets/ in $(pwd). Run this from /opt/docuseal."
  command -v docker >/dev/null || die "docker is not on PATH."

  # --- 2. database dump ------------------------------------------------------
  if [ "${SKIP_DB_BACKUP:-0}" = "1" ]; then
    say "skipping the database dump (SKIP_DB_BACKUP=1)."
  else
    mkdir -p "$BACKUP_DIR"
    dump="$BACKUP_DIR/docuseal-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
    say "dumping the database to $dump"
    docker compose exec -T postgres pg_dump -U postgres docuseal </dev/null | gzip > "$dump" \
      || die "pg_dump failed. Migrations run on boot and are not reversible; fix this before deploying."
    [ -s "$dump" ] || die "the dump is empty: $dump"
    say "dump is $(du -h "$dump" | cut -f1)."
  fi

  # --- 3. refresh the overlay ------------------------------------------------
  # Global, not local: the EXIT trap runs after main has returned.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  say "cloning $REPO_URL ($REPO_REF)"
  git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$tmp/repo" </dev/null \
    || die "clone failed."

  for d in "${OVERLAY_DIRS[@]}"; do
    [ -d "$tmp/repo/$d" ] || die "the repo has no $d/ directory. Check REPO_REF."
  done

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

  [ "$missing" = "0" ] || die "the bind-mount sources listed above are missing or are directories.
       Nothing was restarted. Generate the missing secrets (see README,
       'The signing key' and the Phase E certificate block), remove any stray
       directory under secrets/, then run this again."
  say "all bind-mount sources are present and are files."

  # --- 5. up -----------------------------------------------------------------
  image="$(grep -oE 'image: docuseal/docuseal:[^[:space:]]+' docker-compose.yml | head -1)"
  say "starting the stack with ${image#image: }"

  before="$(docker compose ps -q app </dev/null || true)"
  docker compose up -d </dev/null
  after="$(docker compose ps -q app </dev/null || true)"

  # Same container id means compose saw no configuration change and left the
  # app running on the previous overlay files. See the header.
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    say "the app container was not recreated (its configuration did not change), so it is still running the previous overlay files; recreating it"
    docker compose up -d --no-deps --force-recreate app </dev/null
  fi

  say "waiting 45s for migrations and boot, then printing the ICODOS diagnostics"
  sleep 45
  docker compose logs app --since 5m </dev/null 2>&1 \
    | grep -E '\[sso\]|\[mcp-oauth\]|\[icodos-contracts\]|\[icodos-reveal\]|\[icodos-reminders\]|Migrating|FATAL|Error' \
    || say "no ICODOS diagnostic lines found yet; check 'docker compose logs app' by hand."

  # --- 6. prove it ----------------------------------------------------------
  verify_overlay_live

  say "done. Now run the acceptance checks in the version bump runbook."
}

# Keep this the last line. Nothing may run before bash has read the whole file.
main "$@"
