#!/bin/sh
# Network-free test: replaces lego with a deterministic fake ACME client.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
smartdns_pid=""
cleanup() {
  if [ -n "$smartdns_pid" ] && kill -0 "$smartdns_pid" 2>/dev/null; then
    kill "$smartdns_pid" 2>/dev/null || true
    wait "$smartdns_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/conf" "$tmp/run"

cat > "$tmp/bin/lego" <<'EOF'
#!/bin/sh
set -eu
[ "${CLOUDFLARE_DNS_API_TOKEN:-}" = "test-cf-token" ] || {
  echo "missing Cloudflare DNS token" >&2
  exit 41
}
[ "${1:-}" = "run" ] || { echo "expected lego run" >&2; exit 42; }
shift
printf '%s\n' "$@" > "$LEGO_CAPTURE"
path=""
domain=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--path" ]; then path="$arg"; fi
  if { [ "$prev" = "-d" ] || [ "$prev" = "--domains" ]; } && [ -z "$domain" ]; then domain="$arg"; fi
  prev="$arg"
done
[ -n "$path" ] && [ -n "$domain" ] || exit 43
mkdir -p "$path/certificates"
# A changed content is intentional: renew-once must see the change and reload SmartDNS.
printf 'fake-cert-%s\n' "$(date +%s%N 2>/dev/null || date +%s)-$$" > "$path/certificates/$domain.crt"
printf 'fake-key\n' > "$path/certificates/$domain.key"
EOF
chmod +x "$tmp/bin/lego"

# A PID target that records SIGHUP then exits. Python is used because a shell
# blocked in `sleep` may defer a signal trap on some BusyBox/dash builds.
cat > "$tmp/hup-watcher.py" <<'PY'
import os, signal, time
out = os.environ["HUP_FILE"]
ready = os.environ["READY_FILE"]
def on_hup(signum, frame):
    open(out, "w").write("hup\n")
    raise SystemExit(0)
signal.signal(signal.SIGHUP, on_hup)
open(ready, "w").write("ready\n")
while True:
    time.sleep(60)
PY
HUP_FILE="$tmp/hup" READY_FILE="$tmp/ready" python3 "$tmp/hup-watcher.py" &
smartdns_pid=$!
printf '%s\n' "$smartdns_pid" > "$tmp/run/smartdns.pid"
# Do not send HUP until Python has installed its handler.
for _ in 1 2 3 4 5; do [ -f "$tmp/ready" ] && break; sleep 1; done
test -f "$tmp/ready"

export PATH="$tmp/bin:$PATH"
export CONF_DIR="$tmp/conf"
export RUNTIME_DIR="$tmp/run"
# Override all certificate paths so this test is independent from callers.
export LEGO_PATH="$tmp/conf/letsencrypt"
export TLS_CERT="$tmp/conf/letsencrypt/certificates/dot.example.com.crt"
export TLS_KEY="$tmp/conf/letsencrypt/certificates/dot.example.com.key"
export DOT_TLS_MODE=letsencrypt
export DOT_DOMAIN=dot.example.com
export DOT_EXTRA_DOMAINS=alt.example.com
export LE_EMAIL=admin@example.com
export CF_DNS_API_TOKEN=test-cf-token
export LEGO_CAPTURE="$tmp/lego.args"
export RENEW_BEFORE_DAYS=30

"$ROOT/scripts/cert-manager.sh" ensure
test -s "$tmp/conf/letsencrypt/certificates/dot.example.com.crt"
test -s "$tmp/conf/letsencrypt/certificates/dot.example.com.key"
grep -qx -- '--dns' "$tmp/lego.args"
grep -qx 'cloudflare' "$tmp/lego.args"
grep -qx -- '--renew-days' "$tmp/lego.args" && { echo "ensure unexpectedly used renewal" >&2; exit 1; } || true
grep -qx 'dot.example.com' "$tmp/lego.args"
grep -qx 'alt.example.com' "$tmp/lego.args"

"$ROOT/scripts/cert-manager.sh" renew-once
grep -qx -- '--renew-days' "$tmp/lego.args"
grep -qx '30' "$tmp/lego.args"
# Let the trap receive/process the signal.
sleep 1
test -f "$tmp/hup"

echo "cert-manager PASS"
