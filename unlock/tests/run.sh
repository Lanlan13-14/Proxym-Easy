#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

echo "== shell syntax =="
for f in scripts/*.sh tests/*.sh; do
  [ -f "$f" ] || continue
  sh -n "$f" || fail=1
done

echo "== gen-domains =="
# CI runs inside unlock/ without UNLOCK_ROOT; the script must find checkout files.
env -u UNLOCK_ROOT sh scripts/gen-domains.sh
test -s domains/all.txt || fail=1
# Image mode still supports its explicit /opt/unlock root.
UNLOCK_ROOT="$ROOT" sh scripts/gen-domains.sh
test -s domains/all.txt || fail=1
count="$(wc -l < domains/all.txt | tr -d ' ')"
echo "domains=$count"
[ "$count" -ge 600 ] || { echo "merged domain list is incomplete (<600)"; fail=1; }
grep -qx 'claude.com' domains/all.txt || { echo "missing 1-stream supplemental domain claude.com"; fail=1; }
grep -qx 'spotify.com' domains/all.txt || { echo "missing StreamConfig-only domain spotify.com"; fail=1; }

echo "== gen-configs smoke =="
tmp="$(mktemp -d)"
export UNLOCK_ROOT="$ROOT"
export CONF_DIR="$tmp/conf"
export RUNTIME_DIR="$tmp/run"
export UNLOCK_IP="203.0.113.10"
export DOT_DOMAIN="test.unlock.example.com"
export DOT_TLS_MODE="selfsigned"
export DOT_PORT="9853"
# HTTP_PORT/HTTPS_PORT are intentionally ignored by transparent DNS unlock.
# sniproxy must stay on 80/443 because clients retain their destination port.
unset TLS_CERT TLS_KEY LEGO_PATH
export PLATFORMS="all"
# Explicit test-only TLS path: production default is Let's Encrypt, never an
# implicit self-signed fallback.
sh scripts/cert-manager.sh ensure
TLS_CERT="$tmp/conf/tls/cert.pem"
TLS_KEY="$tmp/conf/tls/key.pem"
test -s "$TLS_CERT" && test -s "$TLS_KEY" || { echo "test TLS missing"; fail=1; }
sh scripts/gen-configs.sh
test -s "$CONF_DIR/smartdns.conf" || fail=1
test -s "$CONF_DIR/sniproxy.conf" || fail=1
grep -q "bind-tls .*:9853" "$CONF_DIR/smartdns.conf" || { echo "missing custom bind-tls port"; fail=1; }
grep -q "bind-cert-file $TLS_CERT" "$CONF_DIR/smartdns.conf" || { echo "missing TLS certificate path"; fail=1; }
grep -q "bind-cert-key-file $TLS_KEY" "$CONF_DIR/smartdns.conf" || { echo "missing TLS key path"; fail=1; }
grep -q "address /netflix.com/203.0.113.10" "$CONF_DIR/smartdns.conf" || { echo "missing netflix address"; fail=1; }
grep -q "bind-tls .*:9853 -force-aaaa-soa" "$CONF_DIR/smartdns.conf" || { echo "missing IPv6 bypass protection on DoT"; fail=1; }
if grep -q '^force-aaaa-soa ' "$CONF_DIR/smartdns.conf"; then
  echo "invalid global force-aaaa-soa directive"
  fail=1
fi
grep -q "listen 80" "$CONF_DIR/sniproxy.conf" || { echo "missing transparent HTTP/80"; fail=1; }
grep -q "listen 443" "$CONF_DIR/sniproxy.conf" || { echo "missing transparent HTTPS/443"; fail=1; }
grep -q "table https_hosts" "$CONF_DIR/sniproxy.conf" || { echo "missing sniproxy table"; fail=1; }
grep -q "netflix" "$CONF_DIR/sniproxy.conf" || { echo "missing netflix in sniproxy"; fail=1; }

echo "== cert-manager DNS-01 / renewal / reload =="
sh tests/cert-manager.test.sh || fail=1

echo "== mandatory Cloudflare Zero Trust WARP =="
sh tests/warp-zt.test.sh || fail=1

echo "== optional SOCKS5 independent access controls =="
sh tests/socks.test.sh || fail=1

echo "== dockerfile context isolation =="
# Ensure Dockerfile only COPY . (relative to unlock/)
grep -q '^COPY \. /opt/unlock/' Dockerfile || { echo "Dockerfile COPY not isolated"; fail=1; }
# Ensure no parent path references in Dockerfile
if grep -nE '\.\./|Proxym-Easy/script|xray\.sh' Dockerfile; then
  echo "Dockerfile leaks outside unlock/"
  fail=1
fi
if grep -q '/opt/unlock/tests' Dockerfile && grep -qx 'tests' .dockerignore; then
  echo "Dockerfile references tests excluded from build context"
  fail=1
fi

echo "== compose dynamic port + ACME wiring =="
grep -q 'DOT_TLS_MODE' docker-compose.yml || { echo "compose does not pass TLS mode"; fail=1; }
grep -q '\${DOT_PORT:-853}:\${DOT_PORT:-853}/tcp' docker-compose.yml || { echo "DoT port mapping is not dynamic"; fail=1; }
if grep -qE '53:53|DNS_UDP_PORT[^\n]*:/tcp|DNS_UDP_PORT[^\n]*:/udp' docker-compose.yml; then
  echo "plaintext DNS/53 must not be published"
  fail=1
fi
grep -q 'CF_DNS_API_TOKEN' .env.example || { echo "missing Cloudflare DNS token config"; fail=1; }
grep -q 'cert-manager.sh' scripts/entrypoint.sh || { echo "certificate manager not started"; fail=1; }
grep -q 'CLOUDFLARE_DNS_API_TOKEN' scripts/cert-manager.sh || { echo "lego Cloudflare DNS token missing"; fail=1; }
grep -q 'WARP_ORGANIZATION' docker-compose.yml || { echo "compose missing Zero Trust organization"; fail=1; }
grep -q 'WARP_CLIENT_ID' docker-compose.yml || { echo "compose missing Zero Trust Client ID"; fail=1; }
grep -q 'WARP_CLIENT_SECRET' docker-compose.yml || { echo "compose missing Zero Trust Client Secret"; fail=1; }
grep -q 'cloudflare-warp_' Dockerfile || { echo "official Cloudflare One Client package missing"; fail=1; }
grep -q 'warp-svc' Dockerfile || { echo "official warp-svc missing"; fail=1; }
grep -q 'dante-server' Dockerfile || { echo "Dante SOCKS5 server missing"; fail=1; }
grep -q 'start-socks.sh' scripts/entrypoint.sh || { echo "SOCKS5 startup not wired"; fail=1; }
grep -q 'SOCKS5_ALLOWED_IPS' docker-compose.yml || { echo "SOCKS5 independent ACL missing"; fail=1; }

echo "== .dockerignore present =="
test -f .dockerignore || { echo "missing .dockerignore"; fail=1; }

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  echo "FAIL"
  exit 1
fi
echo "PASS"
