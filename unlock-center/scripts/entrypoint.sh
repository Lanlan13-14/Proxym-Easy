#!/bin/sh
# unlock-center container entrypoint:
#   1) ensure TLS cert (LE CF DNS-01 / selfsigned)
#   2) ensure GeoIP DB (optional download)
#   3) start cert renew-loop + geoip-updater
#   4) exec unlock-center
set -eu

ROOT="${CENTER_ROOT:-/opt/unlock-center}"
DATA_DIR="${DATA_DIR:-/data}"
CONF_DIR="${CONF_DIR:-/etc/unlock-center}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock-center}"
CONFIG_FILE="${CONFIG_FILE:-$CONF_DIR/config.toml}"
export DATA_DIR CONF_DIR RUNTIME_DIR CENTER_PID_FILE="${CENTER_PID_FILE:-$RUNTIME_DIR/unlock-center.pid}"

mkdir -p "$DATA_DIR/tls" "$DATA_DIR/geoip" "$CONF_DIR" "$RUNTIME_DIR" /var/log/unlock-center
log() { echo " >> [entrypoint] $*"; }

# Keep an atomically replaceable CIDR file beside config. SIGHUP can reload this
# file and hot-push the complete snapshot over existing node control sessions.
CENTER_ALLOWED_IPS_FILE="${CENTER_ALLOWED_IPS_FILE:-$CONF_DIR/allowed-ips.txt}"
export CENTER_ALLOWED_IPS_FILE
if [ -n "${CENTER_ALLOWED_IPS:-}" ]; then
  acl_candidate="$CENTER_ALLOWED_IPS_FILE.new"
  printf '%s\n' "$CENTER_ALLOWED_IPS" >"$acl_candidate"
  chmod 600 "$acl_candidate"
  mv "$acl_candidate" "$CENTER_ALLOWED_IPS_FILE"
elif [ ! -e "$CENTER_ALLOWED_IPS_FILE" ]; then
  : >"$CENTER_ALLOWED_IPS_FILE"
  chmod 600 "$CENTER_ALLOWED_IPS_FILE"
fi

# Map common env into cert-manager / center
export ENABLE_DOT="${ENABLE_DOT:-${CENTER_ENABLE_DOT:-1}}"
export ENABLE_DOH="${ENABLE_DOH:-${CENTER_ENABLE_DOH:-1}}"
export ENABLE_DNS="${ENABLE_DNS:-${CENTER_ENABLE_DNS:-0}}"
export DOT_TLS_MODE="${DOT_TLS_MODE:-${CENTER_TLS_MODE:-letsencrypt}}"
export DOT_DOMAIN="${DOT_DOMAIN:-${CENTER_DOT_DOMAIN:-}}"
export GEOIP_DB_PATH="${GEOIP_DB_PATH:-$DATA_DIR/geoip/GeoLite2-City.mmdb}"
# Built-in default download URL — always set unless user overrides.
export GEOIP_DB_URL="${GEOIP_DB_URL:-https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb}"
export GEOIP_ENABLE_AUTO_UPDATE="${GEOIP_ENABLE_AUTO_UPDATE:-1}"
export GEOIP_UPDATE_HOUR="${GEOIP_UPDATE_HOUR:-4}"
export GEOIP_UPDATE_MINUTE="${GEOIP_UPDATE_MINUTE:-0}"

log "ensuring TLS certificates"
"$ROOT/scripts/cert-manager.sh" ensure

# Boot geoip if missing
if [ "${GEOIP_ENABLE:-1}" = "1" ] || [ "${GEOIP_ENABLE:-true}" = "true" ]; then
  if [ ! -s "$GEOIP_DB_PATH" ]; then
    log "geoip DB missing; downloading once"
    "$ROOT/scripts/geoip-updater.sh" once || log "geoip boot download failed (nearest will degrade)"
  fi
fi

# Background supervisors
"$ROOT/scripts/cert-manager.sh" renew-loop >"$RUNTIME_DIR/cert-manager.log" 2>&1 &
echo $! >"$RUNTIME_DIR/cert-manager.pid"
"$ROOT/scripts/geoip-updater.sh" loop >"$RUNTIME_DIR/geoip-updater.log" 2>&1 &
echo $! >"$RUNTIME_DIR/geoip-updater.pid"

# Render minimal config from env if no config mounted
if [ ! -f "$CONFIG_FILE" ]; then
  log "writing $CONFIG_FILE from environment"
  cat >"$CONFIG_FILE" <<EOF
[listen]
enable_dns = $([ "$ENABLE_DNS" = "1" ] || [ "$ENABLE_DNS" = "true" ] && echo true || echo false)
dns_host = "0.0.0.0"
dns_port = ${DNS_UDP_PORT:-53}
enable_dot = $([ "$ENABLE_DOT" = "1" ] || [ "$ENABLE_DOT" = "true" ] && echo true || echo false)
dot_host = "0.0.0.0"
dot_port = ${DOT_PORT:-853}
enable_doh = $([ "$ENABLE_DOH" = "1" ] || [ "$ENABLE_DOH" = "true" ] && echo true || echo false)
doh_host = "0.0.0.0"
doh_port = ${DOH_PORT:-443}
doh_base_path = "${DOH_BASE_PATH:-/api/v2/weather}"
doh_extra_paths = []

[tls]
mode = "$DOT_TLS_MODE"
domain = "${DOT_DOMAIN:-dns.example.com}"
cert_file = "$DATA_DIR/tls/cert.pem"
key_file = "$DATA_DIR/tls/key.pem"

[policy]
unlock_scope = "${UNLOCK_SCOPE:-all}"
enable_ai_unlock = true
default_global_region = "${DEFAULT_GLOBAL_REGION:-us}"
default_ai_region = "${DEFAULT_AI_REGION:-}"
allow_regions = ["us","jp","hk","sg","tw","uk","kr","eu","au","cn"]
unlock_answer_ttl_secs = 45
aaaa_mode = "empty"
other_qtype_mode = "refused"

[tables]
domain_map_url = "${DOMAIN_MAP_URL:-https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock-center/domains/domain-region.map}"
domain_map_file = "${DOMAIN_MAP_FILE:-$ROOT/domains/domain-region.map}"
refresh_interval_secs = ${DOMAIN_MAP_REFRESH_SECS:-3600}
min_entries = ${DOMAIN_MAP_MIN_ENTRIES:-100}

[nodes]
file = "${NODES_FILE:-$CONF_DIR/nodes.toml}"

[schedule]
nearest_for_passthrough = true
default_passthrough_region = "${DEFAULT_PASSTHROUGH_REGION:-us}"
allow_region_fallback = false

[geoip]
db_path = "$GEOIP_DB_PATH"
enabled = true
update_url = "$GEOIP_DB_URL"
auto_update = false
update_hour = ${GEOIP_UPDATE_HOUR:-4}
update_minute = ${GEOIP_UPDATE_MINUTE:-0}

[passthrough]
timeout_ms = 800
fallback_upstreams = ["1.1.1.1:53", "8.8.8.8:53"]

[cache]
passthrough_max_entries = 500000
passthrough_max_ttl_secs = 300

[access]
# This is the single source of client ACL truth. CENTER_ALLOWED_IPS is parsed
# directly by the Rust process; its atomically mirrored file is for SIGHUP hot
# reload and control-node propagation. CENTER_TRUSTED_PROXY_IPS is parsed by
# the same process and is only for peers allowed to provide CF-Connecting-IP.
allowed_cidrs = []
bearer_token = "${CENTER_BEARER_TOKEN:-}"
trusted_proxy_cidrs = []

[control]
# Empty token disables the WebSocket endpoint and preserves legacy UDP node DNS.
bearer_token = "${CENTER_CONTROL_TOKEN:-}"
path = "${CENTER_CONTROL_PATH:-/unlock-control/v1/connect}"

log_level = "${CENTER_LOG_LEVEL:-info}"
EOF
fi

if [ ! -f "${NODES_FILE:-$CONF_DIR/nodes.toml}" ]; then
  if [ -f "$ROOT/nodes.example.toml" ]; then
    log "WARNING: no nodes.toml; copying example (replace with real unlock IPs)"
    cp "$ROOT/nodes.example.toml" "$CONF_DIR/nodes.toml"
  else
    log "ERROR: nodes.toml required at $CONF_DIR/nodes.toml"
    exit 1
  fi
fi

log "starting unlock-center"
export CENTER_PID_FILE
exec "$ROOT/bin/unlock-center" -c "$CONFIG_FILE"
