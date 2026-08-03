#!/bin/sh
# Build domains/all.txt from MetaCubeX geosite lists + local supplemental sources.
# Intended for CI (daily Action) and local maintainers — not the container hot path.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="${UNLOCK_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${DOMAINS_DIR:-$ROOT/domains}"
OUT_FILE="${OUT_FILE:-$OUT_DIR/all.txt}"
SOURCES_FILE="${GEOSITE_SOURCES_FILE:-$OUT_DIR/geosite-sources.txt}"
STREAM_CONFIG="${STREAM_CONFIG:-$ROOT/StreamConfig.yaml}"
ONE_STREAM_FILE="${ONE_STREAM_FILE:-$OUT_DIR/1stream.txt}"
GEOSITE_DIR="${GEOSITE_DIR:-}"
GEOSITE_BASE_URL="${GEOSITE_BASE_URL:-https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite}"
WORKDIR="${WORKDIR:-}"

log() { echo " >> [build-geosite-domains] $*"; }

if [ ! -f "$SOURCES_FILE" ]; then
  echo "ERROR: geosite sources file not found: $SOURCES_FILE" >&2
  exit 1
fi

if [ -z "$WORKDIR" ]; then
  WORKDIR="$(mktemp -d)"
  cleanup_work=1
else
  mkdir -p "$WORKDIR"
  cleanup_work=0
fi
tmp_raw="$WORKDIR/raw.txt"
tmp_norm="$WORKDIR/norm.txt"
tmp_fetch="$WORKDIR/fetch"
mkdir -p "$tmp_fetch"
: >"$tmp_raw"
if [ "$cleanup_work" -eq 1 ]; then
  trap 'rm -rf "$WORKDIR"' EXIT INT TERM
fi

fetch_list() {
  name="$1"
  dest="$tmp_fetch/$name.list"
  if [ -n "$GEOSITE_DIR" ]; then
    src="$GEOSITE_DIR/$name.list"
    if [ ! -f "$src" ]; then
      echo "ERROR: missing local geosite list: $src" >&2
      return 1
    fi
    cp "$src" "$dest"
    return 0
  fi
  url="$GEOSITE_BASE_URL/$name.list"
  # curl fails the step on HTTP errors when -f is set.
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
      -o "$dest" "$url"; then
    echo "ERROR: failed to download $url" >&2
    return 1
  fi
  # Guard against HTML error pages.
  if ! grep -qE '^[+.A-Za-z0-9_@.*-]' "$dest" 2>/dev/null; then
    echo "ERROR: downloaded list looks empty/invalid: $name" >&2
    return 1
  fi
}

# Pull every configured geosite list.
count_lists=0
while IFS= read -r line || [ -n "$line" ]; do
  name="$(printf '%s' "$line" | sed -E 's/#.*//; s/^\s+//; s/\s+$//')"
  [ -n "$name" ] || continue
  case "$name" in
    *@ads*|google*|youtube*)
      log "skip blocked source name: $name"
      continue
      ;;
  esac
  log "source geosite: $name"
  fetch_list "$name"
  # MetaCubeX .list files often omit a trailing newline; force one so domains
  # from adjacent lists never concatenate into a single invalid FQDN.
  {
    cat "$tmp_fetch/$name.list"
    printf '\n'
  } >>"$tmp_raw"
  count_lists=$((count_lists + 1))
done <"$SOURCES_FILE"

[ "$count_lists" -gt 0 ] || { echo "ERROR: no geosite sources loaded" >&2; exit 1; }

# Supplemental: StreamConfig.yaml categorized hosts (covers services without a geosite list).
if [ -f "$STREAM_CONFIG" ]; then
  log "merge StreamConfig supplemental: $STREAM_CONFIG"
  grep -E '^\s+-\s+[A-Za-z0-9._-]+' "$STREAM_CONFIG" \
    | sed -E 's/^\s+-\s+//; s/\s+$//' >>"$tmp_raw" || true
  printf '\n' >>"$tmp_raw"
fi

# Supplemental: normalized 1-stream snapshot.
if [ -f "$ONE_STREAM_FILE" ]; then
  log "merge 1-stream supplemental: $ONE_STREAM_FILE"
  {
    cat "$ONE_STREAM_FILE"
    printf '\n'
  } >>"$tmp_raw"
fi

# Normalize mihomo geosite lines:
#   +.example.com  -> example.com   (DOMAIN-SUFFIX)
#   *.example.com  -> example.com   (wildcard suffix; SmartDNS/sniproxy treat bare as suffix)
#   full.example.com stays full.example.com
# Drop keywords-only tokens, IPv4 literals, empty, and Google/YouTube family.
python3 - "$tmp_raw" "$tmp_norm" <<'PY'
import re, sys
src, dst = sys.argv[1:3]
block = re.compile(
    r'(^|\.)('
    r'google|googleapis|gstatic|googleusercontent|googlevideo|ggpht|gvt[0-9]|'
    r'youtube|ytimg|youtu\.be|withgoogle|blogspot|blogger|appspot|'
    r'chrome|doubleclick|android\.com|clients[0-9]\.google'
    r')(\.|$)',
    re.I,
)
out = set()
for raw in open(src, encoding="utf-8", errors="ignore"):
    s = raw.strip().lower()
    if not s or s.startswith("#"):
        continue
    # strip list metadata markers
    if s.startswith("+."):
        s = s[2:]
    elif s.startswith("*."):
        s = s[2:]
    s = s.lstrip(".")
    # reject regexp / keyword only lines and junk
    if not s or "/" in s or " " in s or "*" in s or s.startswith("regexp:"):
        continue
    if not re.fullmatch(r"[a-z0-9._-]+", s):
        continue
    if "." not in s:
        continue
    if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", s):
        continue
    if block.search(s):
        continue
    out.add(s)
Path = __import__("pathlib").Path
Path(dst).write_text("\n".join(sorted(out)) + ("\n" if out else ""), encoding="utf-8")
print(len(out))
PY

mkdir -p "$OUT_DIR"
cp "$tmp_norm" "$OUT_FILE"
count="$(wc -l <"$OUT_FILE" | tr -d ' ')"
log "wrote $count domains from $count_lists geosite lists + supplementals -> $OUT_FILE"

# Fail closed on suspiciously small merges (geosite alone is already large).
min_count="${MIN_DOMAIN_COUNT:-800}"
if [ "$count" -lt "$min_count" ]; then
  echo "ERROR: merged domain count $count < minimum $min_count" >&2
  exit 1
fi
