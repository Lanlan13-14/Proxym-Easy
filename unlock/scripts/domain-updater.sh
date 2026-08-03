#!/bin/sh
# Pull the published domain list from a fixed URL and hot-reload SmartDNS/sniproxy.
# Designed to run as a long-lived supervisor inside the container (daily 04:00 by default).
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
DOMAINS_FILE="${DOMAINS_FILE:-$RUNTIME_DIR/domains.all.txt}"
BUNDLED_DOMAINS="${BUNDLED_DOMAINS:-$ROOT/domains/all.txt}"
DOMAIN_LIST_URL="${DOMAIN_LIST_URL:-https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock/domains/all.txt}"
ENABLE_DOMAIN_AUTO_UPDATE="${ENABLE_DOMAIN_AUTO_UPDATE:-1}"
DOMAIN_UPDATE_HOUR="${DOMAIN_UPDATE_HOUR:-4}"
DOMAIN_UPDATE_MINUTE="${DOMAIN_UPDATE_MINUTE:-0}"
DOMAIN_UPDATE_CHECK_SECONDS="${DOMAIN_UPDATE_CHECK_SECONDS:-60}"
MIN_DOMAIN_COUNT="${MIN_DOMAIN_COUNT:-800}"

log() { echo " >> [domain-updater] $*"; }

enabled() {
  case "${1:-}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

ensure_seed() {
  mkdir -p "$RUNTIME_DIR" "$(dirname "$DOMAINS_FILE")"
  if [ ! -f "$DOMAINS_FILE" ] || [ ! -s "$DOMAINS_FILE" ]; then
    if [ -f "$BUNDLED_DOMAINS" ]; then
      cp "$BUNDLED_DOMAINS" "$DOMAINS_FILE"
      log "seeded $DOMAINS_FILE from bundled list ($(wc -l <"$DOMAINS_FILE" | tr -d ' ') domains)"
    else
      echo "ERROR: no domain list available (missing $DOMAINS_FILE and $BUNDLED_DOMAINS)" >&2
      return 1
    fi
  fi
}

validate_list() {
  file="$1"
  [ -s "$file" ] || return 1
  count="$(grep -E '^[a-z0-9._-]+$' "$file" | wc -l | tr -d ' ')"
  [ "$count" -ge "$MIN_DOMAIN_COUNT" ] || {
    log "reject list: count=$count < min=$MIN_DOMAIN_COUNT"
    return 1
  }
  # Hard ban Google/YouTube family in published unlock lists.
  if grep -qiE '(^|\.)(google|googleapis|gstatic|youtube|ytimg)(\.|$)' "$file"; then
    log "reject list: contains google/youtube related domains"
    return 1
  fi
  # Must still cover major services.
  for must in netflix.com disneyplus.com bamgrid.com; do
    grep -qx "$must" "$file" || grep -qE "(^|\.)$must$" "$file" || {
      # bare suffix form is enough (disneyplus.com line)
      grep -qx "$must" "$file" || {
        log "reject list: missing required domain $must"
        return 1
      }
    }
  done
  return 0
}

fetch_remote() {
  dest="$1"
  [ -n "$DOMAIN_LIST_URL" ] || return 1
  tmp="$(mktemp "$RUNTIME_DIR/domains.fetch.XXXXXX")"
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
      -o "$tmp" "$DOMAIN_LIST_URL"; then
    rm -f "$tmp"
    return 1
  fi
  # Normalize whitespace/case for stability.
  tr 'A-Z' 'a-z' <"$tmp" \
    | sed -E 's/^\s+//; s/\s+$//; /^#/d; /^$/d' \
    | grep -E '^[a-z0-9._-]+$' \
    | grep -E '\.' \
    | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -u >"${tmp}.norm"
  rm -f "$tmp"
  if ! validate_list "${tmp}.norm"; then
    rm -f "${tmp}.norm"
    return 1
  fi
  mv "${tmp}.norm" "$dest"
  return 0
}

reload_services() {
  # Rebuild SmartDNS/sniproxy configs from the active domain file.
  export DOMAINS_FILE
  "$ROOT/scripts/gen-configs.sh"

  # SmartDNS supports SIGHUP reload of config.
  if [ -f "$RUNTIME_DIR/smartdns.pid" ]; then
    pid="$(cat "$RUNTIME_DIR/smartdns.pid")"
    if kill -0 "$pid" 2>/dev/null; then
      kill -HUP "$pid" 2>/dev/null || true
      log "sent SIGHUP to SmartDNS pid=$pid"
    fi
  fi

  # sniproxy has no reliable in-place reload for table changes — restart process.
  if [ -f "$RUNTIME_DIR/sniproxy.pid" ]; then
    old="$(cat "$RUNTIME_DIR/sniproxy.pid")"
    kill "$old" 2>/dev/null || true
    # wait up to ~5s for exit
    i=0
    while kill -0 "$old" 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -ge 50 ] && break
      sleep 0.1 2>/dev/null || sleep 1
    done
  fi
  sniproxy -c "$CONF_DIR/sniproxy.conf" -f >"$RUNTIME_DIR/sniproxy.log" 2>&1 &
  echo $! >"$RUNTIME_DIR/sniproxy.pid"
  sleep 1
  if ! kill -0 "$(cat "$RUNTIME_DIR/sniproxy.pid")" 2>/dev/null; then
    log "ERROR: sniproxy failed to restart after domain update"
    tail -n 40 "$RUNTIME_DIR/sniproxy.log" >&2 || true
    return 1
  fi
  log "sniproxy restarted pid=$(cat "$RUNTIME_DIR/sniproxy.pid")"
}

refresh_once() {
  ensure_seed
  if ! enabled "$ENABLE_DOMAIN_AUTO_UPDATE"; then
    log "auto-update disabled; using $(wc -l <"$DOMAINS_FILE" | tr -d ' ') local domains"
    return 0
  fi
  if [ -z "$DOMAIN_LIST_URL" ]; then
    log "DOMAIN_LIST_URL empty; skip remote refresh"
    return 0
  fi
  tmp_new="$RUNTIME_DIR/domains.all.next"
  if ! fetch_remote "$tmp_new"; then
    log "remote fetch failed; keep current list ($(wc -l <"$DOMAINS_FILE" | tr -d ' ') domains)"
    return 1
  fi
  new_count="$(wc -l <"$tmp_new" | tr -d ' ')"
  if [ -f "$DOMAINS_FILE" ] && cmp -s "$tmp_new" "$DOMAINS_FILE"; then
    rm -f "$tmp_new"
    log "remote list unchanged ($new_count domains)"
    return 0
  fi
  mv "$tmp_new" "$DOMAINS_FILE"
  log "updated domain list -> $new_count domains from $DOMAIN_LIST_URL"
  # Only reload if services are already running (boot path seeds before start).
  if [ -f "$RUNTIME_DIR/smartdns.pid" ] || [ -f "$RUNTIME_DIR/sniproxy.pid" ]; then
    reload_services
  fi
  return 0
}

seconds_until_next_hhmm() {
  hour="$1"
  minute="$2"
  # BusyBox date: use epoch math in python for portability.
  python3 - "$hour" "$minute" <<'PY'
import sys, datetime
hour = int(sys.argv[1]); minute = int(sys.argv[2])
now = datetime.datetime.now().astimezone()
target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if target <= now:
    target += datetime.timedelta(days=1)
print(int((target - now).total_seconds()))
PY
}

loop_daily() {
  ensure_seed
  if ! enabled "$ENABLE_DOMAIN_AUTO_UPDATE"; then
    log "auto-update disabled; supervisor idle"
    while true; do sleep 3600; done
  fi
  log "daily refresh armed for ${DOMAIN_UPDATE_HOUR}:$(printf '%02d' "$DOMAIN_UPDATE_MINUTE") (TZ=${TZ:-local}) url=$DOMAIN_LIST_URL"
  while true; do
    wait_s="$(seconds_until_next_hhmm "$DOMAIN_UPDATE_HOUR" "$DOMAIN_UPDATE_MINUTE")"
    log "sleeping ${wait_s}s until next domain refresh"
    # Sleep in chunks so container signals / restarts stay responsive.
    left="$wait_s"
    while [ "$left" -gt 0 ]; do
      chunk="$DOMAIN_UPDATE_CHECK_SECONDS"
      [ "$left" -lt "$chunk" ] && chunk="$left"
      sleep "$chunk"
      left=$((left - chunk))
    done
    refresh_once || true
  done
}

cmd="${1:-loop}"
case "$cmd" in
  once|refresh)
    refresh_once
    ;;
  seed)
    ensure_seed
    ;;
  loop|supervise)
    loop_daily
    ;;
  *)
    echo "Usage: $0 {once|seed|loop}" >&2
    exit 2
    ;;
esac
