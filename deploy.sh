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
#   5. brings the stack up and prints the boot diagnostics
#
# Escape hatches:
#   SKIP_DB_BACKUP=1   skip step 2
#   REPO_REF=some-branch   deploy something other than main

set -euo pipefail

REPO_URL="https://github.com/ICODOS/docuseal-branding.git"
REPO_REF="${REPO_REF:-main}"
OVERLAY_DIRS=(branding sso mcp contracts reveal reminders)
BACKUP_DIR="${BACKUP_DIR:-/var/backups/docuseal}"

die() { printf '\n[deploy] FAILED: %s\n' "$1" >&2; exit 1; }
say() { printf '[deploy] %s\n' "$1"; }

# --- 1. where are we ---------------------------------------------------------
[ -f .env ] || die "no .env in $(pwd). Run this from /opt/docuseal."
[ -d secrets ] || die "no secrets/ in $(pwd). Run this from /opt/docuseal."
command -v docker >/dev/null || die "docker is not on PATH."

# --- 2. database dump --------------------------------------------------------
if [ "${SKIP_DB_BACKUP:-0}" = "1" ]; then
  say "skipping the database dump (SKIP_DB_BACKUP=1)."
else
  mkdir -p "$BACKUP_DIR"
  dump="$BACKUP_DIR/docuseal-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
  say "dumping the database to $dump"
  docker compose exec -T postgres pg_dump -U postgres docuseal | gzip > "$dump" \
    || die "pg_dump failed. Migrations run on boot and are not reversible; fix this before deploying."
  [ -s "$dump" ] || die "the dump is empty: $dump"
  say "dump is $(du -h "$dump" | cut -f1)."
fi

# --- 3. refresh the overlay --------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
say "cloning $REPO_URL ($REPO_REF)"
git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$tmp/repo" \
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

# --- 4. preflight: every bind-mount source must be an existing FILE -----------
# secrets/ is gitignored and lives only here, so a missing key shows up at this
# step rather than as a feature that quietly stopped working.
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

# --- 5. up -------------------------------------------------------------------
image="$(grep -oE 'image: docuseal/docuseal:[^[:space:]]+' docker-compose.yml | head -1)"
say "starting the stack with ${image#image: }"
docker compose up -d

say "waiting 45s for migrations and boot, then printing the ICODOS diagnostics"
sleep 45
docker compose logs app --since 5m 2>&1 \
  | grep -E '\[sso\]|\[mcp-oauth\]|\[icodos-contracts\]|\[icodos-reveal\]|\[icodos-reminders\]|Migrating|FATAL|Error' \
  || say "no ICODOS diagnostic lines found yet; check 'docker compose logs app' by hand."

say "done. Now run the acceptance checks in the version bump runbook."
