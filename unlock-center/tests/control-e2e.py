#!/usr/bin/env python3
"""Exercise center DNS -> WSS node control -> DNS response end to end."""

import asyncio
import os
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import time

import websockets

BINARY = os.environ.get("CENTER_BINARY")
if not BINARY:
    raise SystemExit("CENTER_BINARY is required")


def wait_tcp(port, proc):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
            raise RuntimeError(f"center exited early: {proc.returncode}: {stderr}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("center TLS listener did not open")


def query_packet():
    return (
        b"\xbe\xef\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
        b"\x07example\x03com\x00\x00\x01\x00\x01"
    )


def response_for(request):
    if len(request) < 29:
        raise RuntimeError("unexpected DNS request")
    # One fixed-question A response: example.com -> 203.0.113.9.
    header = request[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
    question = request[12:]
    answer = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x1e\x00\x04\xcb\x00\x71\x09"
    return header + question + answer


async def node_client(port, ready):
    context = ssl._create_unverified_context()
    async with websockets.connect(
        f"wss://127.0.0.1:{port}/unlock-control/v1/connect",
        additional_headers={"Authorization": "Bearer e2e-secret"},
        subprotocols=["proxym-unlock-control-v1"],
        ssl=context,
    ) as websocket:
        if websocket.subprotocol != "proxym-unlock-control-v1":
            raise RuntimeError("subprotocol was not negotiated")
        await websocket.send('{"type":"hello","protocol":"proxym-unlock-control-v1","node_id":"node-1"}')
        hello = await asyncio.wait_for(websocket.recv(), 3)
        acl = await asyncio.wait_for(websocket.recv(), 3)
        if '"type":"hello"' not in hello or '"type":"acl"' not in acl or "127.0.0.0/8" not in acl:
            raise RuntimeError("center did not send expected hello/ACL snapshot")
        ready.set()
        while True:
            message = await websocket.recv()
            if '"type":"query"' not in message:
                continue
            import base64
            import json
            payload = json.loads(message)
            wire = base64.urlsafe_b64decode(payload["dns_message_b64"] + "===")
            answer = base64.urlsafe_b64encode(response_for(wire)).rstrip(b"=").decode()
            await websocket.send(json.dumps({
                "type": "query_result", "id": payload["id"], "dns_message_b64": answer,
            }, separators=(",", ":")))
            return


async def run_e2e():
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        cert = root / "cert.pem"
        key = root / "key.pem"
        nodes = root / "nodes.toml"
        config = root / "config.toml"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-keyout", str(key), "-out", str(cert), "-subj", "/CN=localhost",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        nodes.write_text(
            '[[nodes]]\nid = "node-1"\nregion = "us"\nunlock_ip = "203.0.113.10"\ndns_upstream = "203.0.113.10:53"\n'
        )
        config.write_text(f'''[listen]
enable_dns = true
dns_host = "127.0.0.1"
dns_port = 15353
enable_dot = false
enable_doh = true
doh_host = "127.0.0.1"
doh_port = 18443
doh_base_path = "/dns-query"

[tls]
mode = "files"
domain = "localhost"
cert_file = "{cert}"
key_file = "{key}"

[policy]
default_global_region = "us"
allow_regions = ["us"]

[tables]
domain_map_file = "{root / 'none.map'}"
domain_map_url = ""
min_entries = 0

[nodes]
file = "{nodes}"

[geoip]
enabled = false

[access]
allowed_cidrs = ["127.0.0.0/8"]

[control]
bearer_token = "e2e-secret"
path = "/unlock-control/v1/connect"
''')
        proc = subprocess.Popen([BINARY, "--config", str(config)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            wait_tcp(18443, proc)
            ready = asyncio.Event()
            task = asyncio.create_task(node_client(18443, ready))
            await asyncio.wait_for(ready.wait(), 5)
            def udp_query():
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.settimeout(3)
                try:
                    sock.sendto(query_packet(), ("127.0.0.1", 15353))
                    return sock.recvfrom(4096)[0]
                finally:
                    sock.close()
            answer = await asyncio.to_thread(udp_query)
            await asyncio.wait_for(task, 3)
            if answer[:2] != b"\xbe\xef" or answer[2:4] != b"\x81\x80" or not answer.endswith(b"\xcb\x00\x71\x09"):
                raise RuntimeError(f"unexpected DNS answer: {answer.hex()}")
            print("control_e2e_pass")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    asyncio.run(run_e2e())
