#!/bin/sh
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
DNS_UDP_PORT="${DNS_UDP_PORT:-53}"

alive() {
  [ -f "$1" ] || return 1
  pid="$(cat "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Core services + official Zero Trust WARP must all be healthy.
alive "$RUNTIME_DIR/sniproxy.pid"
alive "$RUNTIME_DIR/smartdns.pid"
case "${ENABLE_SOCKS5:-0}" in
    1|true|yes)
      alive "$RUNTIME_DIR/socks5d.pid"
      ;;
  esac
"$ROOT/scripts/warp-zt.sh" status

# Probe an existing local static rule, independently of public recursion.
probe_status=0
timeout -k 1 3 python3 "$ROOT/scripts/dns-health.py" || probe_status=$?
case "$probe_status" in
  0|2) exit 0 ;; # no applicable static rule: retain process/WARP checks above
  *) exit "$probe_status" ;;
esac
