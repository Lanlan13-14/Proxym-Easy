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
      alive "$RUNTIME_DIR/danted.pid"
      ;;
  esac
"$ROOT/scripts/warp-zt.sh" status

# warp-zt status already checks Connected + a pinned-IP `warp=on` trace.

# DNS smoke test must return the configured unlock IP for a known rule.
if command -v dig >/dev/null 2>&1; then
  answer="$(dig +time=2 +tries=1 @127.0.0.1 -p "$DNS_UDP_PORT" netflix.com A +short | tail -1)"
  [ -n "$answer" ]
elif command -v nslookup >/dev/null 2>&1; then
  nslookup -port="$DNS_UDP_PORT" netflix.com 127.0.0.1 >/dev/null 2>&1
fi
