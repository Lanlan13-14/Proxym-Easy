#!/bin/sh
# Build domains/all.txt from:
#   1) MetaCubeX geosite lists (geosite-sources.txt)
#   2) Lanlan13-14/Rules Domain YAML payloads (rules-domain-sources.txt)
#   3) StreamConfig.yaml + domains/1stream.txt supplementals
# Dedup happens at the end (sort -u). Intended for CI daily Action / maintainers.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="${UNLOCK_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${DOMAINS_DIR:-$ROOT/domains}"
OUT_FILE="${OUT_FILE:-$OUT_DIR/all.txt}"
SOURCES_FILE="${GEOSITE_SOURCES_FILE:-$OUT_DIR/geosite-sources.txt}"
RULES_SOURCES_FILE="${RULES_DOMAIN_SOURCES_FILE:-$OUT_DIR/rules-domain-sources.txt}"
STREAM_CONFIG="${STREAM_CONFIG:-$ROOT/StreamConfig.yaml}"
ONE_STREAM_FILE="${ONE_STREAM_FILE:-$OUT_DIR/1stream.txt}"
GEOSITE_DIR="${GEOSITE_DIR:-}"
GEOSITE_BASE_URL="${GEOSITE_BASE_URL:-https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite}"
RULES_DOMAIN_BASE_URL="${RULES_DOMAIN_BASE_URL:-https://raw.githubusercontent.com/Lanlan13-14/Rules/main/rules/Domain}"
RULES_DOMAIN_DIR="${RULES_DOMAIN_DIR:-}"
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

append_file_with_nl() {
  # Always terminate with newline so adjacent sources never glue FQDNs.
  cat "$1"
  printf '\n'
}

fetch_geosite_list() {
  name="$1"
  dest="$tmp_fetch/geosite-$name.list"
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
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
      -o "$dest" "$url"; then
    echo "ERROR: failed to download $url" >&2
    return 1
  fi
  if ! grep -qE '^[+.A-Za-z0-9_@.*-]' "$dest" 2>/dev/null; then
    echo "ERROR: downloaded geosite list looks empty/invalid: $name" >&2
    return 1
  fi
}

fetch_rules_yaml() {
  name="$1"
  dest="$tmp_fetch/rules-$name.yaml"
  if [ -n "$RULES_DOMAIN_DIR" ]; then
    src="$RULES_DOMAIN_DIR/$name.yaml"
    if [ ! -f "$src" ]; then
      # allow .list fallback for local mirrors
      if [ -f "$RULES_DOMAIN_DIR/$name.list" ]; then
        src="$RULES_DOMAIN_DIR/$name.list"
      else
        echo "ERROR: missing local Rules Domain file: $name.yaml" >&2
        return 1
      fi
    fi
    cp "$src" "$dest"
    return 0
  fi
  url="$RULES_DOMAIN_BASE_URL/$name.yaml"
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
      -o "$dest" "$url"; then
    echo "ERROR: failed to download $url" >&2
    return 1
  fi
  if ! grep -qE 'payload:|^\s*-\s+' "$dest" 2>/dev/null; then
    echo "ERROR: downloaded Rules Domain YAML looks empty/invalid: $name" >&2
    return 1
  fi
}

# Extract domains from Clash-style Domain YAML:
#   payload:
#     - '*.example.com'
#     - example.com
#     - '*.*.example.com'   -> example.com
# Writes one bare FQDN per line to stdout (still needs global normalize/block).
extract_rules_yaml_domains() {
  python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="ignore").read().splitlines()
out = []
for line in text:
    s = line.strip()
    if not s or s.startswith("#") or s == "payload:":
        continue
    # YAML list item: - value / - 'value' / - "value"
    m = re.match(r"^-\s+(.*)$", s)
    if not m:
        continue
    val = m.group(1).strip()
    # strip surrounding quotes
    if (len(val) >= 2) and ((val[0] == val[-1] == "'") or (val[0] == val[-1] == '"')):
        val = val[1:-1]
    val = val.strip().lower()
    # strip repeated wildcard / suffix markers
    while val.startswith("*."):
        val = val[2:]
    while val.startswith("+."):
        val = val[2:]
    val = val.lstrip(".")
    if not val or "*" in val or "/" in val or " " in val:
        continue
    if "." not in val:
        continue
    if not re.fullmatch(r"[a-z0-9._-]+", val):
        continue
    out.append(val)
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
PY
}

# --- 1) MetaCubeX geosite ---
count_lists=0
while IFS= read -r line || [ -n "$line" ]; do
  name="$(printf '%s' "$line" | sed -E 's/#.*//; s/^\s+//; s/\s+$//')"
  [ -n "$name" ] || continue
  case "$name" in
    *@ads*|google*|youtube*)
      log "skip blocked geosite source: $name"
      continue
      ;;
  esac
  log "source geosite: $name"
  fetch_geosite_list "$name"
  append_file_with_nl "$tmp_fetch/geosite-$name.list" >>"$tmp_raw"
  count_lists=$((count_lists + 1))
done <"$SOURCES_FILE"

[ "$count_lists" -gt 0 ] || { echo "ERROR: no geosite sources loaded" >&2; exit 1; }

# --- 2) Lanlan13-14/Rules Domain YAML ---
count_rules=0
if [ -f "$RULES_SOURCES_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    name="$(printf '%s' "$line" | sed -E 's/#.*//; s/^\s+//; s/\s+$//')"
    [ -n "$name" ] || continue
    log "source rules Domain: $name"
    fetch_rules_yaml "$name"
    extract_rules_yaml_domains "$tmp_fetch/rules-$name.yaml" >>"$tmp_raw"
    printf '\n' >>"$tmp_raw"
    count_rules=$((count_rules + 1))
  done <"$RULES_SOURCES_FILE"
else
  log "rules-domain-sources.txt absent; skip Rules Domain merge"
fi

# --- 3) StreamConfig supplemental ---
if [ -f "$STREAM_CONFIG" ]; then
  log "merge StreamConfig supplemental: $STREAM_CONFIG"
  grep -E '^\s+-\s+[A-Za-z0-9._-]+' "$STREAM_CONFIG" \
    | sed -E 's/^\s+-\s+//; s/\s+$//' >>"$tmp_raw" || true
  printf '\n' >>"$tmp_raw"
fi

# --- 4) 1-stream supplemental ---
if [ -f "$ONE_STREAM_FILE" ]; then
  log "merge 1-stream supplemental: $ONE_STREAM_FILE"
  append_file_with_nl "$ONE_STREAM_FILE" >>"$tmp_raw"
fi

# Normalize all markers + dedupe + block Google/YouTube family.
#   +.example.com / *.example.com / *.*.example.com -> example.com
python3 - "$tmp_raw" "$tmp_norm" <<'PY'
import re, sys
src, dst = sys.argv[1:3]
block = re.compile(
    r'(^|\.)('
    r'google|googleapis|gstatic|googleusercontent|googlevideo|ggpht|gvt[0-9]|'
    r'youtube|ytimg|youtu\.be|withgoogle|blogspot|blogger|appspot|'
    r'chrome|doubleclick|android\.com|clients[0-9]\.google|'
    r'app-measurement\.com|pik\.goog|\.goog$'
    r')(\.|$)',
    re.I,
)
out = set()
for raw in open(src, encoding="utf-8", errors="ignore"):
    s = raw.strip().lower()
    if not s or s.startswith("#") or s == "payload:":
        continue
    # YAML leftovers if any slipped through
    if s.startswith("- "):
        s = s[2:].strip()
        if (len(s) >= 2) and ((s[0] == s[-1] == "'") or (s[0] == s[-1] == '"')):
            s = s[1:-1]
    while s.startswith("*."):
        s = s[2:]
    while s.startswith("+."):
        s = s[2:]
    s = s.lstrip(".")
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
log "wrote $count unique domains (geosite=$count_lists rules=$count_rules + supplementals) -> $OUT_FILE"

min_count="${MIN_DOMAIN_COUNT:-800}"
if [ "$count" -lt "$min_count" ]; then
  echo "ERROR: merged domain count $count < minimum $min_count" >&2
  exit 1
fi
