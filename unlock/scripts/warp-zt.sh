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

fix_return_routes() {
  # Besides external clients, preserve the container's attached Docker subnet;
  # otherwise WARP's policy routing can break host->published-port replies.
  routes="$ALLOWED_IPS"
  docker_cidr="$(ip -4 route show dev eth0 proto kernel 2>/dev/null | awk 'NR==1{print $1}')"
  [ -z "$docker_cidr" ] || routes="$routes,$docker_cidr"

  oldifs="$IFS"; IFS=','
  for cidr in $routes; do
    cidr="$(printf '%s' "$cidr" | tr -d ' ')"; [ -n "$cidr" ] || continue
    case "$cidr" in
      *:*)
        ip -6 rule list | grep -Fq "to $cidr lookup main" || ip -6 rule add to "$cidr" lookup main priority 10
        if nft list table inet cloudflare-warp >/dev/null 2>&1; then
          nft list table inet cloudflare-warp | grep -Fq "ip6 saddr $cidr accept" || nft add rule inet cloudflare-warp input ip6 saddr "$cidr" accept
          nft list table inet cloudflare-warp | grep -Fq "ip6 daddr $cidr accept" || nft add rule inet cloudflare-warp output ip6 daddr "$cidr" accept
        fi
        ;;
      *)
        ip rule list | grep -Fq "to $cidr lookup main" || ip rule add to "$cidr" lookup main priority 10
        if nft list table inet cloudflare-warp >/dev/null 2>&1; then
          nft list table inet cloudflare-warp | grep -Fq "ip saddr $cidr accept" || nft add rule inet cloudflare-warp input ip saddr "$cidr" accept
          nft list table inet cloudflare-warp | grep -Fq "ip daddr $cidr accept" || nft add rule inet cloudflare-warp output ip daddr "$cidr" accept
        fi
        ;;
    esac
  done
  IFS="$oldifs"
}

trace_request() {
  # Pin the validation hostname to Cloudflare IPs so the fail-closed check does
  # not depend on warp-svc changing /etc/resolv.conf inside Docker.
  curl -4fsS --max-time 20 \
    --resolve www.cloudflare.com:443:104.16.123.96 \
    --resolve www.cloudflare.com:443:104.16.124.96 \
    https://www.cloudflare.com/cdn-cgi/trace
}

verify_path() {
  trace="$(trace_request)" || fail "WARP egress trace failed"
  printf '%s\n' "$trace" > "$RUNTIME_DIR/warp-trace.log"
  printf '%s\n' "$trace" | grep -q '^warp=on$' || fail "traffic is not exiting through WARP"
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
      && trace_request | grep -q '^warp=on$'
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
