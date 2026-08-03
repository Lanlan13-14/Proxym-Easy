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
[ "$count" -ge 588 ] || { echo "merged domain list is incomplete (<588)"; fail=1; }
grep -qx 'claude.com' domains/all.txt || { echo "missing 1-stream supplemental domain claude.com"; fail=1; }
grep -qx 'spotify.com' domains/all.txt || { echo "missing StreamConfig-only domain spotify.com"; fail=1; }
# Google / YouTube intentionally excluded from unlock domain set.
if grep -qiE 'google|googleapis|youtube' domains/all.txt; then
  echo "google-related domains must not appear in domains/all.txt"
  fail=1
fi

echo "== gen-configs smoke =="
tmp="$(mktemp -d)"
export UNLOCK_ROOT="$ROOT"
export CONF_DIR="$tmp/conf"
export RUNTIME_DIR="$tmp/run"
export UNLOCK_IP="203.0.113.10"
export DOT_DOMAIN="test.unlock.example.com"
export DOT_TLS_MODE="selfsigned"
export ENABLE_DOT="1"
export DOT_PORT="9853"
export ENABLE_DOH="1"
export DOH_PORT="9443"
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
grep -q "bind-https .*:9443" "$CONF_DIR/smartdns.conf" || { echo "missing custom bind-https DoH port"; fail=1; }
grep -q "bind-cert-file $TLS_CERT" "$CONF_DIR/smartdns.conf" || { echo "missing TLS certificate path"; fail=1; }
grep -q "bind-cert-key-file $TLS_KEY" "$CONF_DIR/smartdns.conf" || { echo "missing TLS key path"; fail=1; }
grep -q "address /netflix.com/203.0.113.10" "$CONF_DIR/smartdns.conf" || { echo "missing netflix address"; fail=1; }
grep -q "bind-tls .*:9853 -force-aaaa-soa" "$CONF_DIR/smartdns.conf" || { echo "missing IPv6 bypass protection on DoT"; fail=1; }
grep -q "bind-https .*:9443 -force-aaaa-soa" "$CONF_DIR/smartdns.conf" || { echo "missing IPv6 bypass protection on DoH"; fail=1; }
if grep -q '^force-aaaa-soa ' "$CONF_DIR/smartdns.conf"; then
  echo "invalid global force-aaaa-soa directive"
  fail=1
fi
# DoH must not steal sniproxy 443.
if grep -E 'bind-https .*:443([[:space:]]|$)' "$CONF_DIR/smartdns.conf"; then
  echo "DoH must not bind port 443 (reserved for sniproxy)"
  fail=1
fi
grep -q "listen 80" "$CONF_DIR/sniproxy.conf" || { echo "missing transparent HTTP/80"; fail=1; }
grep -q "listen 443" "$CONF_DIR/sniproxy.conf" || { echo "missing transparent HTTPS/443"; fail=1; }
grep -q "table https_hosts" "$CONF_DIR/sniproxy.conf" || { echo "missing sniproxy table"; fail=1; }
grep -q "netflix" "$CONF_DIR/sniproxy.conf" || { echo "missing netflix in sniproxy"; fail=1; }

echo "== DoH-only path (no DoT) =="
tmp_doh="$(mktemp -d)"
CONF_DIR="$tmp_doh/conf" RUNTIME_DIR="$tmp_doh/run" \
  ENABLE_DNS=0 ENABLE_DOT=0 ENABLE_DOH=1 DOH_PORT=9853 \
  TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" \
  sh scripts/gen-configs.sh
grep -q "bind-https .*:9853" "$tmp_doh/conf/smartdns.conf" || { echo "DoH-only missing bind-https:9853"; fail=1; }
if grep -q 'bind-tls' "$tmp_doh/conf/smartdns.conf"; then
  echo "bind-tls must be absent when ENABLE_DOT=0"
  fail=1
fi
grep -q 'bind 127.0.0.1:53' "$tmp_doh/conf/smartdns.conf" || { echo "DoH-only must keep loopback plain DNS"; fail=1; }
rm -rf "$tmp_doh"

echo "== DoT-only path (no DoH) =="
tmp_dot="$(mktemp -d)"
CONF_DIR="$tmp_dot/conf" RUNTIME_DIR="$tmp_dot/run" \
  ENABLE_DNS=0 ENABLE_DOT=1 DOT_PORT=9853 ENABLE_DOH=0 \
  TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" \
  sh scripts/gen-configs.sh
grep -q "bind-tls .*:9853" "$tmp_dot/conf/smartdns.conf" || { echo "DoT-only missing bind-tls"; fail=1; }
if grep -q 'bind-https' "$tmp_dot/conf/smartdns.conf"; then
  echo "bind-https must be absent when ENABLE_DOH=0"
  fail=1
fi
rm -rf "$tmp_dot"

echo "== plain DNS only (no DoT/DoH, no DOT_DOMAIN) =="
tmp_dns="$(mktemp -d)"
if ! CONF_DIR="$tmp_dns/conf" RUNTIME_DIR="$tmp_dns/run" \
  ENABLE_DNS=1 ENABLE_DOT=0 ENABLE_DOH=0 \
  DOT_DOMAIN="" DOT_TLS_MODE=letsencrypt \
  sh scripts/gen-configs.sh >/dev/null; then
  echo "plain DNS only must succeed without DOT_DOMAIN"
  fail=1
fi
grep -q 'bind 0.0.0.0:53' "$tmp_dns/conf/smartdns.conf" || { echo "plain DNS missing public bind 0.0.0.0:53"; fail=1; }
grep -q 'bind-tcp 0.0.0.0:53' "$tmp_dns/conf/smartdns.conf" || { echo "plain DNS missing public bind-tcp"; fail=1; }
if grep -q 'bind-tls' "$tmp_dns/conf/smartdns.conf"; then
  echo "bind-tls must be absent for plain DNS only"
  fail=1
fi
if grep -q 'bind-https' "$tmp_dns/conf/smartdns.conf"; then
  echo "bind-https must be absent for plain DNS only"
  fail=1
fi
if grep -q 'bind-cert-file' "$tmp_dns/conf/smartdns.conf"; then
  echo "bind-cert-file must be absent for plain DNS only"
  fail=1
fi
if grep -q 'bind-cert-key-file' "$tmp_dns/conf/smartdns.conf"; then
  echo "bind-cert-key-file must be absent for plain DNS only"
  fail=1
fi
# cert-manager must no-op without domain/token when DoT/DoH are off.
if ! CONF_DIR="$tmp_dns/conf" RUNTIME_DIR="$tmp_dns/run" \
  ENABLE_DNS=1 ENABLE_DOT=0 ENABLE_DOH=0 DOT_DOMAIN="" \
  sh scripts/cert-manager.sh ensure >/dev/null; then
  echo "cert-manager ensure must skip when plain DNS only"
  fail=1
fi
rm -rf "$tmp_dns"

echo "== all DNS listeners disabled rejected =="
if CONF_DIR="$tmp/conf-none" RUNTIME_DIR="$tmp/run-none" \
  ENABLE_DNS=0 ENABLE_DOT=0 ENABLE_DOH=0 \
  TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" \
  sh scripts/gen-configs.sh 2>/dev/null; then
  echo "ENABLE_DNS=ENABLE_DOT=ENABLE_DOH=0 must be rejected"
  fail=1
fi

echo "== DoT without DOT_DOMAIN rejected =="
if CONF_DIR="$tmp/conf-nodomain" RUNTIME_DIR="$tmp/run-nodomain" \
  ENABLE_DNS=0 ENABLE_DOT=1 ENABLE_DOH=0 DOT_DOMAIN="" \
  sh scripts/gen-configs.sh 2>/dev/null; then
  echo "ENABLE_DOT=1 without DOT_DOMAIN must be rejected"
  fail=1
fi

echo "== DoH/DoT port conflict =="
if CONF_DIR="$tmp/conf-bad" RUNTIME_DIR="$tmp/run-bad" \
  ENABLE_DOT=1 ENABLE_DOH=1 DOH_PORT=443 \
  TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" \
  sh scripts/gen-configs.sh 2>/dev/null; then
  echo "DOH_PORT=443 must be rejected"
  fail=1
fi
if CONF_DIR="$tmp/conf-bad2" RUNTIME_DIR="$tmp/run-bad2" \
  ENABLE_DOT=1 DOT_PORT=9853 ENABLE_DOH=1 DOH_PORT=9853 \
  TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" \
  sh scripts/gen-configs.sh 2>/dev/null; then
  echo "same DOT_PORT and DOH_PORT must be rejected when both enabled"
  fail=1
fi
# DoH-only may use former DoT port freely.
if ! CONF_DIR="$tmp/conf-doh9853" RUNTIME_DIR="$tmp/run-doh9853" \
  ENABLE_DNS=0 ENABLE_DOT=0 ENABLE_DOH=1 DOH_PORT=9853 \
  TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" \
  sh scripts/gen-configs.sh >/dev/null; then
  echo "DoH-only on 9853 must be allowed"
  fail=1
fi

echo "== cert-manager DNS-01 / renewal / reload =="
sh tests/cert-manager.test.sh || fail=1

echo "== mandatory Cloudflare Zero Trust WARP =="
sh tests/warp-zt.test.sh || fail=1

echo "== optional SOCKS5 independent access controls =="
sh tests/socks.test.sh || fail=1
echo "== SOCKS5 free-charset runtime =="
python3 tests/socks5-runtime.py || fail=1

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
grep -q 'ENABLE_DNS' docker-compose.yml || { echo "compose missing ENABLE_DNS"; fail=1; }
grep -q 'ENABLE_DOT' docker-compose.yml || { echo "compose missing ENABLE_DOT"; fail=1; }
grep -q 'ENABLE_DOH' docker-compose.yml || { echo "compose missing ENABLE_DOH"; fail=1; }
grep -q 'DOH_PORT' docker-compose.yml || { echo "compose missing DOH_PORT"; fail=1; }
grep -q '\${DOH_PORT:-4430}:\${DOH_PORT:-4430}/tcp' docker-compose.yml || { echo "DoH port mapping is not dynamic"; fail=1; }
grep -q '\${DNS_UDP_PORT:-53}:\${DNS_UDP_PORT:-53}/udp' docker-compose.yml || { echo "plain DNS UDP mapping missing"; fail=1; }
grep -q '\${DNS_UDP_PORT:-53}:\${DNS_UDP_PORT:-53}/tcp' docker-compose.yml || { echo "plain DNS TCP mapping missing"; fail=1; }
grep -q 'bind-https' scripts/gen-configs.sh || { echo "gen-configs missing bind-https"; fail=1; }
grep -q 'ENABLE_DNS' scripts/gen-configs.sh || { echo "gen-configs missing ENABLE_DNS"; fail=1; }
grep -q 'ENABLE_DOT' scripts/gen-configs.sh || { echo "gen-configs missing ENABLE_DOT"; fail=1; }
grep -q 'ENABLE_DNS' scripts/apply-acl.sh || { echo "ACL missing ENABLE_DNS"; fail=1; }
grep -q 'ENABLE_DOT' scripts/apply-acl.sh || { echo "ACL missing ENABLE_DOT"; fail=1; }
grep -q 'DOH_PORT' scripts/apply-acl.sh || { echo "ACL missing DoH port"; fail=1; }
grep -q 'ENABLE_DNS' scripts/warp-zt.sh || { echo "WARP return mark missing ENABLE_DNS"; fail=1; }
grep -q 'ENABLE_DOT' scripts/warp-zt.sh || { echo "WARP return mark missing ENABLE_DOT"; fail=1; }
grep -q 'DOH_PORT' scripts/warp-zt.sh || { echo "WARP return mark missing DoH port"; fail=1; }
grep -q 'ENABLE_DNS=0' .env.example || { echo "env example missing ENABLE_DNS"; fail=1; }
grep -q 'ENABLE_DOT=1' .env.example || { echo "env example missing ENABLE_DOT"; fail=1; }
grep -q 'ENABLE_DOH=1' .env.example || { echo "env example missing ENABLE_DOH"; fail=1; }
grep -q 'DOH_PORT=4430' .env.example || { echo "env example missing DOH_PORT"; fail=1; }
grep -q 'at least one of ENABLE_DNS, ENABLE_DOT, or ENABLE_DOH' scripts/gen-configs.sh || { echo "missing all-disabled guard"; fail=1; }
grep -q 'plain DNS only' scripts/gen-configs.sh || { echo "gen-configs missing plain DNS path"; fail=1; }
grep -q 'DoT/DoH disabled; skipping TLS' scripts/cert-manager.sh || { echo "cert-manager missing plain-DNS skip"; fail=1; }
grep -q 'CF_DNS_API_TOKEN' .env.example || { echo "missing Cloudflare DNS token config"; fail=1; }
grep -q 'cert-manager.sh' scripts/entrypoint.sh || { echo "certificate manager not started"; fail=1; }
grep -q 'CLOUDFLARE_DNS_API_TOKEN' scripts/cert-manager.sh || { echo "lego Cloudflare DNS token missing"; fail=1; }
grep -q 'WARP_ORGANIZATION' docker-compose.yml || { echo "compose missing Zero Trust organization"; fail=1; }
grep -q 'WARP_CLIENT_ID' docker-compose.yml || { echo "compose missing Zero Trust Client ID"; fail=1; }
grep -q 'WARP_CLIENT_SECRET' docker-compose.yml || { echo "compose missing Zero Trust Client Secret"; fail=1; }
grep -q 'cloudflare-warp_' Dockerfile || { echo "official Cloudflare One Client package missing"; fail=1; }
grep -q 'warp-svc' Dockerfile || { echo "official warp-svc missing"; fail=1; }
grep -q 'unlock-socks5d' Dockerfile || { echo "unlock-socks5d SOCKS5 server missing"; fail=1; }
grep -q 'socks5d.c' Dockerfile || { echo "socks5d.c not built in image"; fail=1; }
if grep -q 'dante-server' Dockerfile; then
  echo "Dockerfile still installs dante-server"
  fail=1
fi
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
