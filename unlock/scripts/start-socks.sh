#!/bin/sh
# Optional authenticated SOCKS5 service, pinned to the verified WARP interface.
# Auth is RFC1929 user/pass implemented by unlock-socks5d (not Linux accounts).
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
ENABLE_SOCKS5="${ENABLE_SOCKS5:-0}"
SOCKS5_PORT="${SOCKS5_PORT:-1080}"
SOCKS5_USERNAME="${SOCKS5_USERNAME:-}"
SOCKS5_PASSWORD="${SOCKS5_PASSWORD:-}"
SOCKS5_ALLOWED_IPS="${SOCKS5_ALLOWED_IPS:-}"
SOCKS5_EXTERNAL_INTERFACE="${SOCKS5_EXTERNAL_INTERFACE:-CloudflareWARP}"
SOCKS5_EXTERNAL_IP="${SOCKS5_EXTERNAL_IP:-}"
SOCKS5D_BIN="${SOCKS5D_BIN:-unlock-socks5d}"
PID_FILE="${RUNTIME_DIR}/socks5d.pid"
LOG_FILE="${RUNTIME_DIR}/socks5d.log"

log() { echo " >> [socks] $*"; }
fail() { echo " >> [socks] ERROR: $*" >&2; exit 1; }

is_enabled() {
  case "$ENABLE_SOCKS5" in 1|true|yes) return 0 ;; 0|false|no|'') return 1 ;; *) fail "ENABLE_SOCKS5 must be 0 or 1" ;; esac
}

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

byte_len() {
  # Byte length of a string (UTF-8 multi-byte counts as multiple).
  printf '%s' "$1" | wc -c | tr -d ' '
}

normalize_cred() {
  # Strip only CR (Windows .env paste). Do NOT strip spaces — they are valid.
  printf '%s' "$1" | tr -d '\r'
}

validate_env() {
  SOCKS5_USERNAME="$(normalize_cred "$SOCKS5_USERNAME")"
  SOCKS5_PASSWORD="$(normalize_cred "$SOCKS5_PASSWORD")"
  export SOCKS5_USERNAME SOCKS5_PASSWORD

  valid_port "$SOCKS5_PORT" || fail "invalid SOCKS5_PORT: $SOCKS5_PORT"
  case "$SOCKS5_PORT" in 53|80|443|"${DOT_PORT:-853}") fail "SOCKS5_PORT conflicts with DNS/DoT/SNI service" ;; esac
  [ -n "$SOCKS5_ALLOWED_IPS" ] || fail "SOCKS5_ALLOWED_IPS is required when SOCKS is enabled (it does not inherit ALLOWED_IPS)"

  ulen="$(byte_len "$SOCKS5_USERNAME")"
  plen="$(byte_len "$SOCKS5_PASSWORD")"
  [ "$ulen" -ge 1 ] || fail "SOCKS5_USERNAME is empty; any 1-255 byte string is allowed"
  [ "$ulen" -le 255 ] || fail "SOCKS5_USERNAME is $ulen bytes; RFC1929 max is 255"
  [ "$plen" -ge 1 ] || fail "SOCKS5_PASSWORD is empty; any 1-255 byte string is allowed"
  [ "$plen" -le 255 ] || fail "SOCKS5_PASSWORD is $plen bytes; RFC1929 max is 255"
  # Reject newlines (BusyBox case + $'\0' is unreliable for UTF-8; use tr).
  # Embedded NUL cannot appear in shell env vars / docker compose interpolation.
  [ "$(printf '%s' "$SOCKS5_USERNAME" | tr -d '\n' | wc -c | tr -d ' ')" -eq "$ulen" ] \
    || fail "SOCKS5_USERNAME must not contain newline"
  [ "$(printf '%s' "$SOCKS5_PASSWORD" | tr -d '\n' | wc -c | tr -d ' ')" -eq "$plen" ] \
    || fail "SOCKS5_PASSWORD must not contain newline"

  [ -n "$SOCKS5_EXTERNAL_INTERFACE" ] || fail "SOCKS5_EXTERNAL_INTERFACE is required"
}

validate_runtime() {
  if [ -z "$SOCKS5_EXTERNAL_IP" ]; then
    ip link show "$SOCKS5_EXTERNAL_INTERFACE" >/dev/null 2>&1 || fail "$SOCKS5_EXTERNAL_INTERFACE interface is unavailable"
    SOCKS5_EXTERNAL_IP="$(ip -4 -o addr show dev "$SOCKS5_EXTERNAL_INTERFACE" | awk 'NR==1{sub(/\/.*/, "", $4); print $4}')"
  fi
  printf '%s' "$SOCKS5_EXTERNAL_IP" | grep -Eq '^[0-9]+(\.[0-9]+){3}$' || fail "SOCKS5_EXTERNAL_IP must be an IPv4 address"
}

validate() {
  validate_env
  validate_runtime
}

resolve_bin() {
  if command -v "$SOCKS5D_BIN" >/dev/null 2>&1; then
    command -v "$SOCKS5D_BIN"
    return
  fi
  if [ -x "$ROOT/scripts/unlock-socks5d" ]; then
    echo "$ROOT/scripts/unlock-socks5d"
    return
  fi
  if [ -x "$ROOT/bin/unlock-socks5d" ]; then
    echo "$ROOT/bin/unlock-socks5d"
    return
  fi
  fail "unlock-socks5d binary missing (build step should install it to /usr/local/bin)"
}

case "${1:-start}" in
  env)
    is_enabled || exit 0
    validate_env
    log "SOCKS5 env ok (user_bytes=$(byte_len "$SOCKS5_USERNAME") pass_bytes=$(byte_len "$SOCKS5_PASSWORD") port=$SOCKS5_PORT)"
    ;;
  config)
    is_enabled || exit 0
    validate
    log "SOCKS5 config ok (bind=$SOCKS5_EXTERNAL_IP port=$SOCKS5_PORT)"
    ;;
  start)
    is_enabled || { log "disabled"; exit 0; }
    validate
    bin="$(resolve_bin)"
    mkdir -p "$RUNTIME_DIR" "$CONF_DIR"
    # Credentials stay in environment only — never argv, never config file.
    export SOCKS5_USERNAME SOCKS5_PASSWORD
    log "starting SOCKS5 TCP on $SOCKS5_PORT; external=$SOCKS5_EXTERNAL_IP ($SOCKS5_EXTERNAL_INTERFACE); free-charset RFC1929 auth"
    "$bin" --port "$SOCKS5_PORT" --bind-ip "$SOCKS5_EXTERNAL_IP" >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null || { tail -n 100 "$LOG_FILE" >&2 || true; fail "unlock-socks5d exited during startup"; }
    ss -lnt | grep -Eq ":${SOCKS5_PORT}[[:space:]]" || { tail -n 100 "$LOG_FILE" >&2 || true; fail "unlock-socks5d is not listening on TCP $SOCKS5_PORT"; }
    log "SOCKS5 ready (separate ACL=$SOCKS5_ALLOWED_IPS)"
    ;;
  *) fail "usage: $0 [env|config|start]" ;;
esac
