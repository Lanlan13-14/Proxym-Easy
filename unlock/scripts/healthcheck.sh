#!/bin/sh
set -eu

RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
DNS_UDP_PORT="${DNS_UDP_PORT:-53}"

alive() {
  [ -f "$1" ] || return 1
  pid="$(cat "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

alive "$RUNTIME_DIR/sniproxy.pid" || exit 1
alive "$RUNTIME_DIR/smartdns.pid" || exit 1

# Local DNS smoke test (A query for a known streaming domain if present)
if command -v dig >/dev/null 2>&1; then
  dig +time=2 +tries=1 @"127.0.0.1" -p "$DNS_UDP_PORT" netflix.com A +short >/dev/null 2>&1 || true
elif command -v nslookup >/dev/null 2>&1; then
  nslookup -port="$DNS_UDP_PORT" netflix.com 127.0.0.1 >/dev/null 2>&1 || true
fi

exit 0
