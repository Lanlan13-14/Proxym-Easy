#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/start-socks.sh"
ACL="$ROOT/scripts/apply-acl.sh"
WARP="$ROOT/scripts/warp-zt.sh"
COMPOSE="$ROOT/docker-compose.yml"
COMPOSE_SOCKS="$ROOT/docker-compose.socks.yml"
ENV="$ROOT/.env.example"

[ -x "$SCRIPT" ] || { echo "start-socks.sh not executable" >&2; exit 1; }

# Independent authentication + TCP ACL + forced WARP egress.
grep -q 'ENABLE_SOCKS5' "$SCRIPT"
grep -q 'SOCKS5_USERNAME' "$SCRIPT"
grep -q 'SOCKS5_PASSWORD' "$SCRIPT"
grep -q 'SOCKS5_ALLOWED_IPS' "$SCRIPT"
grep -q 'SOCKS5_EXTERNAL_IP' "$SCRIPT"
grep -q 'external: \$SOCKS5_EXTERNAL_IP' "$SCRIPT"
grep -q 'socksmethod: username' "$SCRIPT"
grep -q 'command: connect' "$SCRIPT"
grep -q 'protocol: tcp' "$SCRIPT"
if grep -Eq 'udpassociate|udp\.portrange|SOCKS5_UDP' "$SCRIPT" "$ACL" "$COMPOSE" "$COMPOSE_SOCKS" "$ENV"; then
  echo "unreliable SOCKS UDP support must not be advertised through Docker bridge" >&2
  exit 1
fi
grep -q 'SOCKS5_USERNAME collides with a protected system account' "$SCRIPT"
grep -q 'refusing to change password of pre-existing user' "$SCRIPT"
grep -q "SOCKS5_PASSWORD must not contain ':'" "$SCRIPT"
grep -q 'SOCKS5_PORT conflicts with DNS/DoT/SNI service' "$SCRIPT"
grep -q '"\$DANTED_BIN" -f "\$SOCKS_CONF"' "$SCRIPT"
if grep -q '"\$DANTED_BIN" -N' "$SCRIPT"; then
  echo "Dante -N is worker-count, not foreground mode" >&2
  exit 1
fi

grep -q 'SOCKS5_ALLOWED_IPS' "$ACL"
grep -q 'SOCKS5_ALLOWED_IPS' "$WARP"
grep -q 'SOCKS5_PORT' "$COMPOSE"
grep -q 'SOCKS5_PORT' "$COMPOSE_SOCKS"
grep -q 'DANTE_AUTH_PASS' "$ROOT/tests/dante-runtime.py"
if grep -qE 'SOCKS5_PORT:-1080.*:/tcp' "$COMPOSE"; then
  echo "base Compose must not publish SOCKS ports" >&2
  exit 1
fi
grep -q 'ENABLE_SOCKS5=0' "$ENV"

if grep -RInE 'SOCKS_ENABLED|SOCKS_PORT|SOCKS_USERNAME|SOCKS_PASSWORD|SOCKS_ALLOWED_IPS|SOCKS_UDP_PORT' "$ROOT/scripts" "$ROOT/docker-compose.yml" "$ROOT/.env.example"; then
  echo "legacy SOCKS variable names found" >&2
  exit 1
fi

echo "SOCKS5_CONFIG_PASS"
