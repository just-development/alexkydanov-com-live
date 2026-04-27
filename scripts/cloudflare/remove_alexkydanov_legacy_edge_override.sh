#!/usr/bin/env bash
set -euo pipefail

# Finds and removes legacy Cloudflare edge rules for alexkydanov.com.
# Default behavior is dry-run; set APPLY=1 to delete matched rules.
#
# Usage:
#   CLOUDFLARE_API_TOKEN=... ./scripts/cloudflare/remove_alexkydanov_legacy_edge_override.sh
#   APPLY=1 CLOUDFLARE_API_TOKEN=... ./scripts/cloudflare/remove_alexkydanov_legacy_edge_override.sh
#
# Optional env vars:
#   ZONE_NAME=alexkydanov.com
#   LEGACY_MATCH=JUS-49
#   PHASES="http_request_origin http_request_dynamic_redirect ..."

API_BASE="https://api.cloudflare.com/client/v4"
ZONE_NAME="${ZONE_NAME:-alexkydanov.com}"
LEGACY_MATCH="${LEGACY_MATCH:-JUS-49}"
APPLY="${APPLY:-0}"
PHASES="${PHASES:-http_request_origin http_request_dynamic_redirect http_request_redirect http_request_transform http_request_late_transform http_request_cache_settings http_config_settings}"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN is required." >&2
  exit 1
fi

for dep in curl jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $dep" >&2
    exit 1
  fi
done

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

print_api_error() {
  local resp="$1"
  echo "$resp" | jq -r '.errors[]? | "- [\(.code)] \(.message)"' >&2
}

zone_resp="$(api GET "/zones?name=$ZONE_NAME")"
zone_success="$(jq -r '.success // false' <<<"$zone_resp")"
zone_id="$(jq -r '.result[0].id // empty' <<<"$zone_resp")"

if [[ "$zone_success" != "true" || -z "$zone_id" ]]; then
  echo "ERROR: Could not resolve zone id for $ZONE_NAME" >&2
  print_api_error "$zone_resp"
  exit 1
fi

echo "Zone: $ZONE_NAME ($zone_id)"
echo "Match pattern: $LEGACY_MATCH"

tmp_matches="$(mktemp)"
trap 'rm -f "$tmp_matches"' EXIT

auth_error=0

while IFS= read -r phase; do
  [[ -z "$phase" ]] && continue

  phase_resp="$(api GET "/zones/$zone_id/rulesets/phases/$phase/entrypoint")"
  success="$(jq -r '.success // false' <<<"$phase_resp")"

  if [[ "$success" != "true" ]]; then
    code="$(jq -r '.errors[0].code // empty' <<<"$phase_resp")"

    if [[ "$code" == "10000" ]]; then
      echo "Phase $phase: authentication/permission error." >&2
      print_api_error "$phase_resp"
      auth_error=1
      continue
    fi

    echo "Phase $phase: skipped (no readable entrypoint ruleset)."
    continue
  fi

  ruleset_id="$(jq -r '.result.id' <<<"$phase_resp")"
  ruleset_name="$(jq -r '.result.name // "(unnamed)"' <<<"$phase_resp")"

  matches="$(jq -c --arg needle "$LEGACY_MATCH" --arg phase "$phase" --arg rid "$ruleset_id" --arg rname "$ruleset_name" '
    .result.rules[]?
    | select(
        ((.description // "") | test($needle; "i"))
        or ((.ref // "") | test($needle; "i"))
        or ((.expression // "") | test($needle; "i"))
        or ((.action // "") | test($needle; "i"))
        or ((.action_parameters | tostring) | test($needle; "i"))
      )
    | {
        phase: $phase,
        ruleset_id: $rid,
        ruleset_name: $rname,
        rule_id: .id,
        ref: (.ref // ""),
        description: (.description // ""),
        action: (.action // ""),
        expression: (.expression // "")
      }
  ' <<<"$phase_resp")"

  if [[ -z "$matches" ]]; then
    echo "Phase $phase: no matching rules."
    continue
  fi

  echo "Phase $phase: found matching rules."
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" >>"$tmp_matches"
  done <<<"$matches"
done < <(tr ' ' '\n' <<<"$PHASES")

if [[ "$auth_error" -eq 1 && ! -s "$tmp_matches" ]]; then
  cat >&2 <<'MSG'
ERROR: Token cannot read rulesets, so JUS-49 override cannot be confirmed/removed.
Required token scopes usually include:
- Zone Rulesets:Read
- Zone Rulesets:Edit (for APPLY=1 deletion)
MSG
  exit 2
fi

if [[ ! -s "$tmp_matches" ]]; then
  echo "No rules matched '$LEGACY_MATCH'."
  exit 0
fi

echo
if [[ "$APPLY" != "1" ]]; then
  echo "Dry run only. Matching rules:"
else
  echo "APPLY=1 set. Deleting matching rules:"
fi

jq -s '.' "$tmp_matches" | jq -r '.[] | "- phase=\(.phase) ruleset=\(.ruleset_id) rule=\(.rule_id) ref=\(.ref) desc=\(.description)"'

if [[ "$APPLY" != "1" ]]; then
  echo
  echo "Set APPLY=1 to delete these rules."
  exit 0
fi

while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  phase="$(jq -r '.phase' <<<"$match")"
  ruleset_id="$(jq -r '.ruleset_id' <<<"$match")"
  rule_id="$(jq -r '.rule_id' <<<"$match")"

  del_resp="$(api DELETE "/zones/$zone_id/rulesets/$ruleset_id/rules/$rule_id")"
  del_success="$(jq -r '.success // false' <<<"$del_resp")"

  if [[ "$del_success" != "true" ]]; then
    echo "ERROR: Failed to delete rule $rule_id in phase $phase" >&2
    print_api_error "$del_resp"
    exit 1
  fi

  echo "Deleted rule $rule_id from phase $phase"
done <"$tmp_matches"

echo "Done."
