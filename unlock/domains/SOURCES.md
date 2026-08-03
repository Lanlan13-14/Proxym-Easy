# Domain sources

`all.txt` is the **published unlock domain list**. Running containers pull it from:

```text
https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock/domains/all.txt
```

## Daily rebuild (GitHub Actions)

Workflow: `.github/workflows/update-unlock-domains.yml`

- Schedule: `0 19 * * *` UTC = **03:00 Asia/Shanghai**
- Manual: `workflow_dispatch`
- Steps:
  1. Checkout `MetaCubeX/meta-rules-dat` branch `meta` (sparse `geo/geosite`)
  2. Read basenames from `domains/geosite-sources.txt`
  3. Run `scripts/build-geosite-domains.sh`
  4. Merge supplemental hosts from `StreamConfig.yaml` + `domains/1stream.txt`
  5. Normalize mihomo markers (`+.` / `*.` → bare FQDN), drop IPv4 / non-FQDN
  6. **Exclude** Google / YouTube family domains
  7. Commit `domains/all.txt` back to `main` when changed

## Runtime pull (container)

`scripts/domain-updater.sh`:

- Boot: seed from image-bundled `domains/all.txt`, then best-effort remote refresh
- Daily: default **04:00** (`DOMAIN_UPDATE_HOUR` / `DOMAIN_UPDATE_MINUTE`, container `TZ`)
- On change: regenerate SmartDNS/sniproxy configs, SIGHUP SmartDNS, restart sniproxy
- Fail closed: invalid/too-small/Google-contaminated remote lists are rejected

## Geosite lists (curated)

See `geosite-sources.txt`. Prefer service-specific lists over company mega-lists
(no bare `amazon` / `facebook` / `microsoft` / `google`).

Raw list URL pattern:

```text
https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/<name>.list
```

Mihomo markers in those files mean:

| Marker | Mihomo rule | Our storage |
|---|---|---|
| `example.com` | DOMAIN | bare `example.com` |
| `+.example.com` | DOMAIN-SUFFIX | bare `example.com` |
| `*.example.com` | DOMAIN-WILDCARD suffix | bare `example.com` |

SmartDNS `address /example.com/IP` and sniproxy `(^|\.)example\.com$` both match the name and its subdomains.

## Supplemental sources

Still merged so services without a geosite list are not lost:

1. `StreamConfig.yaml` — categorized historical unlock hosts (incl. AU/NZ/KR/TW niches).
2. `1stream.txt` — normalized FQDN snapshot from
   `1-stream/1stream-public-utils/stream.smartdns.list` (SHA-256
   `b9b31491c0ab99aaa88ddcef7038e296f4275401dd838aaf07c005d4ff2d2ca1`).

## Counts

Counts change every daily rebuild. Inspect:

```sh
wc -l unlock/domains/all.txt
```
