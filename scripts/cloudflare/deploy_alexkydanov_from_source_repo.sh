#!/usr/bin/env bash
set -euo pipefail

# Source-agnostic deploy for alexkydanov.com on web-projects.
# Clones/builds just-development/alexkydanov-com and publishes dist to release dir.
#
# Run this ON web-projects host.
#
# Usage:
#   ./scripts/cloudflare/deploy_alexkydanov_from_source_repo.sh
#   SOURCE_REPO=https://github.com/just-development/alexkydanov-com.git ./scripts/cloudflare/deploy_alexkydanov_from_source_repo.sh

SITE_ROOT="${SITE_ROOT:-/srv/web-projects/sites/alexkydanov.com}"
RELEASES_DIR="$SITE_ROOT/releases"
CURRENT_LINK="$SITE_ROOT/current"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/just-development/alexkydanov-com.git}"
WORKDIR_BASE="${WORKDIR_BASE:-/tmp/alexkydanov-com-deploy}"
RELEASE_ID="${RELEASE_ID:-$(date -u +%Y%m%d%H%M%S)}"
NEW_RELEASE="$RELEASES_DIR/$RELEASE_ID"
PREV_TARGET=""

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing dependency: $1" >&2; exit 1; }
}

for bin in git npm rsync curl; do
  need "$bin"
done

if [[ ! -d "$SITE_ROOT" ]]; then
  echo "ERROR: SITE_ROOT not found: $SITE_ROOT" >&2
  exit 1
fi

if [[ -e "$NEW_RELEASE" ]]; then
  echo "ERROR: release already exists: $NEW_RELEASE" >&2
  exit 1
fi

if [[ -e "$CURRENT_LINK" ]]; then
  PREV_TARGET="$(readlink -f "$CURRENT_LINK" || true)"
fi

rm -rf "$WORKDIR_BASE"
git clone --depth 1 "$SOURCE_REPO" "$WORKDIR_BASE"

pushd "$WORKDIR_BASE" >/dev/null
npm ci --include=dev
npm run build
popd >/dev/null

mkdir -p "$NEW_RELEASE"
rsync -a "$WORKDIR_BASE/dist/" "$NEW_RELEASE/"

if rg -n "JUS-49 dry run" "$NEW_RELEASE" >/dev/null 2>&1; then
  echo "ERROR: built payload contains legacy JUS-49 dry-run string" >&2
  exit 1
fi

ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"
echo "Switched current -> $NEW_RELEASE"

check_local() {
  local path="$1"
  local out
  out="$(curl -sS -H 'Host: alexkydanov.com' "http://127.0.0.1$path")"
  if grep -q "JUS-49 dry run" <<<"$out"; then
    echo "ERROR: legacy payload still served at $path" >&2
    exit 1
  fi
  echo "OK local $path"
}

check_local "/"
check_local "/sitemap.xml"
check_local "/robots.txt"

cat <<MSG

Deployment complete.
New release: $NEW_RELEASE
Current target: $(readlink -f "$CURRENT_LINK")

Rollback:
  ln -sfn "${PREV_TARGET}" "$CURRENT_LINK"
MSG
