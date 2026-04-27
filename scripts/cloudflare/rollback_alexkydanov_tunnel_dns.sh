#!/usr/bin/env bash
set -euo pipefail

# Restores DNS state from backup created by setup_alexkydanov_tunnel.sh.
# Usage:
#   CLOUDFLARE_API_TOKEN=... ./scripts/cloudflare/rollback_alexkydanov_tunnel_dns.sh

API_BASE="https://api.cloudflare.com/client/v4"
ZONE_NAME="alexkydanov.com"
BACKUP_FILE="ops/cloudflare/alexkydanov.com/dns-backup-before-tunnel.json"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN is required." >&2
  exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "ERROR: backup file not found at $BACKUP_FILE" >&2
  exit 1
fi

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$API_BASE$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -sS -X "$method" "$API_BASE$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

zone_id="$(api GET "/zones?name=$ZONE_NAME" | jq -r '.result[0].id // empty')"
if [[ -z "$zone_id" ]]; then
  echo "ERROR: could not resolve zone id for $ZONE_NAME" >&2
  exit 1
fi

# Delete all apex/www records first to avoid CNAME/A conflicts.
for record_id in $(api GET "/zones/$zone_id/dns_records?per_page=100" | jq -r '.result[] | select(.name=="alexkydanov.com" or .name=="www.alexkydanov.com") | .id'); do
  api DELETE "/zones/$zone_id/dns_records/$record_id" >/dev/null
  echo "Deleted current record $record_id"
done

jq -c '.result[] | select(.name=="alexkydanov.com" or .name=="www.alexkydanov.com")' "$BACKUP_FILE" | while read -r rec; do
  payload="$(jq -nc --arg type "$(jq -r '.type' <<<"$rec")" \
    --arg name "$(jq -r '.name' <<<"$rec")" \
    --arg content "$(jq -r '.content' <<<"$rec")" \
    --argjson proxied "$(jq '.proxied' <<<"$rec")" \
    --argjson ttl "$(jq '.ttl' <<<"$rec")" \
    '{type:$type,name:$name,content:$content,proxied:$proxied,ttl:$ttl}')"

  api POST "/zones/$zone_id/dns_records" "$payload" >/dev/null
  echo "Restored $(jq -r '.type + " " + .name + " -> " + .content' <<<"$rec")"
done

echo "Rollback complete. DNS restored from $BACKUP_FILE"
