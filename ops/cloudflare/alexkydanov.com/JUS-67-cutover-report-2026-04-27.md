# JUS-67 Cutover Report (2026-04-27 UTC)

## Executed outcome
- Cloudflare Tunnel created: `alexkydanov-office-origin`
- Tunnel ID: `63431f66-27b2-4210-9263-9b06720dcced`
- Tunnel status: `healthy`
- Active cloudflared connections: `4`

## Final DNS/routing records
- `CNAME alexkydanov.com -> 63431f66-27b2-4210-9263-9b06720dcced.cfargotunnel.com` (proxied)
- `CNAME www.alexkydanov.com -> 63431f66-27b2-4210-9263-9b06720dcced.cfargotunnel.com` (proxied)

## Origin runtime state (web-projects)
- Host path used: `cto@100.113.84.79`
- Binary installed: `/usr/local/bin/cloudflared` (`2026.3.0`)
- Service unit: `/etc/systemd/system/cloudflared.service`
- Config: `/etc/cloudflared/config.yml`
- Status: `active (running)`

## Canonical host behavior
- Implemented at origin Nginx:
  - `www.alexkydanov.com` returns `301` to `https://alexkydanov.com$request_uri`
  - apex `alexkydanov.com` serves site content

## External validation
- `curl -I http://alexkydanov.com` -> `200 OK`
- `curl -I https://alexkydanov.com` -> `200`
- `curl -I http://www.alexkydanov.com` -> `301` with `Location: https://alexkydanov.com/`
- `curl -I https://www.alexkydanov.com` -> `301` with `Location: https://alexkydanov.com/`

## TLS posture notes
- Edge TLS terminates at Cloudflare.
- Tunnel carries origin traffic privately; no direct inbound office NAT dependency.
- Cloudflared logs show non-blocking ICMP/UDP buffer warnings; tunnel remains healthy.

## Rollback
1. Restore DNS records from backup:
   - `CLOUDFLARE_API_TOKEN=... ./scripts/cloudflare/rollback_alexkydanov_tunnel_dns.sh`
2. Stop cloudflared if needed:
   - `sudo systemctl stop cloudflared`
3. Optional cleanup after rollback:
   - remove `/etc/cloudflared/config.yml`
   - disable service: `sudo systemctl disable cloudflared`
