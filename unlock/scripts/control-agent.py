#!/usr/bin/env python3
"""Authenticated outbound control channel for one proxym-easy unlock node.

The node opens one WSS/WS connection to unlock-center's existing DoH port.
The center sends complete ACL snapshots and DNS wire queries. This process
atomically writes the received list and reapplies nftables without restarting
SmartDNS/sniproxy. If unconfigured, it does not run and legacy behavior stays
unchanged.
"""

import asyncio
import base64
import inspect
import ipaddress
import json
import os
import pathlib
import socket
import urllib.parse

try:
    import websockets
except ImportError as exc:
    raise SystemExit(f"python3-websockets is required: {exc}")

ROOT = os.environ.get("UNLOCK_ROOT", "/opt/unlock")
RUNTIME_DIR = pathlib.Path(os.environ.get("RUNTIME_DIR", "/run/unlock"))
URL = os.environ.get("CONTROL_CENTER_URL", "").strip()
TOKEN = os.environ.get("CONTROL_TOKEN", "")
NODE_ID = os.environ.get("CONTROL_NODE_ID", "").strip()
RECONNECT_SECS = max(1, int(os.environ.get("CONTROL_RECONNECT_SECS", "5")))
QUERY_TIMEOUT = max(0.1, float(os.environ.get("CONTROL_QUERY_TIMEOUT_SECS", "0.8")))
ACL_FILE = RUNTIME_DIR / "control-allowed-ips.txt"
PROTOCOL = "proxym-unlock-control-v1"


def log(message):
    print(f" >> [control-agent] {message}", flush=True)


def fail(message):
    raise ValueError(message)


def env_true(name, default="0"):
    return os.environ.get(name, default).strip().lower() in {"1", "true", "yes", "on"}


def validate_config():
    if not URL:
        fail("CONTROL_CENTER_URL is required")
    parsed = urllib.parse.urlparse(URL)
    if parsed.scheme not in {"ws", "wss"} or not parsed.netloc:
        fail("CONTROL_CENTER_URL must be a complete ws:// or wss:// URL")
    if not TOKEN:
        fail("CONTROL_TOKEN is required")
    if not NODE_ID:
        fail("CONTROL_NODE_ID is required")
    if len(NODE_ID) > 128 or any(not (ch.isalnum() or ch in "._-") for ch in NODE_ID):
        fail("CONTROL_NODE_ID may contain only letters, digits, dot, underscore, hyphen")


def normalize_cidrs(values):
    if not isinstance(values, list):
        fail("ACL cidrs must be a JSON array")
    normalized = []
    seen = set()
    for value in values:
        if not isinstance(value, str):
            fail("ACL entry must be a string")
        value = value.strip()
        network = ipaddress.ip_network(value, strict=False)
        canonical = str(network)
        if canonical not in seen:
            normalized.append(canonical)
            seen.add(canonical)
    if not normalized:
        fail("refusing empty center ACL snapshot")
    return normalized


def write_acl(cidrs):
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    candidate = ACL_FILE.with_suffix(".new")
    candidate.write_text(",".join(cidrs) + "\n", encoding="ascii")
    os.chmod(candidate, 0o600)
    os.replace(candidate, ACL_FILE)


async def hot_apply_acl(cidrs):
    write_acl(cidrs)
    # apply-acl reads this file only when the control client is configured.
    # The file replacement above is atomic, so a failed nft update never leaves
    # a partially-written allow list for the next retry.
    process = await asyncio.create_subprocess_exec(
        f"{ROOT}/scripts/apply-acl.sh",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    output, _ = await process.communicate()
    if process.returncode != 0:
        raise RuntimeError(output.decode("utf-8", "replace").strip() or "apply-acl failed")
    # apply-acl protects inbound ports; rerun the idempotent route-mark setup so
    # return packets for newly allowed clients leave main/eth0 instead of WARP.
    process = await asyncio.create_subprocess_exec(
        f"{ROOT}/scripts/warp-zt.sh", "refresh-routes",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    output, _ = await process.communicate()
    if process.returncode != 0:
        raise RuntimeError(output.decode("utf-8", "replace").strip() or "refresh WARP return routes failed")
    log(f"applied center ACL snapshot ({len(cidrs)} CIDRs)")


def b64decode(value):
    if not isinstance(value, str):
        fail("dns_message_b64 must be a string")
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def b64encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def dns_udp_query(wire):
    port = int(os.environ.get("DNS_UDP_PORT", "53"))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(QUERY_TIMEOUT)
    try:
        sock.sendto(wire, ("127.0.0.1", port))
        answer, _ = sock.recvfrom(65535)
        return answer
    finally:
        sock.close()


async def resolve_dns(wire):
    return await asyncio.to_thread(dns_udp_query, wire)


async def send(websocket, payload):
    await websocket.send(json.dumps(payload, separators=(",", ":")))


async def run_once():
    headers = {"Authorization": f"Bearer {TOKEN}"}
    connect_args = {
        "subprotocols": [PROTOCOL],
        "open_timeout": 10,
        "ping_interval": 20,
        "ping_timeout": 20,
        "max_size": 1 << 20,
    }
    # websockets 14+ renamed extra_headers; Debian bookworm's older package
    # still expects it. Keep the data-plane image compatible with both.
    header_arg = "additional_headers" if "additional_headers" in inspect.signature(websockets.connect).parameters else "extra_headers"
    connect_args[header_arg] = headers
    async with websockets.connect(URL, **connect_args) as websocket:
        if websocket.subprotocol != PROTOCOL:
            raise RuntimeError("center did not negotiate control subprotocol")
        await send(websocket, {"type": "hello", "protocol": PROTOCOL, "node_id": NODE_ID})
        async for raw in websocket:
            try:
                message = json.loads(raw)
                message_type = message.get("type")
                if message_type == "hello":
                    if message.get("protocol") != PROTOCOL:
                        raise RuntimeError("center control protocol mismatch")
                elif message_type == "acl":
                    cidrs = normalize_cidrs(message.get("cidrs"))
                    await hot_apply_acl(cidrs)
                elif message_type == "query":
                    request_id = message.get("id")
                    if not isinstance(request_id, int):
                        raise ValueError("query id must be an integer")
                    try:
                        answer = await resolve_dns(b64decode(message.get("dns_message_b64")))
                        await send(websocket, {
                            "type": "query_result", "id": request_id,
                            "dns_message_b64": b64encode(answer),
                        })
                    except Exception as exc:
                        await send(websocket, {
                            "type": "query_result", "id": request_id,
                            "error": str(exc)[:512],
                        })
                elif message_type == "error":
                    raise RuntimeError(f"center error: {message.get('message', '')}")
                else:
                    raise ValueError("unknown control message")
            except Exception as exc:
                await send(websocket, {"type": "error", "message": str(exc)[:512]})
                raise


async def main():
    validate_config()
    log(f"connecting node={NODE_ID} to control center")
    while True:
        try:
            await run_once()
            raise RuntimeError("center closed control connection")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log(f"control channel unavailable: {exc}; reconnecting in {RECONNECT_SECS}s")
            await asyncio.sleep(RECONNECT_SECS)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
