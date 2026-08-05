#!/bin/sh
# Atomically update the center's client ACL and hot-push it to control nodes.
# Usage inside the center container:
#   update-allowed-ips.sh '198.51.100.0/24,2001:db8::/48'
set -eu

RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock-center}"
ACL_FILE="${CENTER_ALLOWED_IPS_FILE:-/etc/unlock-center/allowed-ips.txt}"
PID_FILE="${CENTER_PID_FILE:-$RUNTIME_DIR/unlock-center.pid}"
CIDRS="${1:-}"

log() { echo " >> [update-allowed-ips] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

[ -n "$CIDRS" ] || fail "usage: $0 '<cidr[,cidr...]>'"
printf '%s' "$CIDRS" | grep -Eq '^[0-9A-Fa-f:.,/[:space:]]+$' || fail "CIDRs contain unsupported characters"

candidate="$ACL_FILE.new"
printf '%s\n' "$CIDRS" >"$candidate"
chmod 600 "$candidate"
mv "$candidate" "$ACL_FILE"

[ -s "$PID_FILE" ] || fail "center pid file unavailable: $PID_FILE"
pid="$(cat "$PID_FILE")"
kill -0 "$pid" 2>/dev/null || fail "center pid is not running: $pid"
kill -HUP "$pid"
log "installed ACL snapshot and sent SIGHUP (pid=$pid)"
