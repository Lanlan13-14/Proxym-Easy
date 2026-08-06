# unlock-center domain classification sources

Published files (stable raw URLs under `main`):

| File | URL path |
|---|---|
| `domain-region.map` | `unlock-center/domains/domain-region.map` |
| `global.txt` | `unlock-center/domains/global.txt` |
| `regional.txt` | `unlock-center/domains/regional.txt` |
| `ai.txt` | `unlock-center/domains/ai.txt` |

Example:

```text
https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock-center/domains/domain-region.map
```

## Format (`domain-region.map`)

```text
domain<TAB>class<TAB>region
```

- `class`: `global` | `regional` | `ai`
- `region`: area id (`us` `jp` `hk` `uk` …) or `-` for global/ai

## Build

```sh
sh unlock-center/scripts/build-domain-map.sh
```

### Universe (must cover unlock data-plane list)

1. **`unlock/domains/all.txt`** — same published list unlock nodes pull daily  
2. **MetaCubeX geosite** basenames from `unlock/domains/geosite-sources.txt`  
3. **Lanlan13-14/Rules** Domain YAML from `unlock/domains/rules-domain-sources.txt`  
   (`streaming_hk/sg/tw/uk`, `tvb`, …)  
4. **1-stream** `stream.smartdns.list` domains  

Google/YouTube family is stripped (never unlocked).

### Classification

1. **1-stream** section headers → `global` / `regional` / `ai` (+ region)  
2. **Rules** YAML → `regional` (`hk`/`sg`/`tw`/`uk`) with higher priority  
3. **China Media** → `global`; **bilibili / biliapi / biliintl** → `regional` `hk`  
4. **SouthEastAsia** → `sg` (no separate `sea`)  
5. Domains only in the universe: longest-suffix inherit from classified parents;  
   else keyword heuristics; else default **`global`** (path-selected unlock)

Daily GitHub Action rebuilds unlock `all.txt` then this map together.

## Custom regions (e.g. `uk`)

1. Ensure section/rules map emits `regional` + `uk` (or edit map)  
2. Deploy unlock node with `region = "uk"`  
3. Add `uk` to center `allow_regions`  

If map has a region but no healthy node, center **degrades to real DNS**
(passthrough), not SERVFAIL and not cross-region unlock.
