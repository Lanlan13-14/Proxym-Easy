#!/bin/sh
set -eu

ROOT="${UNLOCK_ROOT:-/opt/unlock}"
CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
export UNLOCK_ROOT CONF_DIR RUNTIME_DIR

mkdir -p "$CONF_DIR" "$RUNTIME_DIR" /var/log/unlock
log() { echo " >> [entrypoint] $*"; }

# DoT certificate first: DNS-01 does not depend on WARP or inbound 80/443.
"$ROOT/scripts/cert-manager.sh" ensure

# Domain list: seed runtime copy from image artifact, then optional remote pull.
# The published list is rebuilt daily by GitHub Actions from MetaCubeX geosite.
export DOMAINS_FILE="${DOMAINS_FILE:-$RUNTIME_DIR/domains.all.txt}"
export BUNDLED_DOMAINS="${BUNDLED_DOMAINS:-$ROOT/domains/all.txt}"
"$ROOT/scripts/domain-updater.sh" seed
# Best-effort boot refresh; failure keeps the bundled/seeded list.
"$ROOT/scripts/domain-updater.sh" once || log "boot domain refresh skipped/failed; continue with local list"
# Keep offline fallback generator available for empty/broken images.
if [ ! -s "$DOMAINS_FILE" ]; then
  DOMAIN_SOURCE=streamconfig DOMAINS_DIR="$RUNTIME_DIR" OUT_FILE="$DOMAINS_FILE" \
    "$ROOT/scripts/gen-domains.sh"
fi

# Resolve public upstream names before WARP enters Traffic-only mode. SmartDNS
# then uses numeric endpoints and never depends on WARP changing /etc/resolv.conf.
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1,1.0.0.1,8.8.8.8,9.9.9.9}"
resolved_upstreams=""
oldifs="$IFS"; IFS=','
for upstream in $UPSTREAM_DNS; do
  upstream="$(printf '%s' "$upstream" | tr -d ' ')"; [ -n "$upstream" ] || continue
  host="$upstream"
  case "$upstream" in
    tls://*|https://*|quic://*)
      host="$(printf '%s' "$upstream" | sed -E 's@^[a-z]+://([^/:]+).*@\1@')"
      ;;
  esac
  case "$host" in
    *[!0-9.:]*)
      ip="$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')"
      [ -n "$ip" ] || { log "cannot resolve upstream $host"; exit 1; }
      upstream="$ip"
      ;;
  esac
  [ -z "$resolved_upstreams" ] && resolved_upstreams="$upstream" || resolved_upstreams="$resolved_upstreams,$upstream"
done
IFS="$oldifs"
UPSTREAM_DNS="$resolved_upstreams"; export UPSTREAM_DNS
"$ROOT/scripts/gen-configs.sh"

# Validate optional center control configuration before touching nftables/WARP.
# An empty CONTROL_CENTER_URL deliberately preserves legacy standalone behavior.
"$ROOT/scripts/control-agent.sh" env

# White-list firewall is mandatory by default.
if [ "${ENABLE_ACL:-1}" = "1" ] || [ "${ENABLE_ACL:-true}" = "true" ]; then
  "$ROOT/scripts/apply-acl.sh"
else
  log "WARNING: ACL disabled explicitly (ENABLE_ACL=${ENABLE_ACL:-0})"
fi

# Validate optional SOCKS5 env early. A bad username/password must not thrash
# WARP enrollment + DNS/SNI just to die after sniproxy starts. Interface/IP
# checks still run later in start-socks.sh after WARP is up.
case "${ENABLE_SOCKS5:-0}" in
  1|true|yes)
    log "validating optional SOCKS5 configuration"
    "$ROOT/scripts/start-socks.sh" env
    ;;
esac

# Mandatory egress: official Cloudflare One Client, Service Token enrollment,
# Traffic-only mode. If this fails, no DNS/sniproxy service is started.
log "starting mandatory Cloudflare Zero Trust WARP egress"
"$ROOT/scripts/warp-zt.sh" start

# Start SmartDNS only after Zero Trust has been proven ready.
log "starting smartdns"
# Keep `smartdns -R` and its workers in a private process group; the PID
# remains stable for existing certificate reloads and health checks.
python3 "$ROOT/scripts/smartdns-process.py" start "$CONF_DIR/smartdns.conf" >"$RUNTIME_DIR/smartdns.log" 2>&1 &
echo $! >"$RUNTIME_DIR/smartdns.pid"
sleep 1
if ! kill -0 "$(cat "$RUNTIME_DIR/smartdns.pid")" 2>/dev/null; then
  tail -n 80 "$RUNTIME_DIR/smartdns.log" >&2 || true
  exit 1
fi

# Start sniproxy last. All destination connections now follow the WARP tunnel.
log "starting sniproxy behind Zero Trust WARP"
sniproxy -c "$CONF_DIR/sniproxy.conf" -f >"$RUNTIME_DIR/sniproxy.log" 2>&1 &
echo $! >"$RUNTIME_DIR/sniproxy.pid"
sleep 1
if ! kill -0 "$(cat "$RUNTIME_DIR/sniproxy.pid")" 2>/dev/null; then
  tail -n 80 "$RUNTIME_DIR/sniproxy.log" >&2 || true
  exit 1
fi

# Optional SOCKS5: separate source whitelist and username/password. It starts
# only after WARP has passed its mandatory egress validation.
"$ROOT/scripts/start-socks.sh" start

# One optional outbound WebSocket multiplexes center ACL hot-sync and
# center-selected `other` DNS passthrough. It uses the center's existing DoH
# port; a missing URL keeps the old independent behavior.
"$ROOT/scripts/control-agent.sh" start

"$ROOT/scripts/cert-manager.sh" renew-loop >"$RUNTIME_DIR/cert-manager.log" 2>&1 &
echo $! >"$RUNTIME_DIR/cert-manager.pid"
"$ROOT/scripts/warp-zt.sh" supervise >"$RUNTIME_DIR/warp-supervisor.log" 2>&1 &
echo $! >"$RUNTIME_DIR/warp-supervisor.pid"
"$ROOT/scripts/domain-updater.sh" loop >"$RUNTIME_DIR/domain-updater.log" 2>&1 &
echo $! >"$RUNTIME_DIR/domain-updater.pid"

log "ready: DNS/DoT/DoH -> sniproxy -> Cloudflare Zero Trust WARP"
log "  organization=${WARP_ORGANIZATION}"
dns_desc="loopback:${DNS_UDP_PORT:-53}"
dot_desc="off"
doh_desc="off"
case "${ENABLE_DNS:-0}" in 1|true|yes) dns_desc="public:${DNS_UDP_PORT:-53}" ;; esac
case "${ENABLE_DOT:-1}" in 1|true|yes) dot_desc="${DOT_PORT:-853}" ;; esac
case "${ENABLE_DOH:-1}" in 1|true|yes) doh_desc="${DOH_PORT:-4430}" ;; esac
log "  DNS=$dns_desc DoT=$dot_desc DoH=$doh_desc"
case "${ENABLE_DOH:-1}" in
  1|true|yes)
    log "  DoH URL=https://${DOT_DOMAIN}:${DOH_PORT:-4430}/dns-query"
    ;;
esac
log "  HTTP=80 HTTPS=443 ALLOWED_IPS=${ALLOWED_IPS}"

# Fail closed: if WARP is no longer healthy, stop sniproxy immediately. The
# container restarts and does not silently fall back to direct VPS egress.
# Container-local DNS recovery; no WARP re-enrollment, ACL/config rewrite or
# periodic restart. Three failed samples (10s apart) reject transient loss.
dns_failures=0
dns_recoveries=0
dns_probe_skipped=0
while true; do
  if [ -f "$RUNTIME_DIR/warp-restart-required" ]; then
    log "scheduled Zero Trust restart; stopping sniproxy and exiting"
    kill "$(cat "$RUNTIME_DIR/sniproxy.pid")" 2>/dev/null || true
    [ ! -f "$RUNTIME_DIR/socks5d.pid" ] || kill "$(cat "$RUNTIME_DIR/socks5d.pid")" 2>/dev/null || true
    exit 1
  fi
  if ! "$ROOT/scripts/warp-zt.sh" status; then
    # Preserve the original fail-closed policy. Do not introduce a grace period:
    # SOCKS workers are forked, so pausing only a listener PID is insufficient.
    log "Zero Trust WARP unhealthy; stopping sniproxy/SOCKS and exiting"
    [ ! -f "$RUNTIME_DIR/sniproxy.pid" ] || kill "$(cat "$RUNTIME_DIR/sniproxy.pid")" 2>/dev/null || true
    [ ! -f "$RUNTIME_DIR/socks5d.pid" ] || kill "$(cat "$RUNTIME_DIR/socks5d.pid")" 2>/dev/null || true
    exit 1
  fi
  for name in smartdns sniproxy; do
    pidfile="$RUNTIME_DIR/$name.pid"
    [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null || {
      log "$name died; exiting for clean container restart"
      exit 1
    }
  done
  probe_status=0
  timeout -k 1 3 python3 "$ROOT/scripts/dns-health.py" >/dev/null 2>&1 || probe_status=$?
  if [ "$probe_status" -eq 0 ]; then
    dns_failures=0
    dns_recoveries=0
    dns_probe_skipped=0
  elif [ "$probe_status" -eq 2 ]; then
    # Existing custom rules may not expose a static UDP answer to test.
    # Lack of an applicable probe is not evidence of a stuck DNS worker.
    [ "$dns_probe_skipped" -eq 1 ] || log "SmartDNS liveness probe not applicable; retaining process supervision"
    dns_probe_skipped=1
    dns_failures=0
    dns_recoveries=0
  else
    dns_failures=$((dns_failures + 1))
    log "SmartDNS probe failed ($dns_failures/3)"
    if [ "$dns_failures" -ge 3 ]; then
      # One local recovery per continuous outage. Do not loop-restart a broken
      # configuration; a failed recovery exits to the existing restart policy.
      [ "$dns_recoveries" -eq 0 ] || { log "SmartDNS recovery failed; exiting"; exit 1; }
      dns_recoveries=1
      dns_failures=0
      log "SmartDNS alive but unresponsive; restarting only SmartDNS"
      dns_pid="$(cat "$RUNTIME_DIR/smartdns.pid")"
      timeout -k 1 5 python3 "$ROOT/scripts/smartdns-process.py" stop "$dns_pid"
      wait "$dns_pid" 2>/dev/null || true
      python3 "$ROOT/scripts/smartdns-process.py" start "$CONF_DIR/smartdns.conf" >>"$RUNTIME_DIR/smartdns.log" 2>&1 &
      echo $! >"$RUNTIME_DIR/smartdns.pid"
    fi
  fi
  case "${ENABLE_SOCKS5:-0}" in
    1|true|yes)
      [ -f "$RUNTIME_DIR/socks5d.pid" ] && kill -0 "$(cat "$RUNTIME_DIR/socks5d.pid")" 2>/dev/null || {
        log "SOCKS5 unlock-socks5d died; exiting for clean container restart"
        exit 1
      }
      ;;
  esac
  if [ -n "${CONTROL_CENTER_URL:-}" ]; then
    # The supervisor subshell restarts the agent itself; a missing pidfile
    # means the supervisor died, which is the only fatal case left.
    [ -f "$RUNTIME_DIR/control-agent.pid" ] && kill -0 "$(cat "$RUNTIME_DIR/control-agent.pid")" 2>/dev/null || {
      log "center control supervisor died; exiting for clean container restart"
      exit 1
    }
  fi
  sleep 10
done
