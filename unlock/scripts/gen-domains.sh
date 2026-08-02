#!/bin/sh
# Generate domain list from StreamConfig.yaml (no yq required).
set -eu

# In the image UNLOCK_ROOT is /opt/unlock. In CI/local checkout, derive it
# from this script so callers do not need to export a container-only path.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="${UNLOCK_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
STREAM_CONFIG="${STREAM_CONFIG:-$ROOT/StreamConfig.yaml}"
OUT_DIR="${DOMAINS_DIR:-$ROOT/domains}"
OUT_FILE="${OUT_DIR}/all.txt"

mkdir -p "$OUT_DIR"

if [ ! -f "$STREAM_CONFIG" ]; then
  echo "ERROR: StreamConfig not found: $STREAM_CONFIG" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM

# Primary categorized source: Smartdns_sniproxy_installer StreamConfig.yaml.
grep -E '^\s+-\s+[A-Za-z0-9._-]+' "$STREAM_CONFIG" \
  | sed -E 's/^\s+-\s+//; s/\s+$//' >> "$tmp"

# Supplemental source: normalized FQDN snapshot derived from 1-stream's
# stream.smartdns.list. Merge rather than replace: each source has unique domains.
ONE_STREAM_FILE="${ONE_STREAM_FILE:-$OUT_DIR/1stream.txt}"
if [ -f "$ONE_STREAM_FILE" ]; then
  cat "$ONE_STREAM_FILE" >> "$tmp"
fi

tr 'A-Z' 'a-z' < "$tmp" \
  | sed -E 's/^\s+//; s/\s+$//' \
  | grep -E '\.' \
  | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -u > "$OUT_FILE"

count="$(wc -l < "$OUT_FILE" | tr -d ' ')"
echo " >> gen-domains: wrote $count domains to $OUT_FILE"
