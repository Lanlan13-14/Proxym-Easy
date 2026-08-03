#!/bin/sh
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
export UNLOCK_ROOT CONF_DIR RUNTIME_DIR

mkdir -p "$CONF_DIR" "$RUNTIME_DIR" /var/log/unlock
log() { echo " >> [entrypoint] $*"; }

# DoT certificate first: DNS-01 does not depend on WARP or inbound 80/443.
"$ROOT/scripts/cert-manager.sh" ensure
"$ROOT/scripts/gen-domains.sh"
# Resolve public upstream names before WARP enters Traffic-only mode. SmartDNS
# then uses numeric endpoints and never depends on WARP changing /etc/resolv.conf.
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1,1.0.0.1,8.8.8.8}"
resolved_upstreams=""
oldifs="$IFS"; IFS=','
for upstream in $UPSTREAM_DNS; do
  upstream="$(printf '%s' "$upstream" | tr -d ' ')"; [ -n "$upstream" ] || continue
  host="$upstream"
  case "$upstream" in
    tls://*|https://*|quic://*)
      host="$(printf '%s' "$upstream" | sed -E 's@^[a-z]+://([^/:]+).*@\1@')"
      ;;
  esac
  case "$host" in
    *[!0-9.:]*)
      ip="$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')"
      [ -n "$ip" ] || { log "cannot resolve upstream $host"; exit 1; }
      upstream="$ip"
      ;;
  esac
  [ -z "$resolved_upstreams" ] && resolved_upstreams="$upstream" || resolved_upstreams="$resolved_upstreams,$upstream"
done
IFS="$oldifs"
UPSTREAM_DNS="$resolved_upstreams"; export UPSTREAM_DNS
"$ROOT/scripts/gen-configs.sh"

# White-list firewall is mandatory by default.
if [ "${ENABLE_ACL:-1}" = "1" ] || [ "${ENABLE_ACL:-true}" = "true" ]; then
  "$ROOT/scripts/apply-acl.sh"
else
  log "WARNING: ACL disabled explicitly (ENABLE_ACL=${ENABLE_ACL:-0})"
fi

# Validate optional SOCKS5 env early. A bad username/password must not thrash
# WARP enrollment + DNS/SNI just to die after sniproxy starts. Interface/IP
# checks still run later in start-socks.sh after WARP is up.
case "${ENABLE_SOCKS5:-0}" in
  1|true|yes)
    log "validating optional SOCKS5 configuration"
    "$ROOT/scripts/start-socks.sh" env
    ;;
esac

# Mandatory egress: official Cloudflare One Client, Service Token enrollment,
# Traffic-only mode. If this fails, no DNS/sniproxy service is started.
log "starting mandatory Cloudflare Zero Trust WARP egress"
"$ROOT/scripts/warp-zt.sh" start

# Start SmartDNS only after Zero Trust has been proven ready.
log "starting smartdns"
smartdns -R -c "$CONF_DIR/smartdns.conf" -f >"$RUNTIME_DIR/smartdns.log" 2>&1 &
echo $! >"$RUNTIME_DIR/smartdns.pid"
sleep 1
if ! kill -0 "$(cat "$RUNTIME_DIR/smartdns.pid")" 2>/dev/null; then
  tail -n 80 "$RUNTIME_DIR/smartdns.log" >&2 || true
  exit 1
fi

# Start sniproxy last. All destination connections now follow the WARP tunnel.
log "starting sniproxy behind Zero Trust WARP"
sniproxy -c "$CONF_DIR/sniproxy.conf" -f >"$RUNTIME_DIR/sniproxy.log" 2>&1 &
echo $! >"$RUNTIME_DIR/sniproxy.pid"
sleep 1
if ! kill -0 "$(cat "$RUNTIME_DIR/sniproxy.pid")" 2>/dev/null; then
  tail -n 80 "$RUNTIME_DIR/sniproxy.log" >&2 || true
  exit 1
fi

# Optional SOCKS5: separate source whitelist and username/password. It starts
# only after WARP has passed its mandatory egress validation.
"$ROOT/scripts/start-socks.sh" start

"$ROOT/scripts/cert-manager.sh" renew-loop >"$RUNTIME_DIR/cert-manager.log" 2>&1 &
echo $! >"$RUNTIME_DIR/cert-manager.pid"
"$ROOT/scripts/warp-zt.sh" supervise >"$RUNTIME_DIR/warp-supervisor.log" 2>&1 &
echo $! >"$RUNTIME_DIR/warp-supervisor.pid"

log "ready: DoT/DNS -> sniproxy -> Cloudflare Zero Trust WARP"
log "  organization=${WARP_ORGANIZATION}"
log "  DNS UDP/TCP=${DNS_UDP_PORT:-53} DoT=${DOT_PORT:-853}"
log "  HTTP=80 HTTPS=443 ALLOWED_IPS=${ALLOWED_IPS}"

# Fail closed: if WARP is no longer healthy, stop sniproxy immediately. The
# container restarts and does not silently fall back to direct VPS egress.
while true; do
  if [ -f "$RUNTIME_DIR/warp-restart-required" ]; then
    log "scheduled Zero Trust restart; stopping sniproxy and exiting"
    kill "$(cat "$RUNTIME_DIR/sniproxy.pid")" 2>/dev/null || true
    [ ! -f "$RUNTIME_DIR/socks5d.pid" ] || kill "$(cat "$RUNTIME_DIR/socks5d.pid")" 2>/dev/null || true
    exit 1
  fi
  "$ROOT/scripts/warp-zt.sh" status || {
    log "Zero Trust WARP unhealthy; stopping sniproxy/SOCKS and exiting"
    [ ! -f "$RUNTIME_DIR/sniproxy.pid" ] || kill "$(cat "$RUNTIME_DIR/sniproxy.pid")" 2>/dev/null || true
    [ ! -f "$RUNTIME_DIR/socks5d.pid" ] || kill "$(cat "$RUNTIME_DIR/socks5d.pid")" 2>/dev/null || true
    exit 1
  }
  for name in smartdns sniproxy; do
    pidfile="$RUNTIME_DIR/$name.pid"
    [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null || {
      log "$name died; exiting for clean container restart"
      exit 1
    }
  done
  case "${ENABLE_SOCKS5:-0}" in
    1|true|yes)
      [ -f "$RUNTIME_DIR/socks5d.pid" ] && kill -0 "$(cat "$RUNTIME_DIR/socks5d.pid")" 2>/dev/null || {
        log "SOCKS5 unlock-socks5d died; exiting for clean container restart"
        exit 1
      }
      ;;
  esac
  sleep 10
done
