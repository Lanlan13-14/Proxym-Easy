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

# Extract YAML list items that look like domains.
grep -E '^\s+-\s+[A-Za-z0-9._-]+' "$STREAM_CONFIG" \
  | sed -E 's/^\s+-\s+//; s/\s+$//' \
  | tr 'A-Z' 'a-z' \
  | grep -E '\.' \
  | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -u > "$OUT_FILE"

count="$(wc -l < "$OUT_FILE" | tr -d ' ')"
echo " >> gen-domains: wrote $count domains to $OUT_FILE"
