#!/bin/sh
# Download / refresh City MMDB for unlock-center nearest scheduling.
# Supports:
#   - GEOIP_DB_URL direct .mmdb or .mmdb.gz
#   - MAXMIND_LICENSE_KEY → official GeoLite2-City tar.gz
# Schedule: GEOIP_UPDATE_HOUR / GEOIP_UPDATE_MINUTE (local TZ, default 04:00)
set -eu

DATA_DIR="${DATA_DIR:-/data}"
GEOIP_DB_PATH="${GEOIP_DB_PATH:-$DATA_DIR/geoip/GeoLite2-City.mmdb}"
GEOIP_ENABLE_AUTO_UPDATE="${GEOIP_ENABLE_AUTO_UPDATE:-1}"
GEOIP_UPDATE_HOUR="${GEOIP_UPDATE_HOUR:-4}"
GEOIP_UPDATE_MINUTE="${GEOIP_UPDATE_MINUTE:-0}"
# Built-in default City MMDB (no license key required). Override with GEOIP_DB_URL
# or MAXMIND_LICENSE_KEY if you prefer official MaxMind.
GEOIP_BUILTIN_URL="https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"
GEOIP_DB_URL="${GEOIP_DB_URL:-$GEOIP_BUILTIN_URL}"
MAXMIND_LICENSE_KEY="${MAXMIND_LICENSE_KEY:-}"
MAXMIND_EDITION_ID="${MAXMIND_EDITION_ID:-GeoLite2-City}"
CENTER_PID_FILE="${CENTER_PID_FILE:-/run/unlock-center/unlock-center.pid}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock-center}"

log() { echo " >> [geoip-updater] $*"; }

enabled() {
  case "${1:-}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

notify_center() {
  if [ -f "$CENTER_PID_FILE" ]; then
    pid="$(cat "$CENTER_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      # USR1 = reload geoip (also HUP reloads TLS; send USR1 for geo only)
      kill -USR1 "$pid" 2>/dev/null || kill -HUP "$pid" 2>/dev/null || true
      log "notified unlock-center pid=$pid to reload geoip"
    fi
  fi
}

download_once() {
  mkdir -p "$(dirname "$GEOIP_DB_PATH")" "$RUNTIME_DIR"
  tmp="$(mktemp "$RUNTIME_DIR/geoip.XXXXXX")"
  # Priority: MaxMind license (official) > GEOIP_DB_URL (defaults to built-in).
  if [ -n "$MAXMIND_LICENSE_KEY" ]; then
    url="https://download.maxmind.com/app/geoip_download?edition_id=${MAXMIND_EDITION_ID}&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz"
  else
    url="$GEOIP_DB_URL"
  fi
  [ -n "$url" ] || url="$GEOIP_BUILTIN_URL"

  log "downloading: $url"
  if ! curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -o "$tmp" "$url"; then
    rm -f "$tmp"
    log "ERROR: download failed"
    return 1
  fi

  # Detect format
  if gzip -t "$tmp" 2>/dev/null; then
    # could be .mmdb.gz or tar.gz
    if tar -tzf "$tmp" >/dev/null 2>&1; then
      extract_dir="$(mktemp -d "$RUNTIME_DIR/geoip-ex.XXXXXX")"
      tar -xzf "$tmp" -C "$extract_dir"
      mmdb="$(find "$extract_dir" -type f -name '*.mmdb' | head -n1)"
      [ -n "$mmdb" ] && [ -s "$mmdb" ] || { rm -rf "$extract_dir" "$tmp"; log "ERROR: no mmdb in tar.gz"; return 1; }
      mv -f "$mmdb" "$GEOIP_DB_PATH"
      rm -rf "$extract_dir" "$tmp"
    else
      gzip -dc "$tmp" >"${tmp}.out"
      mv -f "${tmp}.out" "$GEOIP_DB_PATH"
      rm -f "$tmp"
    fi
  else
    # plain mmdb
    mv -f "$tmp" "$GEOIP_DB_PATH"
  fi

  size="$(wc -c <"$GEOIP_DB_PATH" | tr -d ' ')"
  if [ "$size" -lt 1000000 ]; then
    log "ERROR: geoip file suspiciously small ($size bytes)"
    return 1
  fi
  log "installed $GEOIP_DB_PATH ($size bytes)"
  notify_center
  return 0
}

seconds_until_hhmm() {
  hour="$1"
  minute="$2"
  # BusyBox/date portable via python3
  python3 - "$hour" "$minute" <<'PY'
import sys, datetime
hour=int(sys.argv[1]); minute=int(sys.argv[2])
now=datetime.datetime.now().astimezone()
target=now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if target <= now:
    target += datetime.timedelta(days=1)
print(int((target-now).total_seconds()))
PY
}

cmd="${1:-loop}"
case "$cmd" in
  once|refresh)
    download_once
    ;;
  loop|supervise)
    if ! enabled "$GEOIP_ENABLE_AUTO_UPDATE"; then
      log "auto-update disabled; idle"
      while true; do sleep 3600; done
    fi
    # Boot: ensure file exists
    if [ ! -s "$GEOIP_DB_PATH" ]; then
      download_once || log "boot download failed; will retry on schedule"
    fi
    log "daily geoip update armed for ${GEOIP_UPDATE_HOUR}:$(printf '%02d' "$GEOIP_UPDATE_MINUTE") TZ=${TZ:-local}"
    while true; do
      wait_s="$(seconds_until_hhmm "$GEOIP_UPDATE_HOUR" "$GEOIP_UPDATE_MINUTE")"
      log "sleeping ${wait_s}s until next geoip refresh"
      left="$wait_s"
      while [ "$left" -gt 0 ]; do
        chunk=60
        [ "$left" -lt "$chunk" ] && chunk="$left"
        sleep "$chunk"
        left=$((left - chunk))
      done
      download_once || log "scheduled download failed"
    done
    ;;
  *)
    echo "Usage: $0 {once|loop}" >&2
    exit 2
    ;;
esac
