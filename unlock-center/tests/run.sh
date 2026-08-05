#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

printf '%s\n' '== center control channel static wiring =='
for f in scripts/*.sh; do sh -n "$f" || fail=1; done
grep -q 'CENTER_CONTROL_TOKEN' .env.example || { echo 'missing center control token docs'; fail=1; }
grep -q 'CENTER_ALLOWED_IPS' .env.example || { echo 'missing center ACL docs'; fail=1; }
grep -q 'CENTER_ALLOWED_IPS_FILE' docker-compose.yml || { echo 'missing center ACL file wiring'; fail=1; }
grep -q 'update-allowed-ips.sh' README.md || { echo 'missing ACL hot-update documentation'; fail=1; }
grep -q 'tokio-tungstenite' Cargo.toml || { echo 'missing WebSocket dependency'; fail=1; }
grep -q 'ipnet' Cargo.toml || { echo 'missing CIDR dependency'; fail=1; }
grep -q 'broadcast_acl' crates/unlock-center/src/control.rs || { echo 'missing ACL broadcast implementation'; fail=1; }
grep -q 'reload_acl_from_file' crates/unlock-center/src/main.rs || { echo 'missing SIGHUP ACL reload'; fail=1; }
grep -q 'hub.query' crates/unlock-center/src/resolve.rs || { echo 'missing control DNS passthrough'; fail=1; }

printf '%s\n' '== center config templates parse =='
python3 -c 'import tomllib; tomllib.load(open("config.example.toml", "rb")); print("toml_parse_pass")' || fail=1

printf '%s\n' '== center control channel end to end =='
if [ -n "${CENTER_BINARY:-}" ]; then
  CENTER_BINARY="$CENTER_BINARY" python3 tests/control-e2e.py || fail=1
else
  echo 'SKIP: CENTER_BINARY not set (cargo e2e runner supplies it)'
fi

if [ "$fail" -ne 0 ]; then
  echo FAIL
  exit 1
fi
echo PASS
