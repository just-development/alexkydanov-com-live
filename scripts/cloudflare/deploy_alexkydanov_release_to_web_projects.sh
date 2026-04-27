#!/usr/bin/env bash
set -euo pipefail

# Deploys the current repo static site as a new on-host release for alexkydanov.com.
# Run this ON web-projects host.
#
# Usage:
#   ./scripts/cloudflare/deploy_alexkydanov_release_to_web_projects.sh
#   RELEASE_ID=20260427T142500Z ./scripts/cloudflare/deploy_alexkydanov_release_to_web_projects.sh

SITE_ROOT="${SITE_ROOT:-/srv/web-projects/sites/alexkydanov.com}"
RELEASES_DIR="$SITE_ROOT/releases"
CURRENT_LINK="$SITE_ROOT/current"
RELEASE_ID="${RELEASE_ID:-$(date -u +%Y%m%d%H%M%S)}"
NEW_RELEASE="$RELEASES_DIR/$RELEASE_ID"
PREV_TARGET=""

cleanup_on_error() {
  if [[ -n "${NEW_RELEASE:-}" && -d "$NEW_RELEASE" ]]; then
    rm -rf "$NEW_RELEASE"
  fi
}

if [[ ! -d "$SITE_ROOT" ]]; then
  echo "ERROR: SITE_ROOT not found: $SITE_ROOT" >&2
  exit 1
fi

for dep in rsync curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: missing dependency $dep" >&2; exit 1; }
done

if [[ -e "$CURRENT_LINK" ]]; then
  PREV_TARGET="$(readlink -f "$CURRENT_LINK" || true)"
fi

if [[ -e "$NEW_RELEASE" ]]; then
  echo "ERROR: release already exists: $NEW_RELEASE" >&2
  exit 1
fi

trap cleanup_on_error ERR

mkdir -p "$NEW_RELEASE"

rsync -a \
  --exclude '.git' \
  --exclude 'ops' \
  --exclude 'scripts' \
  --exclude '.agents' \
  ./ "$NEW_RELEASE/"

if rg -n "JUS-49 dry run" "$NEW_RELEASE" >/dev/null 2>&1; then
  echo "ERROR: release payload still contains legacy JUS-49 dry-run content" >&2
  exit 1
fi

ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"

echo "Switched current -> $NEW_RELEASE"

check_local() {
  local path="$1"
  local out
  out="$(curl -sS -H 'Host: alexkydanov.com' "http://127.0.0.1$path")"
  if grep -q "JUS-49 dry run" <<<"$out"; then
    echo "ERROR: legacy JUS-49 content still served at $path" >&2
    exit 1
  fi
  echo "OK local $path"
}

check_local "/"
check_local "/sitemap.xml"
check_local "/robots.txt"

if [[ -n "$PREV_TARGET" ]]; then
  cat <<MSG

Deployment complete.
Rollback:
  ln -sfn "$PREV_TARGET" "$CURRENT_LINK"
MSG
else
  echo "Deployment complete. No previous current target recorded."
fi
