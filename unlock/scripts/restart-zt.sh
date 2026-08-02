#!/bin/sh
# Periodically restart Cloudflare Zero Trust tunnel (cloudflared).
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
INTERVAL_HOURS="${ZT_RESTART_HOURS:-12}"
ENABLE_ZT="${ENABLE_ZT:-auto}"

log() { echo " >> [restart-zt] $*"; }

cloudflared_running() {
  pgrep -x cloudflared >/dev/null 2>&1
}

start_cloudflared() {
  if [ ! -f "$CONF_DIR/cloudflared-env" ]; then
    log "no cloudflared-env; skip"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$CONF_DIR/cloudflared-env"
  if [ -z "${TUNNEL_TOKEN:-}" ]; then
    log "empty TUNNEL_TOKEN; skip"
    return 1
  fi
  log "starting cloudflared"
  # Run in background; logs to stdout via container logging.
  cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" \
    >"$RUNTIME_DIR/cloudflared.log" 2>&1 &
  echo $! >"$RUNTIME_DIR/cloudflared.pid"
  sleep 2
  if cloudflared_running; then
    log "cloudflared started pid=$(cat "$RUNTIME_DIR/cloudflared.pid")"
    return 0
  fi
  log "cloudflared failed to start; last log:"
  tail -n 30 "$RUNTIME_DIR/cloudflared.log" 2>/dev/null || true
  return 1
}

stop_cloudflared() {
  if [ -f "$RUNTIME_DIR/cloudflared.pid" ]; then
    pid="$(cat "$RUNTIME_DIR/cloudflared.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "stopping cloudflared pid=$pid"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$RUNTIME_DIR/cloudflared.pid"
  fi
  pkill -x cloudflared 2>/dev/null || true
}

should_enable() {
  case "$ENABLE_ZT" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
    auto|*)
      [ -f "$CONF_DIR/cloudflared-env" ]
      ;;
  esac
}

if ! should_enable; then
  log "Zero Trust disabled (ENABLE_ZT=$ENABLE_ZT)"
  exit 0
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  log "cloudflared binary not found"
  exit 1
fi

# Initial start
stop_cloudflared || true
start_cloudflared || true

# Interval loop (hours -> seconds)
secs=$((INTERVAL_HOURS * 3600))
if [ "$secs" -lt 300 ]; then
  secs=300
fi
log "restart interval ${INTERVAL_HOURS}h (${secs}s)"

while true; do
  sleep "$secs"
  log "scheduled restart"
  stop_cloudflared || true
  start_cloudflared || true
done
