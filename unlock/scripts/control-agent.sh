#!/bin/sh
# Optional center control client. No URL means exact legacy unlock behavior.
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
CONTROL_CENTER_URL="${CONTROL_CENTER_URL:-}"
CONTROL_TOKEN="${CONTROL_TOKEN:-}"
CONTROL_NODE_ID="${CONTROL_NODE_ID:-}"

log() { echo " >> [control-agent] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

case "${1:-start}" in
  env)
    [ -n "$CONTROL_CENTER_URL" ] || exit 0
    case "$CONTROL_CENTER_URL" in ws://*|wss://*) ;; *) fail "CONTROL_CENTER_URL must start with ws:// or wss://" ;; esac
    [ -n "$CONTROL_TOKEN" ] || fail "CONTROL_TOKEN is required when CONTROL_CENTER_URL is set"
    [ -n "$CONTROL_NODE_ID" ] || fail "CONTROL_NODE_ID is required when CONTROL_CENTER_URL is set"
    printf '%s' "$CONTROL_NODE_ID" | grep -Eq '^[A-Za-z0-9._-]{1,128}$' || fail "CONTROL_NODE_ID may only contain A-Z a-z 0-9 . _ -"
    python3 -c 'import websockets' >/dev/null 2>&1 || fail "python3-websockets is missing"
    ;;
  start)
    "$0" env
    [ -n "$CONTROL_CENTER_URL" ] || { log "control channel disabled (legacy ACL/DNS passthrough retained)"; exit 0; }
    mkdir -p "$RUNTIME_DIR"
    log "starting authenticated center control channel for node=$CONTROL_NODE_ID"
    python3 "$ROOT/scripts/control-agent.py" >"$RUNTIME_DIR/control-agent.log" 2>&1 &
    echo $! >"$RUNTIME_DIR/control-agent.pid"
    ;;
  *) fail "usage: $0 {env|start}" ;;
esac
