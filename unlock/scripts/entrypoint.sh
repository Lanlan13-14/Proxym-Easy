#!/bin/sh
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
export UNLOCK_ROOT CONF_DIR RUNTIME_DIR

mkdir -p "$CONF_DIR" "$RUNTIME_DIR" /var/log/unlock

log() { echo " >> [entrypoint] $*"; }

# DoT is TLS. Obtain/verify a real certificate before SmartDNS binds the DoT port.
# DNS-01 works without exposing HTTP-01 and supports a custom DoT port.
"$ROOT/scripts/cert-manager.sh" ensure

# Generate domain list + configs after certificate paths are known.
"$ROOT/scripts/gen-domains.sh"
"$ROOT/scripts/gen-configs.sh"

# Optional host ACL (needs NET_ADMIN / privileged when used)
if [ "${ENABLE_ACL:-1}" = "1" ] || [ "${ENABLE_ACL:-true}" = "true" ]; then
  "$ROOT/scripts/apply-acl.sh"
else
  log "WARNING: ACL disabled explicitly (ENABLE_ACL=$ENABLE_ACL)"
fi

# Start sniproxy
if command -v sniproxy >/dev/null 2>&1; then
  log "starting sniproxy"
  sniproxy -c "$CONF_DIR/sniproxy.conf" -f >"$RUNTIME_DIR/sniproxy.log" 2>&1 &
  echo $! >"$RUNTIME_DIR/sniproxy.pid"
else
  log "ERROR: sniproxy not found"
  exit 1
fi

# Start smartdns
if command -v smartdns >/dev/null 2>&1; then
  log "starting smartdns"
  # -R creates SmartDNS's monitor process. That process handles SIGHUP by
  # restarting its child, so a renewed certificate is loaded without downtime
  # beyond the restart. -f keeps the monitor attached to container logging.
  smartdns -R -c "$CONF_DIR/smartdns.conf" -f >"$RUNTIME_DIR/smartdns.log" 2>&1 &
  echo $! >"$RUNTIME_DIR/smartdns.pid"
  sleep 1
  if ! kill -0 "$(cat "$RUNTIME_DIR/smartdns.pid")" 2>/dev/null; then
    log "SmartDNS startup failed"
    tail -n 80 "$RUNTIME_DIR/smartdns.log" >&2 || true
    exit 1
  fi
else
  log "ERROR: smartdns not found"
  exit 1
fi

# Automatic Let's Encrypt renewal; certificate changes cause SmartDNS SIGHUP reload.
"$ROOT/scripts/cert-manager.sh" renew-loop >"$RUNTIME_DIR/cert-manager.log" 2>&1 &
echo $! >"$RUNTIME_DIR/cert-manager.pid"

# Zero Trust tunnel supervisor (optional)
if [ -f "$CONF_DIR/cloudflared-env" ] || [ "${ENABLE_ZT:-auto}" = "true" ] || [ "${ENABLE_ZT:-}" = "1" ]; then
  log "starting Zero Trust supervisor"
  "$ROOT/scripts/restart-zt.sh" >"$RUNTIME_DIR/restart-zt.log" 2>&1 &
  echo $! >"$RUNTIME_DIR/restart-zt.pid"
else
  log "Zero Trust tunnel not configured (set CF_TUNNEL_TOKEN to enable)"
fi

log "ready"
log "  DNS UDP : ${DNS_UDP_PORT:-53}"
log "  DoT     : ${DOT_PORT:-853}"
log "  HTTP    : 80 (fixed for transparent SNI unlock)"
log "  HTTPS   : 443 (fixed for transparent SNI unlock)"
log "  UNLOCK_IP=${UNLOCK_IP:-auto}"
log "  ALLOWED_IPS=${ALLOWED_IPS:-<open>}"

# Supervise children; exit if core services die
while true; do
  if [ -f "$RUNTIME_DIR/sniproxy.pid" ]; then
    spid="$(cat "$RUNTIME_DIR/sniproxy.pid")"
    if ! kill -0 "$spid" 2>/dev/null; then
      log "sniproxy died; restarting"
      sniproxy -c "$CONF_DIR/sniproxy.conf" -f >"$RUNTIME_DIR/sniproxy.log" 2>&1 &
      echo $! >"$RUNTIME_DIR/sniproxy.pid"
    fi
  fi
  if [ -f "$RUNTIME_DIR/smartdns.pid" ]; then
    dpid="$(cat "$RUNTIME_DIR/smartdns.pid")"
    if ! kill -0 "$dpid" 2>/dev/null; then
      log "smartdns died; restarting"
      smartdns -R -c "$CONF_DIR/smartdns.conf" -f >"$RUNTIME_DIR/smartdns.log" 2>&1 &
      echo $! >"$RUNTIME_DIR/smartdns.pid"
    fi
  fi
  sleep 5
done
