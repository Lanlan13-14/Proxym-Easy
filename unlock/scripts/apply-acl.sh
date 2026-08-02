#!/bin/sh
# Apply IP whitelist for DNS unlock ports using nftables (fallback iptables).
# ALLOWED_IPS: comma-separated CIDRs/IPs. Empty = allow all (not recommended).
set -eu

ALLOWED_IPS="${ALLOWED_IPS:-}"
DNS_UDP_PORT="${DNS_UDP_PORT:-53}"
DOT_PORT="${DOT_PORT:-853}"
# Transparent DNS unlock always proxies the web ports clients actually use.
HTTP_PORT=80
HTTPS_PORT=443
ACL_TABLE="${ACL_TABLE:-unlock_acl}"

ports="$DNS_UDP_PORT,$DOT_PORT,$HTTP_PORT,$HTTPS_PORT"

if [ -z "$ALLOWED_IPS" ]; then
  echo " >> apply-acl: ERROR ALLOWED_IPS is empty; refusing to expose DNS/DoT/SNI proxy without a whitelist" >&2
  exit 1
fi

# Normalize list
list="$(printf '%s' "$ALLOWED_IPS" | tr ',' ' ' | xargs)"

apply_nft() {
  command -v nft >/dev/null 2>&1 || return 1
  nft list table inet "$ACL_TABLE" >/dev/null 2>&1 && nft delete table inet "$ACL_TABLE" || true
  nft add table inet "$ACL_TABLE"
  nft add chain inet "$ACL_TABLE" input '{ type filter hook input priority -10; policy accept; }'

  # Always allow loopback
  nft add rule inet "$ACL_TABLE" input iif lo accept

  # For unlock ports: accept whitelist, drop others
  for p in $(printf '%s' "$ports" | tr ',' ' '); do
    for ip in $list; do
      case "$ip" in
        *:*) # v6
          nft add rule inet "$ACL_TABLE" input ip6 saddr "$ip" tcp dport "$p" accept 2>/dev/null || true
          nft add rule inet "$ACL_TABLE" input ip6 saddr "$ip" udp dport "$p" accept 2>/dev/null || true
          ;;
        *)
          nft add rule inet "$ACL_TABLE" input ip saddr "$ip" tcp dport "$p" accept
          nft add rule inet "$ACL_TABLE" input ip saddr "$ip" udp dport "$p" accept
          ;;
      esac
    done
    nft add rule inet "$ACL_TABLE" input tcp dport "$p" drop
    nft add rule inet "$ACL_TABLE" input udp dport "$p" drop
  done
  echo " >> apply-acl: nftables table $ACL_TABLE applied for ports $ports"
  return 0
}

apply_iptables() {
  command -v iptables >/dev/null 2>&1 || return 1
  # Clean previous chain
  iptables -D INPUT -j UNLOCK_ACL 2>/dev/null || true
  iptables -F UNLOCK_ACL 2>/dev/null || true
  iptables -X UNLOCK_ACL 2>/dev/null || true
  iptables -N UNLOCK_ACL
  iptables -A UNLOCK_ACL -i lo -j ACCEPT
  for p in $(printf '%s' "$ports" | tr ',' ' '); do
    for ip in $list; do
      case "$ip" in
        *:*) continue ;; # skip v6 in iptables path
      esac
      iptables -A UNLOCK_ACL -p tcp --dport "$p" -s "$ip" -j ACCEPT
      iptables -A UNLOCK_ACL -p udp --dport "$p" -s "$ip" -j ACCEPT
    done
    iptables -A UNLOCK_ACL -p tcp --dport "$p" -j DROP
    iptables -A UNLOCK_ACL -p udp --dport "$p" -j DROP
  done
  iptables -I INPUT 1 -j UNLOCK_ACL
  echo " >> apply-acl: iptables chain UNLOCK_ACL applied for ports $ports"
  return 0
}

if apply_nft; then
  exit 0
fi
if apply_iptables; then
  exit 0
fi

echo " >> apply-acl: WARNING neither nft nor iptables available; ACL not enforced" >&2
exit 0
