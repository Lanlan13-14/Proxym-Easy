#!/bin/sh
set -eu

RUNTIME_DIR="${RUNTIME_DIR:-/run/unlock}"
ALLOWED_IPS="${ALLOWED_IPS:-}"
CONTROL_CENTER_URL="${CONTROL_CENTER_URL:-}"
CONTROL_ALLOWED_IPS_FILE="${CONTROL_ALLOWED_IPS_FILE:-$RUNTIME_DIR/control-allowed-ips.txt}"
ENABLE_ACL="${ENABLE_ACL:-1}"
ENABLE_SOCKS5="${ENABLE_SOCKS5:-0}"
SOCKS5_ALLOWED_IPS="${SOCKS5_ALLOWED_IPS:-}"
SOCKS5_PORT="${SOCKS5_PORT:-1080}"
DNS_PORT="${DNS_UDP_PORT:-53}"
DOT_PORT="${DOT_PORT:-853}"
DOH_PORT="${DOH_PORT:-4430}"
ENABLE_DNS="${ENABLE_DNS:-0}"
ENABLE_DOT="${ENABLE_DOT:-1}"
ENABLE_DOH="${ENABLE_DOH:-1}"

log() { echo " >> [apply-acl] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

case "$ENABLE_ACL" in 1|true|yes) ;; 0|false|no) log "ACL disabled explicitly"; exit 0 ;; *) fail "ENABLE_ACL must be 0 or 1" ;; esac
# A configured control channel makes the center snapshot authoritative for all
# connected data-plane nodes. Keep the local list as a bootstrap/emergency
# list, then merge the last atomically verified center snapshot when present.
if [ -n "$CONTROL_CENTER_URL" ] && [ -s "$CONTROL_ALLOWED_IPS_FILE" ]; then
  control_allowed_ips="$(tr -d '\r\n ' < "$CONTROL_ALLOWED_IPS_FILE")"
  case "$control_allowed_ips" in
    *[!0-9A-Fa-f:.,/]*|'') fail "invalid center ACL snapshot: $CONTROL_ALLOWED_IPS_FILE" ;;
  esac
  [ -n "$ALLOWED_IPS" ] && ALLOWED_IPS="$ALLOWED_IPS,$control_allowed_ips" || ALLOWED_IPS="$control_allowed_ips"
  log "merged last verified center ACL snapshot"
fi
if [ -z "$ALLOWED_IPS" ]; then
  [ -n "$CONTROL_CENTER_URL" ] || fail "ALLOWED_IPS is required for DNS/SNI services"
  log "waiting for first center ACL snapshot; DNS/SNI stays closed until it arrives"
fi
case "$ENABLE_SOCKS5" in 1|true|yes) ENABLE_SOCKS5=1; [ -n "$SOCKS5_ALLOWED_IPS" ] || fail "SOCKS5_ALLOWED_IPS is required when SOCKS5 is enabled" ;; 0|false|no|'') ENABLE_SOCKS5=0 ;; *) fail "ENABLE_SOCKS5 must be 0 or 1" ;; esac
case "$ENABLE_DNS" in 1|true|yes) ENABLE_DNS=1 ;; 0|false|no|'') ENABLE_DNS=0 ;; *) fail "ENABLE_DNS must be 0 or 1" ;; esac
case "$ENABLE_DOT" in 1|true|yes) ENABLE_DOT=1 ;; 0|false|no|'') ENABLE_DOT=0 ;; *) fail "ENABLE_DOT must be 0 or 1" ;; esac
case "$ENABLE_DOH" in 1|true|yes) ENABLE_DOH=1 ;; 0|false|no|'') ENABLE_DOH=0 ;; *) fail "ENABLE_DOH must be 0 or 1" ;; esac
if [ "$ENABLE_DNS" = "0" ] && [ "$ENABLE_DOT" = "0" ] && [ "$ENABLE_DOH" = "0" ]; then
  fail "enable at least one of ENABLE_DNS, ENABLE_DOT, or ENABLE_DOH"
fi

# Validate/build first; replacement is committed by one nft -f transaction.
# A rejected batch (or control-agent timeout) cannot expose a partial table.
python3 - "$ALLOWED_IPS" "$SOCKS5_ALLOWED_IPS" \
  "$ENABLE_DNS" "$DNS_PORT" "$ENABLE_DOT" "$DOT_PORT" \
  "$ENABLE_DOH" "$DOH_PORT" "$ENABLE_SOCKS5" "$SOCKS5_PORT" <<'PY'
import ipaddress
import re
import subprocess
import sys


def log(message):
    print(" >> [apply-acl] " + message, flush=True)


def fail(message):
    print(" >> [apply-acl] ERROR: " + message, file=sys.stderr)
    sys.exit(1)


def cidrs(value, name):
    result = []
    for item in value.split(","):
        item = item.replace(" ", "")
        if not item:
            continue
        if not re.fullmatch(r"[0-9A-Fa-f:./]+", item):
            fail("invalid " + name + " CIDR")
        try:
            network = ipaddress.ip_network(item, strict=False)
        except ValueError:
            fail("invalid " + name + " CIDR")
        result.append(("ip6" if network.version == 6 else "ip", str(network)))
    return result


def port(value, name):
    if not re.fullmatch(r"[0-9]+", value):
        fail("invalid " + name)
    # Existing env files may zero-pad decimal ports. Compare their numeric
    # value consistently without imposing a new five-character restriction.
    value = value.lstrip("0") or "0"
    if len(value) > 5:
        fail("invalid " + name)
    number = int(value)
    if not 1 <= number <= 65535:
        fail("invalid " + name)
    return str(number)


allowed, socks_allowed, dns, dns_port, dot, dot_port, doh, doh_port, socks, socks_port = sys.argv[1:]
allowed = cidrs(allowed, "ALLOWED_IPS")
socks_allowed = cidrs(socks_allowed, "SOCKS5_ALLOWED_IPS") if socks == "1" else []
services = []
if socks == "1":
    socks_port = port(socks_port, "SOCKS5_PORT")
    reserved = {"80", "443"}
    reserved.update(port(value, name) for enabled, value, name in (
        (dns, dns_port, "DNS_UDP_PORT"), (dot, dot_port, "DOT_PORT"),
        (doh, doh_port, "DOH_PORT")) if enabled == "1")
    if socks_port in reserved:
        fail("SOCKS5_PORT conflicts with DNS/DoT/DoH/SNI service")
if dns == "1":
    services.append(("plain DNS", ("tcp", "udp"), port(dns_port, "DNS_UDP_PORT"), allowed))
if dot == "1":
    services.append(("DoT", ("tcp",), port(dot_port, "DOT_PORT"), allowed))
if doh == "1":
    services.append(("DoH", ("tcp",), port(doh_port, "DOH_PORT"), allowed))
if socks == "1":
    services.append(("SOCKS5", ("tcp",), port(socks_port, "SOCKS5_PORT"), socks_allowed))

rules = [
    # Unlike add, create fails if a concurrent first installer wins the probe.
    "create table inet unlock_acl",
    "add chain inet unlock_acl input { type filter hook input priority filter - 10; policy accept; }",
    "add rule inet unlock_acl input iif lo accept",
]


def add_service(protocols, service_port, sources):
    for protocol in protocols:
        for family, source in sources:
            rules.append(f"add rule inet unlock_acl input {family} saddr {source} {protocol} dport {service_port} accept")
        rules.append(f"add rule inet unlock_acl input {protocol} dport {service_port} drop")


# SNI always uses the exact client destination ports, not HTTP_PORT/HTTPS_PORT.
for sni_port in ("80", "443"):
    add_service(("tcp", "udp"), sni_port, allowed)
for _, protocols, service_port, sources in services:
    add_service(protocols, service_port, sources)

try:
    exists = subprocess.run(
        ["nft", "list", "table", "inet", "unlock_acl"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0
    if exists:
        rules.insert(0, "delete table inet unlock_acl")
    # Existence probe is read-only; delete and all adds share this batch.
    subprocess.run(["nft", "-f", "-"], input="\n".join(rules) + "\n", text=True, check=True)
except (OSError, subprocess.CalledProcessError) as error:
    fail("ACL transaction failed: " + str(error))

# Preserve existing success messages, emitted only after the commit.
for label, protocols, service_port, _ in services:
    protocol_desc = "UDP/TCP" if len(protocols) == 2 else "TCP"
    log(f"{label} ACL applied: {protocol_desc} {service_port}")
dns_desc = dns_port if dns == "1" else "off"
dot_desc = dot_port if dot == "1" else "off"
doh_desc = doh_port if doh == "1" else "off"
log(f"DNS/SNI ACL applied for DNS={dns_desc} DoT={dot_desc} DoH={doh_desc} HTTP=80 HTTPS=443")
PY
