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
import signal
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
# Node-side budget deliberately below the center's passthrough timeout_ms so a
# late answer still crosses the WSS link before the center gives up and falls
# back to public resolvers (which lose the node's GeoDNS perspective).
QUERY_TIMEOUT = max(0.1, float(os.environ.get("CONTROL_QUERY_TIMEOUT_SECS", "0.6")))
COMMAND_TIMEOUT = 15
SEND_TIMEOUT = 5
MAX_QUERIES = 64
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


async def run_command(*args):
    process = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT, start_new_session=True,
    )
    reader = asyncio.create_task(process.communicate())
    try:
        output, _ = await asyncio.wait_for(asyncio.shield(reader), COMMAND_TIMEOUT)
    except BaseException:
        # Kill descendants too: inherited pipe FDs otherwise keep communicate
        # blocked after the shell itself exits. Reap before reconnecting.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await reader
        raise
    if process.returncode != 0:
        raise RuntimeError(output.decode("utf-8", "replace").strip() or "control command failed")


async def hot_apply_acl(cidrs):
    write_acl(cidrs)
    # Atomic file publication is retained; neither a timeout nor reconnect
    # weakens the currently installed nft rules.
    await run_command(f"{ROOT}/scripts/apply-acl.sh")
    await run_command(f"{ROOT}/scripts/warp-zt.sh", "refresh-routes")
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
    # Two short attempts instead of one long one. Loopback UDP to SmartDNS is
    # normally instant; a single lost wakeup under load should not consume the
    # whole budget. None propagates as a per-query error to the center.
    sock.settimeout(max(0.1, QUERY_TIMEOUT / 2))
    try:
        for _ in range(2):
            sock.sendto(wire, ("127.0.0.1", port))
            try:
                answer, _ = sock.recvfrom(65535)
                return answer
            except socket.timeout:
                continue
        raise TimeoutError("local SmartDNS did not answer in time")
    finally:
        sock.close()


async def resolve_dns(wire):
    # Include executor queueing, not only the UDP recv timeouts. Cancelling the
    # awaiting future also prevents an expired queued job from starting later.
    return await asyncio.wait_for(asyncio.to_thread(dns_udp_query, wire), QUERY_TIMEOUT)


async def answer_query(websocket, request_id, payload):
    """Handle one center query concurrently.

    The recv loop must never await the local SmartDNS round-trip: with several
    in-flight center queries, serial processing queued them until the center's
    (equal) timeout fired first, so every burst degraded to the legacy public
    UDP fallback. Errors are reported per query; the connection survives.
    """
    try:
        answer = await resolve_dns(b64decode(payload))
        await send(websocket, {
            "type": "query_result", "id": request_id,
            "dns_message_b64": b64encode(answer),
        })
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        try:
            await send(websocket, {
                "type": "query_result", "id": request_id,
                "error": str(exc)[:512],
            })
        except Exception:
            pass  # connection is gone; the main loop will notice


async def send(websocket, payload):
    await asyncio.wait_for(websocket.send(json.dumps(payload, separators=(",", ":"))), SEND_TIMEOUT)


async def run_once():
    headers = {"Authorization": f"Bearer {TOKEN}"}
    connect_args = {
        "subprotocols": [PROTOCOL],
        "open_timeout": 10,
        "ping_interval": 20,
        "ping_timeout": 20,
        "close_timeout": 5,
        "max_queue": 64,
        "max_size": 1 << 20,
    }
    # websockets 14+ renamed extra_headers; Debian bookworm's older package
    # still expects it. Keep the data-plane image compatible with both.
    header_arg = "additional_headers" if "additional_headers" in inspect.signature(websockets.connect).parameters else "extra_headers"
    connect_args[header_arg] = headers
    async with websockets.connect(URL, **connect_args) as websocket:
        if websocket.subprotocol != PROTOCOL:
            raise RuntimeError("center did not negotiate control subprotocol")
        tasks = set()
        try:
            await receive_messages(websocket, tasks)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


async def receive_messages(websocket, tasks):
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
                if not isinstance(message.get("dns_message_b64"), str):
                    raise ValueError("dns_message_b64 must be a string")
                if len(tasks) >= MAX_QUERIES:
                    await send(websocket, {"type": "query_result", "id": request_id,
                                           "error": "node query capacity exceeded"})
                    continue
                task = asyncio.create_task(answer_query(websocket, request_id, message["dns_message_b64"]))
                tasks.add(task)
                task.add_done_callback(tasks.discard)
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
