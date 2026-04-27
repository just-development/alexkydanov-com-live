# JUS-71 origin cutover runbook (web-projects)

## Confirmed state
- Active nginx root: `/srv/web-projects/sites/alexkydanov.com/current`
- Current symlink target: `/srv/web-projects/sites/alexkydanov.com/releases/20260414191051`
- That release serves legacy dry-run payload.
- Tunnel ingress for apex/www is currently set to `http://127.0.0.1:80`.

## Goal
Switch local origin content to the real live build so tunnel traffic serves intended site output.

## On-host execution (web-projects)

1. Inspect available releases and locate real build candidate:
```bash
ls -lah /srv/web-projects/sites/alexkydanov.com/releases
for r in /srv/web-projects/sites/alexkydanov.com/releases/*; do
  echo "=== $r ==="
  head -n 5 "$r/index.html" || true
done
```

2. Choose release directory (`$NEW_RELEASE`) that contains real site build (not JUS-49 dry run).

3. Backup current symlink target and switch:
```bash
cd /srv/web-projects/sites/alexkydanov.com
PREV_TARGET=$(readlink -f current)
echo "PREV_TARGET=$PREV_TARGET"
ln -sfn "$NEW_RELEASE" current
readlink -f current
```

4. Validate local nginx output before public checks:
```bash
curl -sv -H 'Host: alexkydanov.com' http://127.0.0.1/
curl -sv -H 'Host: alexkydanov.com' http://127.0.0.1/sitemap.xml
curl -sv -H 'Host: alexkydanov.com' http://127.0.0.1/robots.txt
```

5. If nginx config changed, test/reload:
```bash
nginx -t
systemctl reload nginx
```

## Public validation (post-cutover)
```bash
curl -I https://alexkydanov.com
curl -I https://www.alexkydanov.com
curl -sS https://alexkydanov.com/sitemap.xml | head
curl -sS https://alexkydanov.com/robots.txt | head
```

Expected:
- apex returns `200` with real site payload
- `www` redirects `301` to apex
- `/sitemap.xml` returns XML (not dry-run html)
- `/robots.txt` returns plaintext robots directives

## Optional cache cleanup
If stale legacy response persists after origin fix, purge Cloudflare cache for:
- `https://alexkydanov.com/`
- `https://alexkydanov.com/sitemap.xml`
- `https://alexkydanov.com/robots.txt`

## Rollback
If new release is bad:
```bash
cd /srv/web-projects/sites/alexkydanov.com
ln -sfn "$PREV_TARGET" current
readlink -f current
curl -sv -H 'Host: alexkydanov.com' http://127.0.0.1/
```

## JUS-54 unblock gate
JUS-54 can be unblocked only after all four public validations pass with real content.
