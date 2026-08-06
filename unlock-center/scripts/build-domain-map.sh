#!/bin/sh
# Build classified domain-region.map for unlock-center.
#
# Universe (completeness, same family as unlock/domains/all.txt):
#   1) unlock/domains/all.txt (if present)
#   2) MetaCubeX geosite lists (unlock/domains/geosite-sources.txt)
#   3) Lanlan13-14/Rules Domain YAML (unlock/domains/rules-domain-sources.txt)
#   4) 1-stream stream.smartdns.list domains
#
# Classification:
#   - 1-stream section headers → global / regional / ai (+ region)
#   - Rules streaming_hk|sg|tw|uk|tvb → regional (hk/sg/tw/uk)
#   - China Media → global; bilibili/biliapi → regional hk
#   - SouthEastAsia → sg
#   - Domains only in universe (not in 1-stream/Rules): longest-suffix inherit,
#     else default class=global (path-selected unlock region)
#
# Output lines: domain<TAB>class<TAB>region
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$ROOT/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/domains}"
OUT_MAP="${OUT_MAP:-$OUT_DIR/domain-region.map}"
OUT_GLOBAL="${OUT_GLOBAL:-$OUT_DIR/global.txt}"
OUT_REGIONAL="${OUT_REGIONAL:-$OUT_DIR/regional.txt}"
OUT_AI="${OUT_AI:-$OUT_DIR/ai.txt}"

STREAM_LIST="${STREAM_LIST:-}"
STREAM_URL="${STREAM_URL:-https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.smartdns.list}"

UNLOCK_ALL="${UNLOCK_ALL:-$REPO_ROOT/unlock/domains/all.txt}"
GEOSITE_SOURCES="${GEOSITE_SOURCES_FILE:-$REPO_ROOT/unlock/domains/geosite-sources.txt}"
RULES_SOURCES="${RULES_DOMAIN_SOURCES_FILE:-$REPO_ROOT/unlock/domains/rules-domain-sources.txt}"
GEOSITE_DIR="${GEOSITE_DIR:-}"
GEOSITE_BASE_URL="${GEOSITE_BASE_URL:-https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite}"
RULES_DIR="${RULES_DOMAIN_DIR:-}"
RULES_BASE_URL="${RULES_DOMAIN_BASE_URL:-https://raw.githubusercontent.com/Lanlan13-14/Rules/main/rules/Domain}"
MIN_ENTRIES="${MIN_ENTRIES:-100}"

log() { echo " >> [build-domain-map] $*"; }

mkdir -p "$OUT_DIR"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

# --- 1-stream list ---
if [ -n "$STREAM_LIST" ] && [ -f "$STREAM_LIST" ]; then
  cp "$STREAM_LIST" "$WORKDIR/stream.list"
else
  log "fetch 1-stream list"
  curl -fsSL --retry 3 -o "$WORKDIR/stream.list" "$STREAM_URL"
fi

# --- Rules Domain YAML → regional map lines ---
: >"$WORKDIR/rules_extra.map"
if [ -f "$RULES_SOURCES" ]; then
  RULES_NAMES="$(
    sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$RULES_SOURCES" | sed '/^$/d' | tr '\n' ' '
  )"
else
  RULES_NAMES="${RULES_NAMES:-streaming_hk streaming_sg streaming_tw streaming_uk tvb}"
fi
for name in $RULES_NAMES; do
  [ -n "$name" ] || continue
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
  region="sg"
  case "$name" in
    streaming_hk|tvb) region="hk" ;;
    streaming_sg) region="sg" ;;
    streaming_tw) region="tw" ;;
    streaming_uk) region="uk" ;;
  esac
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
    if re.search(
        r"(^|\.)(google|googleapis|gstatic|youtube|ytimg|appspot|app-measurement)",
        val,
    ):
        continue
    print(f"{val}\tregional\t{region}")
PY
  log "rules $name → region=$region"
done

# --- Universe: bare domains (one per line) ---
: >"$WORKDIR/universe.txt"

if [ -f "$UNLOCK_ALL" ]; then
  log "universe: unlock all.txt ($(wc -l <"$UNLOCK_ALL" | tr -d ' ') lines)"
  cat "$UNLOCK_ALL" >>"$WORKDIR/universe.txt"
  printf '\n' >>"$WORKDIR/universe.txt"
else
  log "universe: unlock all.txt missing ($UNLOCK_ALL)"
fi

# geosite lists (same basenames as unlock daily build)
if [ -f "$GEOSITE_SOURCES" ]; then
  count_g=0
  while IFS= read -r line || [ -n "$line" ]; do
    name="$(printf '%s' "$line" | sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$name" ] || continue
    case "$name" in
      *@ads*|google*|youtube*) continue ;;
    esac
    dest="$WORKDIR/geosite-$name.list"
    if [ -n "$GEOSITE_DIR" ] && [ -f "$GEOSITE_DIR/$name.list" ]; then
      cp "$GEOSITE_DIR/$name.list" "$dest"
    else
      if ! curl -fsSL --retry 2 -o "$dest" "$GEOSITE_BASE_URL/$name.list" 2>/dev/null; then
        log "skip geosite $name"
        continue
      fi
    fi
    # normalize markers to bare FQDN
    python3 - "$dest" >>"$WORKDIR/universe.txt" <<'PY'
import re, sys
path = sys.argv[1]
for raw in open(path, encoding="utf-8", errors="ignore"):
    s = raw.strip().lower()
    if not s or s.startswith("#"):
        continue
    if s.startswith("- "):
        s = s[2:].strip().strip("\"'")
    while s.startswith("*."):
        s = s[2:]
    while s.startswith("+."):
        s = s[2:]
    s = s.lstrip(".")
    if not s or "." not in s or "*" in s or "/" in s or " " in s:
        continue
    if not re.fullmatch(r"[a-z0-9._-]+", s):
        continue
    print(s)
PY
    count_g=$((count_g + 1))
  done <"$GEOSITE_SOURCES"
  log "universe: geosite lists merged ($count_g)"
fi

# rules domains also enter universe (already in rules_extra.map; add bare names)
if [ -s "$WORKDIR/rules_extra.map" ]; then
  cut -f1 "$WORKDIR/rules_extra.map" >>"$WORKDIR/universe.txt"
fi

# 1-stream domains into universe
python3 - "$WORKDIR/stream.list" >>"$WORKDIR/universe.txt" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    m = re.match(r"^nameserver\s+/([^/]+)/", line, re.I)
    if m:
        print(m.group(1).strip().lower())
PY

python3 - \
  "$WORKDIR/stream.list" \
  "$WORKDIR/rules_extra.map" \
  "$WORKDIR/universe.txt" \
  "$OUT_MAP" \
  "$OUT_GLOBAL" \
  "$OUT_REGIONAL" \
  "$OUT_AI" \
  "$MIN_ENTRIES" <<'PY'
import re, sys
from pathlib import Path

stream_path, rules_path, universe_path, out_map, out_g, out_r, out_a, min_e = sys.argv[1:9]
min_e = int(min_e)

SECTION_RULES = [
    ("Global Plaform", "global", None),
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
    ("SouthEastAsia media", "regional", "sg"),
    ("Southeast Asia", "regional", "sg"),
    ("China Media", "global", None),
    ("Others", "global", None),
    ("? media", "global", None),
]

BLOCK = re.compile(
    r"(^|\.)(google|googleapis|gstatic|googleusercontent|googlevideo|ggpht|"
    r"youtube|youtube-nocookie|ytimg|youtu\.be|withgoogle|blogspot|blogger|appspot|"
    r"doubleclick|app-measurement\.com|android\.com|"
    r"gvt1\.com|gvt2\.com|gvt3\.com|1e100\.net|"
    r"googleadservices|googlesyndication|google-analytics|"
    r"googletagmanager|googletagservices|recaptcha\.net)(\.|$)",
    re.I,
)

# Service-ish keyword → default class when only in universe (no 1-stream hit).
# Longer / more specific keywords first where needed.
KEYWORD_CLASS = [
    # AI
    (re.compile(r"(openai|anthropic|claude\.ai|chatgpt|sora\.com|oaistatic|oaiusercontent|copilot\.microsoft)", re.I), "ai", None),
    # Force regional families (also applied after merge)
    (re.compile(r"(^|\.)(bilibili|biliapi|biliintl|bilivideo)(\.|$)", re.I), "regional", "hk"),
    (re.compile(r"(^|\.)(mytvsuper|nowe\.com|now\.com|tvb|encoretvb)(\.|$)", re.I), "regional", "hk"),
    (re.compile(r"(^|\.)(mewatch|starhub|sooka\.my|hbogoasia|trueid)(\.|$)", re.I), "regional", "sg"),
    (re.compile(r"(^|\.)(kktv|litv|hamivideo|catchplay|bahamut|friday\.tw|linetv|4gtv|ofiii)(\.|$)", re.I), "regional", "tw"),
    (re.compile(r"(^|\.)(bbc\.|bbci\.|itv\.com|channel4|channel5|sky\.com|britbox)", re.I), "regional", "uk"),
    (re.compile(r"(^|\.)(dmm\.|abema|niconico|nicovideo|tver\.|unext|radiko|hulu\.jp|paravi)", re.I), "regional", "jp"),
    (re.compile(r"(^|\.)(coupang|wavve|tving|naver\.com|afreecatv|kbs\.|mbc\.|sbs\.co\.kr)", re.I), "regional", "kr"),
    # Global streaming brands
    (re.compile(
        r"(netflix|nflx|disney|bamgrid|dssott|hotstar|hulu|hbo|max\.com|primevideo|prime-video|"
        r"amazonvideo|aiv-cdn|aiv-delivery|pv-cdn|dazn|spotify|tiktok|byteoversea|"
        r"instagram|steam|twitch|apple.?tv|tvplus|espn|discovery|paramount|peacock|"
        r"youtube"  # blocked above; keep harmless
        r")",
        re.I,
    ), "global", None),
]

prio = {"regional": 3, "ai": 2, "global": 1}
table = {}  # domain -> (class, region|None, score)

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
    # reject pure IPv4
    if s.split(".").count(".") == 3 and all(p.isdigit() and 0 <= int(p) <= 255 for p in s.split(".")):
        return None
    return s

def put(domain, cls, region, boost=0):
    d = norm(domain)
    if not d:
        return
    reg = None if not region or region == "-" else region.lower()
    if cls == "regional" and not reg:
        return
    score = prio[cls] + boost
    old = table.get(d)
    if old is None or score >= old[2]:
        table[d] = (cls, reg, score)

# 1-stream sections
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
        continue
    m = re.match(r"^nameserver\s+/([^/]+)/", line, re.I)
    if m:
        put(m.group(1), section_cls, section_reg)

# Rules extras (boost over 1-stream for HK/SG/TW/UK refinement)
if Path(rules_path).is_file():
    for line in Path(rules_path).read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = line.strip().split("\t")
        if len(parts) >= 3:
            put(parts[0], parts[1], parts[2], boost=1)

# Universe domains
universe = set()
for line in Path(universe_path).read_text(encoding="utf-8", errors="ignore").splitlines():
    d = norm(line)
    if d:
        universe.add(d)

# Ensure classified keys are in universe
universe |= set(table.keys())

def longest_classified(domain: str):
    name = domain
    while True:
        if name in table:
            return table[name]
        i = name.find(".")
        if i < 0:
            return None
        name = name[i + 1 :]

def keyword_class(domain: str):
    for rx, cls, reg in KEYWORD_CLASS:
        if rx.search(domain):
            return cls, reg
    return "global", None

# Fill universe gaps
for d in sorted(universe):
    if d in table:
        continue
    hit = longest_classified(d)
    if hit is not None:
        cls, reg, _ = hit
        put(d, cls, reg, boost=0)
        continue
    cls, reg = keyword_class(d)
    put(d, cls, reg, boost=0)

# Bilibili family → always regional hk
BILI_RE = re.compile(r"(^|\.)(bilibili|biliapi|biliintl|bilivideo)(\.|$)")
for d in list(table.keys()):
    if BILI_RE.search(d):
        put(d, "regional", "hk", boost=10)

if len(table) < min_e:
    raise SystemExit(f"ERROR: only {len(table)} entries < min {min_e}")

# Write
lines, g, r, a = [], [], [], []
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
    "# sources: unlock/all.txt + geosite + Rules Domain + 1-stream\n"
)
Path(out_map).write_text(header + "\n".join(lines) + "\n", encoding="utf-8")
Path(out_g).write_text("\n".join(g) + ("\n" if g else ""), encoding="utf-8")
Path(out_r).write_text("\n".join(r) + ("\n" if r else ""), encoding="utf-8")
Path(out_a).write_text("\n".join(a) + ("\n" if a else ""), encoding="utf-8")
print(f"wrote {len(lines)} → {out_map}")
print(f"  global={len(g)} regional={len(r)} ai={len(a)}")
# coverage vs unlock all.txt
all_path = Path(universe_path)
print(f"  universe_input_lines≈{sum(1 for _ in open(universe_path, encoding='utf-8', errors='ignore'))}")
PY

log "done: $OUT_MAP"
wc -l "$OUT_MAP" "$OUT_GLOBAL" "$OUT_REGIONAL" "$OUT_AI" 2>/dev/null || true
