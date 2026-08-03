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
# Public DNS listeners are independent:
#   ENABLE_DNS=1 -> plaintext bind UDP/TCP :DNS_UDP_PORT on BIND_HOST (published)
#   ENABLE_DOT=1 -> bind-tls  :DOT_PORT
#   ENABLE_DOH=1 -> bind-https :DOH_PORT  (path /dns-query)
# At least one of ENABLE_DNS / ENABLE_DOT / ENABLE_DOH is required.
# Plaintext DNS always binds loopback for healthchecks even when ENABLE_DNS=0.
# 443 is reserved for sniproxy SNI unlock — never use it for DoH.
DOT_PORT="${DOT_PORT:-853}"
DOH_PORT="${DOH_PORT:-4430}"
ENABLE_DNS="${ENABLE_DNS:-0}"
ENABLE_DOT="${ENABLE_DOT:-1}"
ENABLE_DOH="${ENABLE_DOH:-1}"
# Transparent DNS unlock cannot use custom web ports: clients always connect
# to HTTP/80 and HTTPS/443 after DNS resolution.
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
# Shared by DoT and DoH TLS (same cert/SNI). DOT_SERVER_NAME is a legacy alias.
# Required only when ENABLE_DOT or ENABLE_DOH is on — plain DNS needs neither.
DOT_DOMAIN="${DOT_DOMAIN:-${DOT_SERVER_NAME:-}}"
DOT_TLS_MODE="${DOT_TLS_MODE:-letsencrypt}"

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}
normalize_bool() {
  # $1=value $2=name -> prints 0 or 1
  case "$1" in
    1|true|yes) echo 1 ;;
    0|false|no|'') echo 0 ;;
    *) echo "ERROR: $2 must be 0 or 1" >&2; exit 1 ;;
  esac
}
ENABLE_DNS="$(normalize_bool "$ENABLE_DNS" ENABLE_DNS)"
ENABLE_DOT="$(normalize_bool "$ENABLE_DOT" ENABLE_DOT)"
ENABLE_DOH="$(normalize_bool "$ENABLE_DOH" ENABLE_DOH)"
if [ "$ENABLE_DNS" = "0" ] && [ "$ENABLE_DOT" = "0" ] && [ "$ENABLE_DOH" = "0" ]; then
  echo "ERROR: enable at least one of ENABLE_DNS, ENABLE_DOT, or ENABLE_DOH" >&2
  exit 1
fi
NEED_TLS=0
if [ "$ENABLE_DOT" = "1" ] || [ "$ENABLE_DOH" = "1" ]; then
  NEED_TLS=1
fi

TLS_CERT=""
TLS_KEY=""
if [ "$NEED_TLS" = "1" ]; then
  if [ -z "$DOT_DOMAIN" ]; then
    echo "ERROR: DOT_DOMAIN is required when ENABLE_DOT or ENABLE_DOH is enabled" >&2
    exit 1
  fi
  case "$DOT_TLS_MODE" in
    letsencrypt) TLS_CERT="${TLS_CERT:-$CONF_DIR/letsencrypt/certificates/$DOT_DOMAIN.crt}"; TLS_KEY="${TLS_KEY:-$CONF_DIR/letsencrypt/certificates/$DOT_DOMAIN.key}" ;;
    selfsigned|custom) TLS_CERT="${TLS_CERT:-$CONF_DIR/tls/cert.pem}"; TLS_KEY="${TLS_KEY:-$CONF_DIR/tls/key.pem}" ;;
    *) echo "ERROR: DOT_TLS_MODE must be letsencrypt, selfsigned, or custom" >&2; exit 1 ;;
  esac
  DOT_SERVER_NAME="$DOT_DOMAIN"
else
  # Plain DNS only: no cert paths, no ACME domain.
  DOT_TLS_MODE="none"
  DOT_SERVER_NAME="${DOT_DOMAIN:-unlock}"
fi
export DOT_DOMAIN DOT_TLS_MODE TLS_CERT TLS_KEY NEED_TLS ENABLE_DNS ENABLE_DOT ENABLE_DOH
export DOT_SERVER_NAME

reserved_port() {
  # $1=port $2=label — reject 53/80/443 and plaintext DNS port
  case "$1" in
    53|80|443|"$DNS_UDP_PORT")
      echo "ERROR: $2=$1 conflicts with DNS/SNI reserved ports (53/80/443/DNS_UDP_PORT)" >&2
      exit 1
      ;;
  esac
}

valid_port "$DNS_UDP_PORT" || { echo "ERROR: invalid DNS_UDP_PORT: $DNS_UDP_PORT" >&2; exit 1; }
case "$DNS_UDP_PORT" in
  80|443)
    echo "ERROR: DNS_UDP_PORT=$DNS_UDP_PORT conflicts with sniproxy 80/443" >&2
    exit 1
    ;;
esac

if [ "$ENABLE_DOT" = "1" ]; then
  valid_port "$DOT_PORT" || { echo "ERROR: invalid DOT_PORT: $DOT_PORT" >&2; exit 1; }
  reserved_port "$DOT_PORT" DOT_PORT
fi
if [ "$ENABLE_DOH" = "1" ]; then
  valid_port "$DOH_PORT" || { echo "ERROR: invalid DOH_PORT: $DOH_PORT" >&2; exit 1; }
  reserved_port "$DOH_PORT" DOH_PORT
fi
if [ "$ENABLE_DOT" = "1" ] && [ "$ENABLE_DOH" = "1" ] && [ "$DOT_PORT" = "$DOH_PORT" ]; then
  echo "ERROR: DOT_PORT and DOH_PORT both set to $DOT_PORT; use different ports or disable one" >&2
  exit 1
fi
PLATFORMS="${PLATFORMS:-all}"
REGIONS="${REGIONS:-}"
SNIPROXY_USER="${SNIPROXY_USER:-nobody}"
SNIPROXY_WORKERS="${SNIPROXY_WORKERS:-auto}"

mkdir -p "$CONF_DIR" "$RUNTIME_DIR"
if [ "$NEED_TLS" = "1" ]; then
  mkdir -p "$(dirname "$TLS_CERT")" "$(dirname "$TLS_KEY")"
fi

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
# Public plaintext DNS only when ENABLE_DNS=1. Otherwise keep loopback for
# healthchecks/exec dig so the host mapping (if any) has nothing useful to hit.
if [ "$ENABLE_DNS" = "1" ]; then
  DNS_BIND_HOST="$BIND_HOST"
else
  DNS_BIND_HOST="127.0.0.1"
fi
{
  cat <<EOF
server-name $DOT_SERVER_NAME
bind ${DNS_BIND_HOST}:${DNS_UDP_PORT}${bind_flags}
bind-tcp ${DNS_BIND_HOST}:${DNS_UDP_PORT}${bind_flags}
EOF
  if [ "$ENABLE_DOT" = "1" ]; then
    echo "bind-tls ${BIND_HOST}:${DOT_PORT}${bind_flags}"
  fi
  if [ "$ENABLE_DOH" = "1" ]; then
    # SmartDNS DoH endpoint is https://<host>:<DOH_PORT>/dns-query
    # Same Let's Encrypt cert/SNI as DoT (DOT_DOMAIN).
    echo "bind-https ${BIND_HOST}:${DOH_PORT}${bind_flags}"
  fi
  if [ "$NEED_TLS" = "1" ]; then
    echo "bind-cert-file $TLS_CERT"
    echo "bind-cert-key-file $TLS_KEY"
  fi
  cat <<EOF
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
# this config is used, and only when DoT/DoH needs TLS. Plain DNS skips ACME.
dns_desc="loopback:$DNS_UDP_PORT"
[ "$ENABLE_DNS" = "1" ] && dns_desc="public:$DNS_UDP_PORT"
dot_desc="off"; [ "$ENABLE_DOT" = "1" ] && dot_desc="$DOT_PORT"
doh_desc="off"; [ "$ENABLE_DOH" = "1" ] && doh_desc="$DOH_PORT"
if [ "$NEED_TLS" = "1" ]; then
  echo " >> gen-configs: TLS mode=$DOT_TLS_MODE domain=$DOT_DOMAIN DNS=$dns_desc DoT=$dot_desc DoH=$doh_desc cert=$TLS_CERT"
else
  echo " >> gen-configs: TLS none (plain DNS only) DNS=$dns_desc DoT=off DoH=off"
fi
echo " >> gen-configs: wrote $CONF_DIR/sniproxy.conf $CONF_DIR/smartdns.conf"
