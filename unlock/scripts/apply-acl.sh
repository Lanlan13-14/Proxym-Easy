#!/bin/sh
set -eu

RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
ALLOWED_IPS="${ALLOWED_IPS:-}"
ENABLE_ACL="${ENABLE_ACL:-1}"
ENABLE_SOCKS5="${ENABLE_SOCKS5:-0}"
SOCKS5_ALLOWED_IPS="${SOCKS5_ALLOWED_IPS:-}"
SOCKS5_PORT="${SOCKS5_PORT:-1080}"
DNS_PORT="${DNS_UDP_PORT:-53}"
DOT_PORT="${DOT_PORT:-853}"
DOH_PORT="${DOH_PORT:-4430}"
ENABLE_DNS="${ENABLE_DNS:-0}"
ENABLE_DOT="${ENABLE_DOT:-1}"
ENABLE_DOH="${ENABLE_DOH:-1}"

log() { echo " >> [apply-acl] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

case "$ENABLE_ACL" in 1|true|yes) ;; 0|false|no) log "ACL disabled explicitly"; exit 0 ;; *) fail "ENABLE_ACL must be 0 or 1" ;; esac
[ -n "$ALLOWED_IPS" ] || fail "ALLOWED_IPS is required for DNS/SNI services"
case "$ENABLE_SOCKS5" in 1|true|yes) ENABLE_SOCKS5=1; [ -n "$SOCKS5_ALLOWED_IPS" ] || fail "SOCKS5_ALLOWED_IPS is required when SOCKS5 is enabled" ;; 0|false|no|'') ENABLE_SOCKS5=0 ;; *) fail "ENABLE_SOCKS5 must be 0 or 1" ;; esac
case "$ENABLE_DNS" in 1|true|yes) ENABLE_DNS=1 ;; 0|false|no|'') ENABLE_DNS=0 ;; *) fail "ENABLE_DNS must be 0 or 1" ;; esac
case "$ENABLE_DOT" in 1|true|yes) ENABLE_DOT=1 ;; 0|false|no|'') ENABLE_DOT=0 ;; *) fail "ENABLE_DOT must be 0 or 1" ;; esac
case "$ENABLE_DOH" in 1|true|yes) ENABLE_DOH=1 ;; 0|false|no|'') ENABLE_DOH=0 ;; *) fail "ENABLE_DOH must be 0 or 1" ;; esac
if [ "$ENABLE_DNS" = "0" ] && [ "$ENABLE_DOT" = "0" ] && [ "$ENABLE_DOH" = "0" ]; then
  fail "enable at least one of ENABLE_DNS, ENABLE_DOT, or ENABLE_DOH"
fi

TABLE="unlock_acl"
nft delete table inet "$TABLE" 2>/dev/null || true
nft add table inet "$TABLE"
nft 'add chain inet unlock_acl input { type filter hook input priority filter - 10; policy accept; }'
nft add rule inet "$TABLE" input iif lo accept

add_cidrs() {
  cidrs="$1"; shift
  oldifs="$IFS"; IFS=','
  for cidr in $cidrs; do
    cidr="$(printf '%s' "$cidr" | tr -d ' ')"
    [ -n "$cidr" ] || continue
    case "$cidr" in
      *:*) nft add rule inet "$TABLE" input ip6 saddr "$cidr" "$@" ;;
      *)   nft add rule inet "$TABLE" input ip saddr "$cidr" "$@" ;;
    esac
  done
  IFS="$oldifs"
}

# sniproxy always under ALLOWED_IPS. Plaintext DNS only when ENABLE_DNS=1
# (public bind); otherwise SmartDNS listens on loopback and no public ACL hole.
for proto in tcp udp; do
  add_cidrs "$ALLOWED_IPS" "$proto" dport 80 accept
  add_cidrs "$ALLOWED_IPS" "$proto" dport 443 accept
done
for proto in tcp udp; do
  nft add rule inet "$TABLE" input "$proto" dport 80 drop
  nft add rule inet "$TABLE" input "$proto" dport 443 drop
done

case "$ENABLE_DNS" in
  1)
    [ "$DNS_PORT" -ge 1 ] 2>/dev/null && [ "$DNS_PORT" -le 65535 ] 2>/dev/null || fail "invalid DNS_UDP_PORT"
    for proto in tcp udp; do
      add_cidrs "$ALLOWED_IPS" "$proto" dport "$DNS_PORT" accept
      nft add rule inet "$TABLE" input "$proto" dport "$DNS_PORT" drop
    done
    log "plain DNS ACL applied: UDP/TCP $DNS_PORT"
    ;;
esac

# DoT is TCP (and rarely UDP is unused for TLS); SmartDNS bind-tls is TCP.
case "$ENABLE_DOT" in
  1)
    [ "$DOT_PORT" -ge 1 ] 2>/dev/null && [ "$DOT_PORT" -le 65535 ] 2>/dev/null || fail "invalid DOT_PORT"
    add_cidrs "$ALLOWED_IPS" tcp dport "$DOT_PORT" accept
    nft add rule inet "$TABLE" input tcp dport "$DOT_PORT" drop
    log "DoT ACL applied: TCP $DOT_PORT"
    ;;
esac

# DoH is TCP-only HTTPS on DOH_PORT; shares ALLOWED_IPS with DNS/SNI.
case "$ENABLE_DOH" in
  1)
    [ "$DOH_PORT" -ge 1 ] 2>/dev/null && [ "$DOH_PORT" -le 65535 ] 2>/dev/null || fail "invalid DOH_PORT"
    add_cidrs "$ALLOWED_IPS" tcp dport "$DOH_PORT" accept
    nft add rule inet "$TABLE" input tcp dport "$DOH_PORT" drop
    log "DoH ACL applied: TCP $DOH_PORT"
    ;;
esac

# SOCKS uses an independent CIDR list. DNS/SNI ALLOWED_IPS never authorizes
# SOCKS access.
case "$ENABLE_SOCKS5" in
  1)
    [ "$SOCKS5_PORT" -ge 1 ] 2>/dev/null && [ "$SOCKS5_PORT" -le 65535 ] 2>/dev/null || fail "invalid SOCKS5_PORT"
    add_cidrs "$SOCKS5_ALLOWED_IPS" tcp dport "$SOCKS5_PORT" accept
    nft add rule inet "$TABLE" input tcp dport "$SOCKS5_PORT" drop
    log "SOCKS5 ACL applied: TCP $SOCKS5_PORT"
    ;;
esac

dns_desc="off"; [ "$ENABLE_DNS" = "1" ] && dns_desc="$DNS_PORT"
dot_desc="off"; [ "$ENABLE_DOT" = "1" ] && dot_desc="$DOT_PORT"
doh_desc="off"; [ "$ENABLE_DOH" = "1" ] && doh_desc="$DOH_PORT"
log "DNS/SNI ACL applied for DNS=$dns_desc DoT=$dot_desc DoH=$doh_desc HTTP=80 HTTPS=443"
