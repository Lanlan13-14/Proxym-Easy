#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/warp-zt.sh"

test -s "$SCRIPT"
sh -n "$SCRIPT"

grep -q '<key>organization</key><string>\$ORG</string>' "$SCRIPT"
grep -q '<key>auth_client_id</key><string>\$CLIENT_ID</string>' "$SCRIPT"
grep -q '<key>auth_client_secret</key><string>\$CLIENT_SECRET</string>' "$SCRIPT"
grep -q '<key>service_mode</key><string>tunnelonly</string>' "$SCRIPT"
grep -q "tunnel\[_ -\]?only" "$SCRIPT"
grep -q '<key>warp_tunnel_protocol</key><string>masque</string>' "$SCRIPT"
grep -q 'consumer WARP registration detected; deleting stale registration' "$SCRIPT"
grep -q 'consumer registration returned after cleanup' "$SCRIPT"
grep -q 'Split Tunnel Include mode' "$SCRIPT"
grep -q 'switch this Service Token profile to Exclude mode' "$SCRIPT"
grep -q 'registration exists but is not bound to Zero Trust organization' "$SCRIPT"
grep -q "grep -Eq '\^warp=(on|plus)\$'" "$SCRIPT"
grep -q 'https://cloudflare.com/cdn-cgi/trace' "$SCRIPT"
grep -q 'https://1.1.1.1/cdn-cgi/trace' "$SCRIPT"
grep -q 'dump_diagnostics' "$SCRIPT"
grep -q 'ip rule add to.*lookup main priority 10' "$SCRIPT"
grep -q 'ip -4 route show dev eth0 proto kernel' "$SCRIPT"
grep -q 'nft insert rule inet cloudflare-warp' "$SCRIPT"
if grep -Eq 'nft add rule inet cloudflare-warp' "$SCRIPT"; then
  echo "WARP client allow rules must insert at chain head, not append" >&2
  exit 1
fi
grep -q 'warp-restart-required' "$SCRIPT"
grep -q 'scheduled Zero Trust restart; stopping sniproxy and exiting' "$ROOT/scripts/entrypoint.sh"

# Fail-closed startup order: WARP verification must precede both listeners.
warp_line="$(grep -n 'warp-zt.sh.*start' "$ROOT/scripts/entrypoint.sh" | head -1 | cut -d: -f1)"
acl_line="$(grep -n 'apply-acl.sh' "$ROOT/scripts/entrypoint.sh" | head -1 | cut -d: -f1)"
dns_line="$(grep -n 'smartdns -R' "$ROOT/scripts/entrypoint.sh" | head -1 | cut -d: -f1)"
sni_line="$(grep -n 'sniproxy -c' "$ROOT/scripts/entrypoint.sh" | head -1 | cut -d: -f1)"
[ "$acl_line" -lt "$dns_line" ]
[ "$acl_line" -lt "$sni_line" ]
[ "$warp_line" -lt "$dns_line" ]
[ "$warp_line" -lt "$sni_line" ]

grep -q 'Zero Trust WARP unhealthy; stopping sniproxy' "$ROOT/scripts/entrypoint.sh"

# Reject obsolete cloudflared tunnel implementation.
if grep -RqsE 'cloudflared tunnel|CF_TUNNEL_TOKEN|ENABLE_ZT' \
  "$ROOT/scripts" "$ROOT/docker-compose.yml" "$ROOT/.env.example"; then
  echo "obsolete cloudflared Zero Trust implementation remains" >&2
  exit 1
fi

echo "warp-zt PASS"
