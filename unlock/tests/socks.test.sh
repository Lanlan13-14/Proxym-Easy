#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/start-socks.sh"
SRC="$ROOT/scripts/socks5d.c"
ACL="$ROOT/scripts/apply-acl.sh"
WARP="$ROOT/scripts/warp-zt.sh"
COMPOSE="$ROOT/docker-compose.yml"
ENV="$ROOT/.env.example"
ENTRY="$ROOT/scripts/entrypoint.sh"
DF="$ROOT/Dockerfile"

[ -x "$SCRIPT" ] || { echo "start-socks.sh not executable" >&2; exit 1; }
[ -f "$SRC" ] || { echo "socks5d.c missing" >&2; exit 1; }

# Independent authentication + TCP ACL + forced WARP egress.
grep -q 'ENABLE_SOCKS5' "$SCRIPT"
grep -q 'SOCKS5_USERNAME' "$SCRIPT"
grep -q 'SOCKS5_PASSWORD' "$SCRIPT"
grep -q 'SOCKS5_ALLOWED_IPS' "$SCRIPT"
grep -q 'SOCKS5_EXTERNAL_IP' "$SCRIPT"
grep -q 'unlock-socks5d' "$SCRIPT"
grep -q 'RFC1929' "$SCRIPT"
grep -q '1-255' "$SCRIPT"
# Must NOT create Linux accounts or use Dante.
if grep -Eq 'useradd|chpasswd|danted|dante-server|/etc/shadow' "$SCRIPT"; then
  echo "SOCKS must not use Linux accounts or Dante" >&2
  exit 1
fi
if grep -Eq 'useradd|chpasswd|dante|/etc/shadow' "$SRC"; then
  echo "socks5d.c must not depend on system accounts" >&2
  exit 1
fi
grep -q 'SOCKS5_PORT conflicts with DNS/DoT/SNI service' "$SCRIPT"
grep -q 'validate_env' "$SCRIPT"
grep -q 'start-socks.sh" env' "$ENTRY"
grep -q 'socks5d.pid' "$ENTRY"
grep -q 'unlock-socks5d' "$DF"
grep -q 'socks5d.c' "$DF"
if grep -q 'dante-server' "$DF"; then
  echo "Dockerfile still installs dante-server" >&2
  exit 1
fi

# Server implements username/password method and CONNECT only.
grep -q '0x02' "$SRC"
grep -q 'UDP ASSOCIATE is rejected' "$SRC" || grep -q 'only CONNECT' "$SRC"
grep -q 'bind_outbound' "$SRC" || grep -q 'g_bind_ip' "$SRC"

# Runtime harness must exercise free-charset credentials.
RT="$ROOT/tests/socks5-runtime.py"
grep -q '用户@Foo:Bar' "$RT"
grep -q 'SOCKS5_AUTH_PASS' "$RT"

grep -q 'SOCKS5_ALLOWED_IPS' "$ACL"
# WARP return routing is connection-mark based, so 0.0.0.0/0 is safe:
# only replies to SOCKS connections on SOCKS5_PORT use main/eth0.
grep -q 'socks_port=.*SOCKS5_PORT' "$WARP"
grep -q 'ct mark set' "$WARP"
grep -q 'SOCKS5_PORT' "$COMPOSE"
grep -q 'SOCKS5_PORT:-1080}:${SOCKS5_PORT:-1080}/tcp' "$COMPOSE"
if grep -q 'profiles:' "$COMPOSE"; then
  echo "unlock service must not be hidden behind a Compose profile" >&2
  exit 1
fi
grep -q 'ENABLE_SOCKS5=0' "$ENV"
# Docs: free charset, not Linux username rules.
if grep -Eq 'safe Linux username|A-Za-z0-9_-\]\{0,31\}' "$ENV" "$ROOT/README.md"; then
  echo "docs still claim Linux username charset" >&2
  exit 1
fi
grep -q '1-255' "$ENV" || grep -qi 'RFC1929\|任意字符\|any.*character' "$ENV" "$ROOT/README.md"

if grep -RInE 'SOCKS_ENABLED|SOCKS_PORT|SOCKS_USERNAME|SOCKS_PASSWORD|SOCKS_ALLOWED_IPS|SOCKS_UDP_PORT' "$ROOT/scripts" "$ROOT/docker-compose.yml" "$ROOT/.env.example"; then
  echo "legacy SOCKS variable names found" >&2
  exit 1
fi

echo "SOCKS5_CONFIG_PASS"
