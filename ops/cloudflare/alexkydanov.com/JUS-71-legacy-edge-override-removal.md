# JUS-71 - Remove legacy JUS-49 edge override on alexkydanov.com

## Scope
Remove the legacy Cloudflare edge override left from JUS-49 so all live traffic resolves to the current tunnel-backed origin.

## Current state (2026-04-27)
- DNS apex and `www` are already pointed to tunnel target `63431f66-27b2-4210-9263-9b06720dcced.cfargotunnel.com` (proxied).
- Live checks:
  - `https://alexkydanov.com` returns `200`.
  - `https://www.alexkydanov.com` returns `301` to apex.
- Remaining risk: an old edge rule can still override origin behavior for selected paths/hosts.

## Detection + removal script
Use:
- `scripts/cloudflare/remove_alexkydanov_legacy_edge_override.sh`

Behavior:
- Scans key zone phase entrypoint rulesets for rules matching `LEGACY_MATCH` (defaults to `JUS-49`).
- Dry-run by default.
- Deletes matched rules only with `APPLY=1`.

Examples:
```bash
# Dry-run discovery
CLOUDFLARE_API_TOKEN=... ./scripts/cloudflare/remove_alexkydanov_legacy_edge_override.sh

# Remove matched rules
APPLY=1 CLOUDFLARE_API_TOKEN=... ./scripts/cloudflare/remove_alexkydanov_legacy_edge_override.sh
```

## Required token scopes
The API token must include ruleset permissions in addition to DNS permissions:
- `Zone Rulesets:Read`
- `Zone Rulesets:Edit` (for delete)

Without these scopes the script cannot confirm or remove the edge override and exits with a clear error.

## Verification after removal
Run:
```bash
curl -I https://alexkydanov.com
curl -I https://www.alexkydanov.com
```

Expected:
- Apex responds from current origin path (`200` or app success response).
- `www` keeps canonical redirect to apex (`301`).
- No legacy JUS-49 rule remains in scanned ruleset phases.
