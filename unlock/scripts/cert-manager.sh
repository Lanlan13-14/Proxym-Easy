#!/bin/sh
# Issue and renew DoT/DoH TLS certificates with Let's Encrypt DNS-01 via Cloudflare.
# Uses lego's Cloudflare DNS provider: CLOUDFLARE_DNS_API_TOKEN needs Zone:Read + DNS:Edit.
# Skipped entirely when neither DoT nor DoH is enabled (plain DNS only).
set -eu

CONF_DIR="${CONF_DIR:-/etc/unlock}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
ENABLE_DOT="${ENABLE_DOT:-1}"
ENABLE_DOH="${ENABLE_DOH:-1}"
DOT_TLS_MODE="${DOT_TLS_MODE:-letsencrypt}"
DOT_DOMAIN="${DOT_DOMAIN:-${DOT_SERVER_NAME:-}}"
DOT_EXTRA_DOMAINS="${DOT_EXTRA_DOMAINS:-}"
LE_EMAIL="${LE_EMAIL:-}"
CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN:-}"
LEGO_CA_SERVER="${LEGO_CA_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
LEGO_PATH="${LEGO_PATH:-$CONF_DIR/letsencrypt}"
RENEW_CHECK_HOURS="${RENEW_CHECK_HOURS:-12}"
RENEW_BEFORE_DAYS="${RENEW_BEFORE_DAYS:-30}"

tls_needed() {
  case "$ENABLE_DOT" in 1|true|yes) return 0 ;; esac
  case "$ENABLE_DOH" in 1|true|yes) return 0 ;; esac
  return 1
}

# Keep certificate paths identical to gen-configs.sh for every TLS mode.
if tls_needed; then
  case "$DOT_TLS_MODE" in
    letsencrypt)
      TLS_CERT="${TLS_CERT:-$LEGO_PATH/certificates/$DOT_DOMAIN.crt}"
      TLS_KEY="${TLS_KEY:-$LEGO_PATH/certificates/$DOT_DOMAIN.key}"
      ;;
    selfsigned|custom)
      TLS_CERT="${TLS_CERT:-$CONF_DIR/tls/cert.pem}"
      TLS_KEY="${TLS_KEY:-$CONF_DIR/tls/key.pem}"
      ;;
    none|'')
      # Plain-DNS path should never reach here when ENABLE_DOT/DOH are both off.
      TLS_CERT="${TLS_CERT:-$CONF_DIR/tls/cert.pem}"
      TLS_KEY="${TLS_KEY:-$CONF_DIR/tls/key.pem}"
      ;;
    *)
      # The case dispatcher reports the actionable error later; preserve values here.
      TLS_CERT="${TLS_CERT:-$CONF_DIR/tls/cert.pem}"
      TLS_KEY="${TLS_KEY:-$CONF_DIR/tls/key.pem}"
      ;;
  esac
else
  DOT_TLS_MODE="none"
  TLS_CERT=""
  TLS_KEY=""
fi
SMARTDNS_PID_FILE="${SMARTDNS_PID_FILE:-$RUNTIME_DIR/smartdns.pid}"

log() { echo " >> [cert-manager] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

validate_domain() {
  case "$1" in
    ''|*' '*|*'/'*|*'..'*|.*|*.) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_letsencrypt_env() {
  command -v lego >/dev/null 2>&1 || fail "lego binary is missing"
  validate_domain "$DOT_DOMAIN" || fail "DOT_DOMAIN must be a public FQDN, got: ${DOT_DOMAIN:-<empty>}"
  [ -n "$LE_EMAIL" ] || fail "LE_EMAIL is required for DOT_TLS_MODE=letsencrypt"
  [ -n "$CF_DNS_API_TOKEN" ] || fail "CF_DNS_API_TOKEN is required for Cloudflare DNS-01"
  oldifs="$IFS"; IFS=','
  for d in $DOT_EXTRA_DOMAINS; do
    d="$(printf '%s' "$d" | tr -d ' ')"
    [ -z "$d" ] && continue
    validate_domain "$d" || fail "invalid DOT_EXTRA_DOMAINS entry: $d"
  done
  IFS="$oldifs"
}

issue() {
  validate_letsencrypt_env
  mkdir -p "$LEGO_PATH"
  set -- --accept-tos --email "$LE_EMAIL" --server "$LEGO_CA_SERVER" --dns cloudflare --path "$LEGO_PATH" -d "$DOT_DOMAIN"
  oldifs="$IFS"; IFS=','
  for d in $DOT_EXTRA_DOMAINS; do
    d="$(printf '%s' "$d" | tr -d ' ')"
    [ -z "$d" ] && continue
    set -- "$@" -d "$d"
  done
  IFS="$oldifs"
  log "requesting certificate using Cloudflare DNS-01 for $DOT_DOMAIN"
  CLOUDFLARE_DNS_API_TOKEN="$CF_DNS_API_TOKEN" lego run "$@"
  [ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] || fail "lego finished but certificate files are absent"
  chmod 644 "$TLS_CERT"
  chmod 600 "$TLS_KEY"
}

renew_once() {
  validate_letsencrypt_env
  [ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] || { issue; return 0; }
  before="$(sha256sum "$TLS_CERT" | awk '{print $1}')"
  set -- --accept-tos --email "$LE_EMAIL" --server "$LEGO_CA_SERVER" --dns cloudflare --path "$LEGO_PATH" -d "$DOT_DOMAIN" --renew-days "$RENEW_BEFORE_DAYS"
  oldifs="$IFS"; IFS=','
  for d in $DOT_EXTRA_DOMAINS; do
    d="$(printf '%s' "$d" | tr -d ' ')"
    [ -z "$d" ] && continue
    set -- "$@" -d "$d"
  done
  IFS="$oldifs"
  log "checking renewal for $DOT_DOMAIN (renew if <=${RENEW_BEFORE_DAYS} days)"
  CLOUDFLARE_DNS_API_TOKEN="$CF_DNS_API_TOKEN" lego run "$@"
  after="$(sha256sum "$TLS_CERT" | awk '{print $1}')"
  if [ "$before" != "$after" ]; then
    log "certificate renewed; reloading SmartDNS"
    reload_smartdns
  else
    log "certificate unchanged"
  fi
}

reload_smartdns() {
  if [ -f "$SMARTDNS_PID_FILE" ]; then
    pid="$(cat "$SMARTDNS_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      # SmartDNS handles SIGHUP by restarting its monitored child and rereading TLS files.
      kill -HUP "$pid" 2>/dev/null || true
      log "sent SIGHUP to SmartDNS pid=$pid"
      return 0
    fi
  fi
  log "SmartDNS pid unavailable; certificate will load on its next restart"
}

selfsigned() {
  validate_domain "$DOT_DOMAIN" || fail "DOT_DOMAIN required for selfsigned TLS"
  mkdir -p "$(dirname "$TLS_CERT")" "$(dirname "$TLS_KEY")"
  if [ ! -s "$TLS_CERT" ] || [ ! -s "$TLS_KEY" ]; then
    log "creating explicit test-only self-signed certificate for $DOT_DOMAIN"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
      -keyout "$TLS_KEY" -out "$TLS_CERT" \
      -subj "/CN=$DOT_DOMAIN" -addext "subjectAltName=DNS:$DOT_DOMAIN" 2>/dev/null \
    || openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
      -keyout "$TLS_KEY" -out "$TLS_CERT" -subj "/CN=$DOT_DOMAIN"
    chmod 644 "$TLS_CERT"; chmod 600 "$TLS_KEY"
  fi
}

case "${1:-ensure}" in
  ensure)
    if ! tls_needed; then
      log "DoT/DoH disabled; skipping TLS certificate (plain DNS only)"
      exit 0
    fi
    case "$DOT_TLS_MODE" in
      letsencrypt) [ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] || issue ;;
      selfsigned) selfsigned ;;
      custom) [ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] || fail "custom TLS files missing: $TLS_CERT / $TLS_KEY" ;;
      none) fail "DOT_TLS_MODE=none is only valid when ENABLE_DOT=ENABLE_DOH=0" ;;
      *) fail "DOT_TLS_MODE must be letsencrypt, selfsigned, or custom" ;;
    esac
    ;;
  renew-loop)
    if ! tls_needed; then
      log "renewal disabled: DoT/DoH off (plain DNS only)"
      exit 0
    fi
    [ "$DOT_TLS_MODE" = "letsencrypt" ] || { log "renewal disabled for DOT_TLS_MODE=$DOT_TLS_MODE"; exit 0; }
    seconds=$((RENEW_CHECK_HOURS * 3600))
    [ "$seconds" -ge 3600 ] || seconds=3600
    log "renewal watcher started: every ${RENEW_CHECK_HOURS}h"
    while true; do
      sleep "$seconds"
      renew_once || log "renewal check failed; retrying next interval"
    done
    ;;
  renew-once)
    if ! tls_needed; then
      log "renewal skipped: DoT/DoH off"
      exit 0
    fi
    renew_once
    ;;
  *) fail "usage: $0 {ensure|renew-loop|renew-once}" ;;
esac
