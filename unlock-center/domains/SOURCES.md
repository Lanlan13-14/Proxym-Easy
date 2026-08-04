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

Inputs:

1. **1-stream** `stream.smartdns.list` section headers → global / regional / ai  
2. **Lanlan13-14/Rules** Domain YAML: `streaming_hk/sg/tw/uk`, `tvb` → regional (hk/sg/tw/uk)  
3. Google/YouTube family stripped  

## Custom regions (e.g. `uk`)

1. Ensure section/rules map emits `regional` + `uk` (or edit map)  
2. Deploy unlock node with `region = "uk"`  
3. Add `uk` to center `allow_regions`  

Daily GitHub Action rebuilds these files together with unlock `all.txt`.
