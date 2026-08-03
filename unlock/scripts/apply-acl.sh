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

log() { echo " >> [apply-acl] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

case "$ENABLE_ACL" in 1|true|yes) ;; 0|false|no) log "ACL disabled explicitly"; exit 0 ;; *) fail "ENABLE_ACL must be 0 or 1" ;; esac
[ -n "$ALLOWED_IPS" ] || fail "ALLOWED_IPS is required for DNS/SNI services"
case "$ENABLE_SOCKS5" in 1|true|yes) ENABLE_SOCKS5=1; [ -n "$SOCKS5_ALLOWED_IPS" ] || fail "SOCKS5_ALLOWED_IPS is required when SOCKS5 is enabled" ;; 0|false|no|'') ENABLE_SOCKS5=0 ;; *) fail "ENABLE_SOCKS5 must be 0 or 1" ;; esac

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

# DNS/SNI whitelist: only ports whose connection must originate at the client.
for proto in tcp udp; do
  add_cidrs "$ALLOWED_IPS" "$proto" dport "$DNS_PORT" accept
  add_cidrs "$ALLOWED_IPS" "$proto" dport "$DOT_PORT" accept
  add_cidrs "$ALLOWED_IPS" "$proto" dport 80 accept
  add_cidrs "$ALLOWED_IPS" "$proto" dport 443 accept
done
for proto in tcp udp; do
  nft add rule inet "$TABLE" input "$proto" dport "$DNS_PORT" drop
  nft add rule inet "$TABLE" input "$proto" dport "$DOT_PORT" drop
  nft add rule inet "$TABLE" input "$proto" dport 80 drop
  nft add rule inet "$TABLE" input "$proto" dport 443 drop
done

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

log "DNS/SNI ACL applied for DNS=$DNS_PORT DoT=$DOT_PORT HTTP=80 HTTPS=443"
