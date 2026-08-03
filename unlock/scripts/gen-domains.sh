#!/bin/sh
# Resolve the active unlock domain list.
#
# DOMAIN_SOURCE:
#   auto (default)
#     1) Keep existing domains/all.txt when present and non-empty (geosite artifact)
#     2) Else rebuild from StreamConfig.yaml + domains/1stream.txt
#   geosite
#     Run build-geosite-domains.sh (needs GEOSITE_DIR or network)
#   streamconfig
#     Always rebuild from StreamConfig.yaml + 1stream.txt
#   keep
#     Require an existing all.txt; never rebuild
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="${UNLOCK_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
STREAM_CONFIG="${STREAM_CONFIG:-$ROOT/StreamConfig.yaml}"
OUT_DIR="${DOMAINS_DIR:-$ROOT/domains}"
OUT_FILE="${OUT_FILE:-$OUT_DIR/all.txt}"
DOMAIN_SOURCE="${DOMAIN_SOURCE:-auto}"

mkdir -p "$OUT_DIR"

rebuild_streamconfig() {
  if [ ! -f "$STREAM_CONFIG" ]; then
    echo "ERROR: StreamConfig not found: $STREAM_CONFIG" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  grep -E '^\s+-\s+[A-Za-z0-9._-]+' "$STREAM_CONFIG" \
    | sed -E 's/^\s+-\s+//; s/\s+$//' >>"$tmp"
  ONE_STREAM_FILE="${ONE_STREAM_FILE:-$OUT_DIR/1stream.txt}"
  if [ -f "$ONE_STREAM_FILE" ]; then
    cat "$ONE_STREAM_FILE" >>"$tmp"
  fi
  tr 'A-Z' 'a-z' <"$tmp" \
    | sed -E 's/^\s+//; s/\s+$//' \
    | grep -E '\.' \
    | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -u >"$OUT_FILE"
  rm -f "$tmp"
}

case "$DOMAIN_SOURCE" in
  geosite)
    sh "$SCRIPT_DIR/build-geosite-domains.sh"
    ;;
  streamconfig)
    rebuild_streamconfig
    ;;
  keep)
    if [ ! -s "$OUT_FILE" ]; then
      echo "ERROR: DOMAIN_SOURCE=keep but $OUT_FILE is missing/empty" >&2
      exit 1
    fi
    ;;
  auto|'')
    if [ -s "$OUT_FILE" ]; then
      echo " >> gen-domains: keep existing $(wc -l <"$OUT_FILE" | tr -d ' ') domains in $OUT_FILE"
      exit 0
    fi
    echo " >> gen-domains: $OUT_FILE empty; rebuild from StreamConfig + 1stream"
    rebuild_streamconfig
    ;;
  *)
    echo "ERROR: unknown DOMAIN_SOURCE=$DOMAIN_SOURCE (auto|geosite|streamconfig|keep)" >&2
    exit 1
    ;;
esac

count="$(wc -l <"$OUT_FILE" | tr -d ' ')"
echo " >> gen-domains: wrote $count domains to $OUT_FILE"
