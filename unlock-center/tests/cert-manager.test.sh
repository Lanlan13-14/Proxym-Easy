#!/bin/sh
# Regression: selfsigned TLS writes directly to stable paths and must not cp
# cert.pem onto itself (which would restart-loop the center entrypoint).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

DATA_DIR="$tmp/data"
RUNTIME_DIR="$tmp/run"
CENTER_DOT_DOMAIN="dns.test.example.com"
CENTER_TLS_MODE="selfsigned"
CENTER_ENABLE_DOT=0
CENTER_ENABLE_DOH=1
DATA_DIR="$DATA_DIR" RUNTIME_DIR="$RUNTIME_DIR" \
  CENTER_DOT_DOMAIN="$CENTER_DOT_DOMAIN" CENTER_TLS_MODE="$CENTER_TLS_MODE" \
  CENTER_ENABLE_DOT="$CENTER_ENABLE_DOT" CENTER_ENABLE_DOH="$CENTER_ENABLE_DOH" \
  "$ROOT/scripts/cert-manager.sh" ensure

test -s "$DATA_DIR/tls/cert.pem"
test -s "$DATA_DIR/tls/key.pem"
first_cert="$(sha256sum "$DATA_DIR/tls/cert.pem" | awk '{print $1}')"
first_key="$(sha256sum "$DATA_DIR/tls/key.pem" | awk '{print $1}')"

# A restart with the same volume must succeed and reuse the existing files.
DATA_DIR="$DATA_DIR" RUNTIME_DIR="$RUNTIME_DIR" \
  CENTER_DOT_DOMAIN="$CENTER_DOT_DOMAIN" CENTER_TLS_MODE="$CENTER_TLS_MODE" \
  CENTER_ENABLE_DOT="$CENTER_ENABLE_DOT" CENTER_ENABLE_DOH="$CENTER_ENABLE_DOH" \
  "$ROOT/scripts/cert-manager.sh" ensure

test "$first_cert" = "$(sha256sum "$DATA_DIR/tls/cert.pem" | awk '{print $1}')"
test "$first_key" = "$(sha256sum "$DATA_DIR/tls/key.pem" | awk '{print $1}')"
echo cert_manager_selfsigned_pass
