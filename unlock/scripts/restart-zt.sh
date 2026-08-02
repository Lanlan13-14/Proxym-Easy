#!/bin/sh
# Compatibility shim. Zero Trust is now official warp-svc, not cloudflared.
set -eu
ROOT="${UNLOCK_ROOT:-/opt/unlock}"
exec "$ROOT/scripts/warp-zt.sh" supervise
