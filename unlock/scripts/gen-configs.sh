#!/bin/sh
# Render runtime configs from env + domain list.
set -eu

# In the image UNLOCK_ROOT is /opt/unlock. In CI/local checkout, derive it
# from this script so callers do not need to export a container-only path.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="${UNLOCK_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
DOMAINS_FILE="${DOMAINS_FILE:-$ROOT/domains/all.txt}"

BIND_HOST="${BIND_HOST:-0.0.0.0}"
DNS_UDP_PORT="${DNS_UDP_PORT:-53}"
DOT_PORT="${DOT_PORT:-853}"
# Transparent DNS unlock cannot use custom web ports: clients always connect
# to HTTP/80 and HTTPS/443 after DNS resolution. Only DOT_PORT is configurable.
HTTP_PORT=80
HTTPS_PORT=443
UNLOCK_IP="${UNLOCK_IP:-}"
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1,1.0.0.1,8.8.8.8}"
CACHE_SIZE="${CACHE_SIZE:-32768}"
# Most DNS-unlock hosts publish only IPv4. Suppress AAAA by default so a client
# cannot bypass sniproxy through a direct IPv6 connection.
FORCE_AAAA_SOA="${FORCE_AAAA_SOA:-yes}"
SPEED_CHECK_MODE="${SPEED_CHECK_MODE:-ping,tcp:80,tcp:443}"
# DOT_DOMAIN is the public FQDN validated by Let's Encrypt DNS-01.
# DOT_SERVER_NAME is retained as a backwards-compatible alias.
DOT_DOMAIN="${DOT_DOMAIN:-${DOT_SERVER_NAME:-}}"
DOT_TLS_MODE="${DOT_TLS_MODE:-letsencrypt}"
if [ -z "$DOT_DOMAIN" ]; then
  echo "ERROR: DOT_DOMAIN is required for DoT" >&2
  exit 1
fi
case "$DOT_TLS_MODE" in
  letsencrypt) TLS_CERT="${TLS_CERT:-$CONF_DIR/letsencrypt/certificates/$DOT_DOMAIN.crt}"; TLS_KEY="${TLS_KEY:-$CONF_DIR/letsencrypt/certificates/$DOT_DOMAIN.key}" ;;
  selfsigned|custom) TLS_CERT="${TLS_CERT:-$CONF_DIR/tls/cert.pem}"; TLS_KEY="${TLS_KEY:-$CONF_DIR/tls/key.pem}" ;;
  *) echo "ERROR: DOT_TLS_MODE must be letsencrypt, selfsigned, or custom" >&2; exit 1 ;;
esac
export DOT_DOMAIN DOT_TLS_MODE TLS_CERT TLS_KEY
DOT_SERVER_NAME="$DOT_DOMAIN"
PLATFORMS="${PLATFORMS:-all}"
REGIONS="${REGIONS:-}"
SNIPROXY_USER="${SNIPROXY_USER:-nobody}"
SNIPROXY_WORKERS="${SNIPROXY_WORKERS:-auto}"

mkdir -p "$CONF_DIR" "$RUNTIME_DIR" "$(dirname "$TLS_CERT")" "$(dirname "$TLS_KEY")"

if [ -z "$UNLOCK_IP" ]; then
  # Best-effort public IP; can be overridden via env.
  UNLOCK_IP="$(curl -fsS --max-time 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')" || true
fi
if [ -z "$UNLOCK_IP" ]; then
  UNLOCK_IP="$(hostname -i 2>/dev/null | awk '{print $1}')" || true
fi
if [ -z "$UNLOCK_IP" ]; then
  UNLOCK_IP="127.0.0.1"
fi

if [ ! -f "$DOMAINS_FILE" ] || [ ! -s "$DOMAINS_FILE" ]; then
  "$ROOT/scripts/gen-domains.sh"
fi

# Optional filter by region/platform keys in StreamConfig.yaml
filter_domains() {
  if [ "$PLATFORMS" = "all" ] && [ -z "$REGIONS" ]; then
    cat "$DOMAINS_FILE"
    return
  fi
  # When filtering is requested, re-parse StreamConfig for selected sections.
  python3 - "$ROOT/StreamConfig.yaml" "$PLATFORMS" "$REGIONS" <<'PY'
import re, sys
path, platforms, regions = sys.argv[1:4]
text = open(path, encoding="utf-8").read().splitlines()
want = set()
if platforms and platforms != "all":
    for p in platforms.split(","):
        p=p.strip()
        if p: want.add(p)
if regions:
    for r in regions.split(","):
        r=r.strip()
        if r: want.add(r)

current_top = None
include = platforms == "all" and not regions
domains=[]
top_re = re.compile(r'^([A-Za-z0-9_]+):\s*$')
sub_re = re.compile(r'^  ([A-Za-z0-9_]+):\s*$')
dom_re = re.compile(r'^\s+-\s+([A-Za-z0-9._-]+)\s*$')
for line in text:
    m = top_re.match(line)
    if m:
        current_top = m.group(1)
        include = (not want) or (current_top in want)
        continue
    m = sub_re.match(line)
    if m:
        # keep include based on top-level or exact sub name
        name = m.group(1)
        if want:
            include = (current_top in want) or (name in want)
        continue
    m = dom_re.match(line)
    if m and include:
        d=m.group(1).lower()
        if "." in d:
            domains.append(d)
for d in sorted(set(domains)):
    print(d)
PY
}

DOMAIN_LIST="$(filter_domains)"
DOMAIN_COUNT="$(printf '%s\n' "$DOMAIN_LIST" | sed '/^$/d' | wc -l | tr -d ' ')"
printf '%s\n' "$DOMAIN_LIST" > "$RUNTIME_DIR/domains.active"
echo " >> gen-configs: UNLOCK_IP=$UNLOCK_IP domains=$DOMAIN_COUNT"

# --- sniproxy.conf ---
{
  cat <<EOF
user $SNIPROXY_USER
pidfile $RUNTIME_DIR/sniproxy.pid

error_log {
    syslog daemon
    priority notice
}

listen $HTTP_PORT {
    proto http
    table https_hosts
    fallback 127.0.0.1:9
}

listen $HTTPS_PORT {
    proto tls
    table https_hosts
    fallback 127.0.0.1:9
}

table https_hosts {
EOF
  printf '%s\n' "$DOMAIN_LIST" | sed '/^$/d' | while IFS= read -r d; do
    # regex match suffix domain
    esc="$(printf '%s' "$d" | sed 's/\./\\./g')"
    printf '    .*%s$ *\n' "$esc"
  done
  echo "}"
} > "$CONF_DIR/sniproxy.conf"

# --- smartdns.conf ---
# force-aaaa-soa is a bind option (not a global `yes/no` directive).
# It prevents IPv4-only DNS unlock hosts from leaking traffic through AAAA.
bind_flags=""
case "$FORCE_AAAA_SOA" in
  yes|true|1) bind_flags=" -force-aaaa-soa" ;;
  no|false|0|'') ;;
  *) echo "ERROR: FORCE_AAAA_SOA must be yes or no" >&2; exit 1 ;;
esac
{
  cat <<EOF
server-name $DOT_SERVER_NAME
bind ${BIND_HOST}:${DNS_UDP_PORT}${bind_flags}
bind-tcp ${BIND_HOST}:${DNS_UDP_PORT}${bind_flags}
bind-tls ${BIND_HOST}:${DOT_PORT}${bind_flags}
bind-cert-file $TLS_CERT
bind-cert-key-file $TLS_KEY
cache-size $CACHE_SIZE
cache-persist no
prefetch-domain yes
rr-ttl-min 30
rr-ttl-max 600
dualstack-ip-selection yes
speed-check-mode $SPEED_CHECK_MODE
log-level info
log-console yes
force-qtype-SOA 65
EOF

  # upstream DNS
  oldifs="$IFS"
  IFS=','
  for s in $UPSTREAM_DNS; do
    s="$(echo "$s" | tr -d ' ')"
    [ -n "$s" ] || continue
    echo "server $s"
  done
  IFS="$oldifs"

  # Streaming domains resolve to unlock host IP (classic DNS unlock).
  printf '%s\n' "$DOMAIN_LIST" | sed '/^$/d' | while IFS= read -r d; do
    printf 'address /%s/%s\n' "$d" "$UNLOCK_IP"
  done
} > "$CONF_DIR/smartdns.conf"

# Zero Trust WARP registration is handled by warp-zt.sh. This generator never
# writes WARP secrets into SmartDNS/sniproxy configuration files.

# Certificate creation/renewal is intentionally handled by cert-manager.sh BEFORE
# this config is used. There is no silent self-signed fallback in production.
echo " >> gen-configs: DoT TLS mode=$DOT_TLS_MODE domain=$DOT_DOMAIN cert=$TLS_CERT"
echo " >> gen-configs: wrote $CONF_DIR/sniproxy.conf $CONF_DIR/smartdns.conf"
