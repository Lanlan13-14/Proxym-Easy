#!/bin/sh
# Official Cloudflare One Client in Zero Trust Traffic-only mode.
set -eu

RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
WARP_DIR="${WARP_DIR:-/var/lib/cloudflare-warp}"
ORG="${WARP_ORGANIZATION:-}"
CLIENT_ID="${WARP_CLIENT_ID:-}"
CLIENT_SECRET="${WARP_CLIENT_SECRET:-}"
RESTART_HOURS="${ZT_RESTART_HOURS:-12}"
REGISTER_TIMEOUT="${WARP_REGISTER_TIMEOUT:-240}"
CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-120}"
ALLOWED_IPS="${ALLOWED_IPS:-}"

log() { echo " >> [warp-zt] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

validate_env() {
  [ -n "$ORG" ] || fail "WARP_ORGANIZATION is required"
  [ -n "$CLIENT_ID" ] || fail "WARP_CLIENT_ID is required"
  [ -n "$CLIENT_SECRET" ] || fail "WARP_CLIENT_SECRET is required"
  [ -n "$ALLOWED_IPS" ] || fail "ALLOWED_IPS is required for return-route exclusions"
}

write_mdm() {
  mkdir -p "$WARP_DIR" "$RUNTIME_DIR"
  cat > "$WARP_DIR/mdm.xml" <<EOF
<dict>
  <key>organization</key><string>$ORG</string>
  <key>auth_client_id</key><string>$CLIENT_ID</string>
  <key>auth_client_secret</key><string>$CLIENT_SECRET</string>
  <key>service_mode</key><string>tunnelonly</string>
  <key>warp_tunnel_protocol</key><string>masque</string>
  <key>onboarding</key><false/>
  <key>auto_connect</key><integer>0</integer>
  <key>switch_locked</key><true/>
</dict>
EOF
  chmod 600 "$WARP_DIR/mdm.xml"
}

stop_svc() {
  if [ -f "$RUNTIME_DIR/warp-svc.pid" ]; then
    pid="$(cat "$RUNTIME_DIR/warp-svc.pid" 2>/dev/null || true)"
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  fi
  pkill -x warp-svc 2>/dev/null || true
  rm -f "$RUNTIME_DIR/warp-svc.pid" "$RUNTIME_DIR/warp-ready"
}

start_dbus() {
  mkdir -p /dev/net /run/dbus
  if [ ! -e /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
  fi
  rm -f /run/dbus/pid
  pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --config-file=/usr/share/dbus-1/system.conf
}

start_svc() {
  start_dbus
  log "starting official warp-svc"
  warp-svc --accept-tos >"$RUNTIME_DIR/warp-svc.log" 2>&1 &
  echo $! > "$RUNTIME_DIR/warp-svc.pid"
  i=0
  while [ "$i" -lt 40 ]; do
    warp-cli --accept-tos status >/dev/null 2>&1 && return 0
    kill -0 "$(cat "$RUNTIME_DIR/warp-svc.pid")" 2>/dev/null || break
    i=$((i + 1)); sleep 1
  done
  tail -n 80 "$RUNTIME_DIR/warp-svc.log" >&2 || true
  fail "warp-svc IPC did not become ready"
}

wait_registration() {
  log "waiting for Service Token enrollment into $ORG"
  i=0; stale_deleted=0
  while [ "$i" -lt "$REGISTER_TIMEOUT" ]; do
    if warp-cli --accept-tos registration show >"$RUNTIME_DIR/warp-registration.log" 2>&1; then
      if grep -Eqi 'Auth Method:[[:space:]]*Consumer|Account type:[[:space:]]*Free' "$RUNTIME_DIR/warp-registration.log"; then
        if [ "$stale_deleted" = "0" ]; then
          log "consumer WARP registration detected; deleting stale registration"
          warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
          rm -f "$WARP_DIR/reg.json"
          stale_deleted=1
          i=$((i + 1)); sleep 2; continue
        fi
        fail "consumer registration returned after cleanup; refusing non-Zero-Trust fallback"
      fi
      settings="$(warp-cli --accept-tos settings list 2>&1 || warp-cli --accept-tos settings 2>&1 || true)"
      printf '%s\n' "$settings" > "$RUNTIME_DIR/warp-settings.log"
      if printf '%s\n' "$settings" | grep -Eqi 'Include mode, with hosts/ips|Split Tunnels[^:]*:[[:space:]]*Include'; then
        printf '%s\n' "$settings" >&2
        fail "Zero Trust device profile uses Split Tunnel Include mode; switch this Service Token profile to Exclude mode so Internet/streaming traffic enters WARP"
      fi
      # Registration and MDM settings are asynchronous. Wait until BOTH the
      # organization and Traffic-only mode are visible instead of failing on
      # the first partially-loaded registration response.
      if printf '%s\n%s\n' "$(cat "$RUNTIME_DIR/warp-registration.log")" "$settings" | grep -Fqi "$ORG" \
        && printf '%s\n' "$settings" | grep -Eqi 'tunnel[_ -]?only|Traffic only'; then
        return 0
      fi
    fi
    i=$((i + 1)); sleep 1
  done
  tail -n 100 "$RUNTIME_DIR/warp-registration.log" >&2 2>/dev/null || true
  tail -n 100 "$RUNTIME_DIR/warp-settings.log" >&2 2>/dev/null || true
  tail -n 100 "$RUNTIME_DIR/warp-svc.log" >&2 || true
  fail "registration exists but is not bound to Zero Trust organization $ORG in Traffic-only mode"
}

wait_connected() {
  warp-cli --accept-tos connect >/dev/null
  i=0
  while [ "$i" -lt "$CONNECT_TIMEOUT" ]; do
    status="$(warp-cli --accept-tos status 2>&1 || true)"
    printf '%s\n' "$status" > "$RUNTIME_DIR/warp-status.log"
    printf '%s\n' "$status" | grep -qi 'Connected' && return 0
    i=$((i + 1)); sleep 1
  done
  fail "WARP did not reach Connected state"
}

ensure_nft_accept() {
  # WARP installs a late drop in inet cloudflare-warp. `nft add` appends after
  # that drop and never matches. Always insert at the head of the chain.
  family="$1"; chain="$2"; expr="$3"
  if ! nft list chain inet cloudflare-warp "$chain" 2>/dev/null | grep -Fq "$expr"; then
    nft insert rule inet cloudflare-warp "$chain" $expr
  fi
}

RETURN_MARK="${RETURN_MARK:-0x4d01}"
RETURN_TABLE="unlock_return"

ensure_marked_main_rule() {
  # A destination-CIDR rule works only for finite client CIDRs. With 0.0.0.0/0
  # it would send every new connection through main and bypass WARP. Instead,
  # route only packets marked as replies to connections accepted on public ports.
  ip rule list | grep -Fq "fwmark $RETURN_MARK lookup main" \
    || ip rule add fwmark "$RETURN_MARK" lookup main priority 9 \
    || ip rule list | grep -Fq "fwmark $RETURN_MARK lookup main" \
    || fail "cannot add marked IPv4 return route"
  ip -6 rule list | grep -Fq "fwmark $RETURN_MARK lookup main" \
    || ip -6 rule add fwmark "$RETURN_MARK" lookup main priority 9 \
    || ip -6 rule list | grep -Fq "fwmark $RETURN_MARK lookup main" \
    || fail "cannot add marked IPv6 return route"
}

fix_return_routes() {
  # Mark only inbound service connections, persist the mark in conntrack, then
  # restore it in local OUTPUT. `type route` re-runs policy routing after the
  # mark is restored, so replies leave eth0/main while new outbound traffic
  # continues to use CloudflareWARP. This works safely for /32, subnets, and /0.
  socks_port=""
  case "${ENABLE_SOCKS5:-0}" in
    1|true|yes) socks_port=", ${SOCKS5_PORT:-1080}" ;;
  esac
  # Only mark ports that actually listen. Disabled DNS/DoT/DoH must not open
  # return-path holes for unused ports. Plain DNS is public only when ENABLE_DNS=1.
  extra_tcp=""
  extra_udp=""
  case "${ENABLE_DNS:-0}" in
    1|true|yes)
      extra_tcp="${extra_tcp}, ${DNS_UDP_PORT:-53}"
      extra_udp="${DNS_UDP_PORT:-53}"
      ;;
  esac
  case "${ENABLE_DOT:-1}" in
    1|true|yes) extra_tcp="${extra_tcp}, ${DOT_PORT:-853}" ;;
  esac
  case "${ENABLE_DOH:-1}" in
    1|true|yes) extra_tcp="${extra_tcp}, ${DOH_PORT:-4430}" ;;
  esac
  tcp_ports="80, 443${extra_tcp}${socks_port}"

  nft delete table inet "$RETURN_TABLE" 2>/dev/null || true
  nft add table inet "$RETURN_TABLE"
  nft "add chain inet $RETURN_TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
  nft "add chain inet $RETURN_TABLE output { type route hook output priority mangle; policy accept; }"
  nft add rule inet "$RETURN_TABLE" prerouting iifname eth0 tcp dport "{ $tcp_ports }" ct mark set "$RETURN_MARK"
  if [ -n "$extra_udp" ]; then
    nft add rule inet "$RETURN_TABLE" prerouting iifname eth0 udp dport "$extra_udp" ct mark set "$RETURN_MARK"
  fi
  nft add rule inet "$RETURN_TABLE" output ct mark "$RETURN_MARK" meta mark set "$RETURN_MARK"

  ensure_marked_main_rule
  if nft list table inet cloudflare-warp >/dev/null 2>&1; then
    ensure_nft_accept inet input "ct mark $RETURN_MARK accept"
    ensure_nft_accept inet output "meta mark $RETURN_MARK accept"
  fi
  log "preserved marked service reply paths for any DNS/SNI/SOCKS ACL CIDR"
}

trace_request() {
  # This is the canonical WARP check used by mature warp-svc containers.
  # Fall back to the literal 1.1.1.1 endpoint if container DNS is temporarily
  # unavailable while WARP applies Traffic-only settings.
  curl -4fsS --max-time 20 https://cloudflare.com/cdn-cgi/trace \
    || curl -4fsS --max-time 20 https://1.1.1.1/cdn-cgi/trace
}

dump_diagnostics() {
  echo "--- warp registration ---" >&2
  warp-cli --accept-tos registration show >&2 2>&1 || true
  echo "--- warp settings ---" >&2
  warp-cli --accept-tos settings list >&2 2>&1 || warp-cli --accept-tos settings >&2 2>&1 || true
  echo "--- warp status ---" >&2
  warp-cli --accept-tos status >&2 2>&1 || true
  echo "--- trace ---" >&2
  cat "$RUNTIME_DIR/warp-trace.log" >&2 2>/dev/null || true
  echo "--- IPv4 routes/rules ---" >&2
  ip -4 route show table all >&2 2>&1 || true
  ip -4 rule show >&2 2>&1 || true
  echo "--- warp-svc tail ---" >&2
  tail -n 100 "$RUNTIME_DIR/warp-svc.log" >&2 2>/dev/null || true
}

verify_path() {
  trace="$(trace_request)" || { dump_diagnostics; fail "WARP egress trace failed"; }
  printf '%s\n' "$trace" > "$RUNTIME_DIR/warp-trace.log"
  printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' \
    || { dump_diagnostics; fail "traffic is not exiting through WARP (trace warp is off)"; }
  touch "$RUNTIME_DIR/warp-ready"
  log "Zero Trust WARP ready (tunnelonly, organization=$ORG)"
}

start_all() {
  validate_env
  rm -f "$RUNTIME_DIR/warp-ready" "$RUNTIME_DIR/warp-restart-required"
  write_mdm; stop_svc; start_svc; wait_registration; wait_connected
  fix_return_routes; verify_path
}

case "${1:-}" in
  start|restart) start_all ;;
  status)
    [ -f "$RUNTIME_DIR/warp-ready" ] \
      && pgrep -x warp-svc >/dev/null 2>&1 \
      && warp-cli --accept-tos status 2>/dev/null | grep -qi Connected \
      && trace_request | grep -Eq '^warp=(on|plus)$'
    ;;
  supervise)
    secs=$((RESTART_HOURS * 3600)); [ "$secs" -ge 300 ] || secs=300
    log "scheduled Zero Trust restart in ${secs}s"
    sleep "$secs"
    log "scheduled Zero Trust restart requested"
    touch "$RUNTIME_DIR/warp-restart-required"
    ;;

  stop) stop_svc ;;
  *) fail "usage: $0 {start|restart|status|supervise|stop}" ;;
esac
