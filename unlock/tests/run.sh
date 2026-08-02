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
UNLOCK_ROOT="$ROOT" sh scripts/gen-domains.sh
test -s domains/all.txt || fail=1
count="$(wc -l < domains/all.txt | tr -d ' ')"
echo "domains=$count"
[ "$count" -gt 50 ] || { echo "too few domains"; fail=1; }

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
grep -q "force-aaaa-soa yes" "$CONF_DIR/smartdns.conf" || { echo "missing IPv6 bypass protection"; fail=1; }
grep -q "listen 80" "$CONF_DIR/sniproxy.conf" || { echo "missing transparent HTTP/80"; fail=1; }
grep -q "listen 443" "$CONF_DIR/sniproxy.conf" || { echo "missing transparent HTTPS/443"; fail=1; }
grep -q "table https_hosts" "$CONF_DIR/sniproxy.conf" || { echo "missing sniproxy table"; fail=1; }
grep -q "netflix" "$CONF_DIR/sniproxy.conf" || { echo "missing netflix in sniproxy"; fail=1; }

echo "== cert-manager DNS-01 / renewal / reload =="
sh tests/cert-manager.test.sh || fail=1

echo "== dockerfile context isolation =="
# Ensure Dockerfile only COPY . (relative to unlock/)
grep -q '^COPY \. /opt/unlock/' Dockerfile || { echo "Dockerfile COPY not isolated"; fail=1; }
# Ensure no parent path references in Dockerfile
if grep -nE '\.\./|Proxym-Easy/script|xray\.sh' Dockerfile; then
  echo "Dockerfile leaks outside unlock/"
  fail=1
fi

echo "== compose dynamic port + ACME wiring =="
grep -q 'DOT_TLS_MODE' docker-compose.yml || { echo "compose does not pass TLS mode"; fail=1; }
grep -q '\${DOT_PORT:-853}:\${DOT_PORT:-853}/tcp' docker-compose.yml || { echo "DoT port mapping is not dynamic"; fail=1; }
grep -q 'CF_DNS_API_TOKEN' .env.example || { echo "missing Cloudflare DNS token config"; fail=1; }
grep -q 'cert-manager.sh' scripts/entrypoint.sh || { echo "certificate manager not started"; fail=1; }
grep -q 'CLOUDFLARE_DNS_API_TOKEN' scripts/cert-manager.sh || { echo "lego Cloudflare DNS token missing"; fail=1; }

echo "== .dockerignore present =="
test -f .dockerignore || { echo "missing .dockerignore"; fail=1; }

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  echo "FAIL"
  exit 1
fi
echo "PASS"
