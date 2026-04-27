#!/usr/bin/env bash
set -euo pipefail

# Creates Cloudflare Tunnel + DNS records for alexkydanov.com office origin.
# Requires token scopes:
# - Account Cloudflare Tunnel:Edit
# - Zone DNS:Edit (alexkydanov.com)
#
# Usage:
#   CLOUDFLARE_API_TOKEN=... ./scripts/cloudflare/setup_alexkydanov_tunnel.sh

API_BASE="https://api.cloudflare.com/client/v4"
ZONE_NAME="alexkydanov.com"
TUNNEL_NAME="alexkydanov-office-origin"
BACKUP_DIR="ops/cloudflare/alexkydanov.com"
BACKUP_FILE="$BACKUP_DIR/dns-backup-before-tunnel.json"
OUTPUT_FILE="$BACKUP_DIR/tunnel-bootstrap-output.json"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN is required." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

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

zone_response="$(api GET "/zones?name=$ZONE_NAME")"
zone_id="$(jq -r '.result[0].id // empty' <<<"$zone_response")"
account_id="$(jq -r '.result[0].account.id // empty' <<<"$zone_response")"

if [[ -z "$zone_id" || -z "$account_id" ]]; then
  echo "ERROR: Could not resolve zone/account for $ZONE_NAME" >&2
  echo "$zone_response" | jq '.' >&2
  exit 1
fi

# Backup current DNS before any mutation.
api GET "/zones/$zone_id/dns_records?per_page=100" | jq '.' > "$BACKUP_FILE"

echo "Backed up current DNS records to $BACKUP_FILE"

existing_tunnel_id="$(api GET "/accounts/$account_id/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.result[0].id // empty')"
if [[ -n "$existing_tunnel_id" ]]; then
  tunnel_id="$existing_tunnel_id"
  echo "Using existing tunnel: $tunnel_id"
else
  tunnel_secret="$(openssl rand -base64 32)"
  create_tunnel_body="$(jq -nc --arg name "$TUNNEL_NAME" --arg secret "$tunnel_secret" '{name:$name, tunnel_secret:$secret}')"
  create_tunnel_response="$(api POST "/accounts/$account_id/cfd_tunnel" "$create_tunnel_body")"

  success="$(jq -r '.success // false' <<<"$create_tunnel_response")"
  if [[ "$success" != "true" ]]; then
    echo "ERROR: Tunnel creation failed. Response:" >&2
    echo "$create_tunnel_response" | jq '.' >&2
    exit 1
  fi

  tunnel_id="$(jq -r '.result.id' <<<"$create_tunnel_response")"
  echo "Created tunnel: $tunnel_id"
fi

tunnel_target="$tunnel_id.cfargotunnel.com"

# Remove old apex A records pointing at GitHub Pages before creating CNAME.
for record_id in $(jq -r '.result[] | select(.type=="A" and .name=="alexkydanov.com") | .id' "$BACKUP_FILE"); do
  api DELETE "/zones/$zone_id/dns_records/$record_id" >/dev/null
  echo "Deleted legacy apex A record: $record_id"
done

upsert_cname() {
  local fqdn="$1"
  local record_id
  record_id="$(api GET "/zones/$zone_id/dns_records?type=CNAME&name=$fqdn" | jq -r '.result[0].id // empty')"

  payload="$(jq -nc --arg type "CNAME" --arg name "$fqdn" --arg content "$tunnel_target" '{type:$type,name:$name,content:$content,proxied:true,ttl:1,comment:"Managed by JUS-67 Cloudflare Tunnel cutover"}')"

  if [[ -n "$record_id" ]]; then
    api PUT "/zones/$zone_id/dns_records/$record_id" "$payload" >/dev/null
    echo "Updated CNAME $fqdn -> $tunnel_target"
  else
    api POST "/zones/$zone_id/dns_records" "$payload" >/dev/null
    echo "Created CNAME $fqdn -> $tunnel_target"
  fi
}

upsert_cname "alexkydanov.com"
upsert_cname "www.alexkydanov.com"

jq -n \
  --arg zone_id "$zone_id" \
  --arg account_id "$account_id" \
  --arg tunnel_name "$TUNNEL_NAME" \
  --arg tunnel_id "$tunnel_id" \
  --arg tunnel_target "$tunnel_target" \
  --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{zone_id:$zone_id,account_id:$account_id,tunnel_name:$tunnel_name,tunnel_id:$tunnel_id,tunnel_target:$tunnel_target,generated_at:$generated_at}' \
  > "$OUTPUT_FILE"

echo "Wrote tunnel metadata to $OUTPUT_FILE"
echo "Next: install cloudflared on web-projects and configure ingress per ops/cloudflare/alexkydanov.com/cloudflared-config.yml"
