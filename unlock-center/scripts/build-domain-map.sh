#!/bin/sh
# Build classified domain-region.map for unlock-center from 1-stream sections
# (+ optional Rules Domain YAML + geosite basenames).
#
# Output lines: domain<TAB>class<TAB>region
#   class: global | regional | ai
#   region: us|jp|hk|... or "-" for global/ai
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
# Proxym-Easy repo root (parent of unlock-center)
REPO_ROOT="$(CDPATH= cd -- "$ROOT/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/domains}"
OUT_MAP="${OUT_MAP:-$OUT_DIR/domain-region.map}"
OUT_GLOBAL="${OUT_GLOBAL:-$OUT_DIR/global.txt}"
OUT_REGIONAL="${OUT_REGIONAL:-$OUT_DIR/regional.txt}"
OUT_AI="${OUT_AI:-$OUT_DIR/ai.txt}"
STREAM_LIST="${STREAM_LIST:-}"
STREAM_URL="${STREAM_URL:-https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.smartdns.list}"
RULES_DIR="${RULES_DOMAIN_DIR:-}"
RULES_BASE_URL="${RULES_DOMAIN_BASE_URL:-https://raw.githubusercontent.com/Lanlan13-14/Rules/main/rules/Domain}"
MIN_ENTRIES="${MIN_ENTRIES:-100}"

log() { echo " >> [build-domain-map] $*"; }

mkdir -p "$OUT_DIR"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

if [ -n "$STREAM_LIST" ] && [ -f "$STREAM_LIST" ]; then
  cp "$STREAM_LIST" "$WORKDIR/stream.list"
else
  log "fetch 1-stream list"
  curl -fsSL --retry 3 -o "$WORKDIR/stream.list" "$STREAM_URL"
fi

# Optional Rules Domain files for regional enrichment
RULES_NAMES="${RULES_NAMES:-streaming_hk streaming_sg streaming_tw streaming_uk tvb}"
: >"$WORKDIR/rules_extra.map"
for name in $RULES_NAMES; do
  dest="$WORKDIR/rules-$name.yaml"
  if [ -n "$RULES_DIR" ] && [ -f "$RULES_DIR/$name.yaml" ]; then
    cp "$RULES_DIR/$name.yaml" "$dest"
  else
    url="$RULES_BASE_URL/$name.yaml"
    if curl -fsSL --retry 2 -o "$dest" "$url" 2>/dev/null; then
      :
    else
      log "skip rules $name (unavailable)"
      continue
    fi
  fi
  region="sea"
  case "$name" in
    streaming_hk|tvb) region="hk" ;;
    streaming_sg) region="sg" ;;
    streaming_tw) region="tw" ;;
    streaming_uk) region="uk" ;;
  esac
  # Extract domains from Clash payload YAML
  python3 - "$dest" "$region" >>"$WORKDIR/rules_extra.map" <<'PY'
import re, sys
path, region = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8", errors="ignore"):
    s = line.strip()
    if not s.startswith("- "):
        continue
    val = s[2:].strip().strip("\"'")
    while val.startswith("*."):
        val = val[2:]
    while val.startswith("+."):
        val = val[2:]
    val = val.lstrip(".").lower()
    if not val or "." not in val or "*" in val:
        continue
    if not re.fullmatch(r"[a-z0-9._-]+", val):
        continue
    # skip google family
    if re.search(r"(^|\.)(google|googleapis|gstatic|youtube|ytimg|appspot|app-measurement)", val):
        continue
    print(f"{val}\tregional\t{region}")
PY
  log "rules $name → region=$region"
done

python3 - "$WORKDIR/stream.list" "$WORKDIR/rules_extra.map" "$OUT_MAP" "$OUT_GLOBAL" "$OUT_REGIONAL" "$OUT_AI" "$MIN_ENTRIES" <<'PY'
import re, sys
from pathlib import Path

stream_path, rules_path, out_map, out_g, out_r, out_a, min_e = sys.argv[1:8]
min_e = int(min_e)

# Section title substring → (class, region|None)
# Order: first match wins for section header.
SECTION_RULES = [
    ("Global Plaform", "global", None),  # typo in upstream
    ("Global Platform", "global", None),
    ("AI Platform", "ai", None),
    ("Taiwan Media", "regional", "tw"),
    ("Canada Media", "regional", "ca"),
    ("Japan Media", "regional", "jp"),
    ("Oceania Media", "regional", "au"),
    ("North America Media", "regional", "us"),
    ("Europe Media", "regional", "eu"),
    ("Hong Kong Media", "regional", "hk"),
    ("South America Media", "regional", "sa"),
    ("Indian Media", "regional", "in"),
    ("Korean Media", "regional", "kr"),
    ("SouthEastAsia media", "regional", "sea"),
    ("Southeast Asia", "regional", "sea"),
    ("China Media", "regional", "cn"),
    ("Others", "global", None),
    ("? media", "global", None),
]

BLOCK = re.compile(
    r"(^|\.)(google|googleapis|gstatic|googleusercontent|googlevideo|ggpht|"
    r"youtube|ytimg|youtu\.be|withgoogle|blogspot|blogger|appspot|"
    r"doubleclick|app-measurement\.com|android\.com)(\.|$)",
    re.I,
)

def norm(d: str):
    s = d.strip().lower().rstrip(".")
    while s.startswith("*."):
        s = s[2:]
    while s.startswith("+."):
        s = s[2:]
    s = s.lstrip(".")
    if not s or "." not in s or "*" in s or "/" in s or " " in s:
        return None
    if not re.fullmatch(r"[a-z0-9._-]+", s):
        return None
    if BLOCK.search(s):
        return None
    return s

# domain → (class, region, priority)
# priority: regional=3, ai=2, global=1  (higher wins)
prio = {"regional": 3, "ai": 2, "global": 1}
table = {}

def put(domain, cls, region, boost=0):
    d = norm(domain)
    if not d:
        return
    reg = None if not region or region == "-" else region.lower()
    if cls == "regional" and not reg:
        return
    item = (cls, reg, prio[cls] + boost)
    old = table.get(d)
    if old is None or item[2] >= old[2]:
        # later equal/higher priority overwrites (Rules refine EU→UK etc.)
        table[d] = item

# Parse 1-stream
section_cls, section_reg = "global", None
for line in Path(stream_path).read_text(encoding="utf-8", errors="ignore").splitlines():
    m = re.match(r"^#\s*-{3,}\s*>\s*(.+)$", line)
    if m:
        title = m.group(1).strip()
        section_cls, section_reg = "global", None
        for key, cls, reg in SECTION_RULES:
            if key.lower() in title.lower() or title.lower() in key.lower():
                section_cls, section_reg = cls, reg
                break
        # China default skip? still classify as cn regional; center can choose not to deploy cn nodes
        continue
    m = re.match(r"^nameserver\s+/([^/]+)/", line, re.I)
    if m:
        put(m.group(1), section_cls, section_reg)

# Rules extras
if Path(rules_path).is_file():
    for line in Path(rules_path).read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = line.strip().split("\t")
        if len(parts) >= 3:
            put(parts[0], parts[1], parts[2], boost=1)

if len(table) < min_e:
    raise SystemExit(f"ERROR: only {len(table)} entries < min {min_e}")

# Write outputs
lines = []
g, r, a = [], [], []
for d in sorted(table.keys()):
    cls, reg, _ = table[d]
    reg_s = reg if reg else "-"
    lines.append(f"{d}\t{cls}\t{reg_s}")
    if cls == "global":
        g.append(d)
    elif cls == "regional":
        r.append(d)
    elif cls == "ai":
        a.append(d)

header = (
    "# domain-region.map — unlock-center classified domains\n"
    "# format: domain<TAB>class<TAB>region\n"
    "# class: global | regional | ai\n"
    "# region: area id or - for global/ai\n"
    f"# generated entries: {len(lines)} "
    f"(global={len(g)} regional={len(r)} ai={len(a)})\n"
)
Path(out_map).write_text(header + "\n".join(lines) + "\n", encoding="utf-8")
Path(out_g).write_text("\n".join(g) + ("\n" if g else ""), encoding="utf-8")
Path(out_r).write_text("\n".join(r) + ("\n" if r else ""), encoding="utf-8")
Path(out_a).write_text("\n".join(a) + ("\n" if a else ""), encoding="utf-8")
print(f"wrote {len(lines)} → {out_map}")
print(f"  global={len(g)} regional={len(r)} ai={len(a)}")
PY

log "done: $OUT_MAP"
wc -l "$OUT_MAP" "$OUT_GLOBAL" "$OUT_REGIONAL" "$OUT_AI" 2>/dev/null || true
