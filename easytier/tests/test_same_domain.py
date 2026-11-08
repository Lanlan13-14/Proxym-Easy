"""Same-origin regression migrated from Python gateway internals to native Go.

Coverage mapping: WS forwarding + 2 MiB echo during HTTP redemption, atomic
claims, GET/HEAD, rotation/revocation and root control now run through
GoGateway (--config-fd). The old short-TTL expiry branch is fully covered by
Go TestGrantOnceRotationRevocationExpiry's deterministic 900s boundary clock.
"""
import concurrent.futures
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import sys
import threading
import unittest
from unittest import mock

from go_gateway_harness import GoGateway, read_http_headers

SCRIPT = Path(__file__).resolve().parents[1] / "easytier-cf-debian.py"
spec = importlib.util.spec_from_file_location("same_domain_gateway_under_test", SCRIPT)
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)

PAYLOAD = {
    "format": "easytier-cf-join-v1",
    "domain": "mesh.example.test",
    "network": "gateway-test-net",
    "secret": "TEST_SECRET_" + "x" * 48,
    "subnet": "10.66.66.0/24",
    "server_name": "vps",
}


def post_invite(address, token):
    conn = http.client.HTTPConnection(address[0], address[1], timeout=4)
    try:
        conn.request("POST", "/join/" + token, body=b"", headers={
            "X-EasyTier-Join": "1", "Cache-Control": "no-store",
        })
        response = conn.getresponse()
        return response.status, response.read(), dict(response.getheaders())
    finally:
        conn.close()


class SameDomainGatewayTests(unittest.TestCase):
    def setUp(self):
        self.gateway = self.enterContext(GoGateway(PAYLOAD))
        self.address = self.gateway.address
        self.assertEqual(self.address[0], "127.0.0.1")

    def test_invitation_is_one_time_on_gateway_origin_without_dropping_ws(self):
        token = self.gateway.issue()
        self.assertRegex(token, r"^[0-9a-f]{64}$")

        # Keep a raw WebSocket upgraded on the user-facing listener while a
        # separate client redeems the invitation on that very same listener.
        ws = socket.create_connection(self.address, timeout=8)
        self.addCleanup(ws.close)
        ws.settimeout(8)
        ws.sendall(
            b"GET / HTTP/1.1\r\nHost: mesh.example.test\r\n"
            b"Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            b"Sec-WebSocket-Version: 13\r\nX-Test-Header: preserve-me\r\n\r\n"
        )
        response_head = read_http_headers(ws)
        self.assertTrue(response_head.startswith(b"HTTP/1.1 101 "), response_head)
        self.assertIn(b"X-Upstream: untouched\r\n", response_head)
        self.assertEqual(len(self.gateway.handshakes()), 1)
        self.assertIn(b"X-Test-Header: preserve-me\r\n", self.gateway.handshakes()[0])
        self.assertEqual(self.gateway.handshakes()[0].split(b"\r\n", 1)[0], b"GET / HTTP/1.1")

        # An actual masked 2 MiB client-to-server WS binary frame, streamed
        # across the concurrent one-shot HTTP POST, must echo byte-for-byte.
        payload = bytes((i * 37 + 11) & 0xff for i in range(2 * 1024 * 1024))
        mask = b"\x13\x57\x9b\xdf"
        n = len(payload)
        # Client frames set MASK and use the 127 length marker for 2 MiB.
        frame_head = b"\x82\xff" + n.to_bytes(8, "big") + mask
        masked = bytes(value ^ mask[i & 3] for i, value in enumerate(payload))
        expected = frame_head + masked
        echoed = bytearray()
        read_error = []

        def drain_echo():
            try:
                while len(echoed) < len(expected):
                    part = ws.recv(min(65536, len(expected) - len(echoed)))
                    if not part:
                        raise AssertionError("WebSocket closed during payload")
                    echoed.extend(part)
            except BaseException as exc:
                read_error.append(exc)

        reader = threading.Thread(target=drain_echo, daemon=True)
        reader.start()
        first = 65536
        ws.sendall(expected[:first])
        status, body, headers = post_invite(self.address, token)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), PAYLOAD)
        self.assertEqual(headers.get("Cache-Control"), "no-store, no-cache, must-revalidate")
        self.assertIn("nosniff", headers.get("X-Content-Type-Options", ""))
        self.assertEqual(self.gateway.status(token), "consumed")
        repeat_status, repeat_body, _ = post_invite(self.address, token)
        self.assertNotEqual(repeat_status, 200)
        self.assertNotIn(PAYLOAD["secret"].encode(), repeat_body)

        for offset in range(first, len(expected), 32768):
            ws.sendall(expected[offset:offset + 32768])
        reader.join(timeout=12)
        self.assertFalse(reader.is_alive(), "WebSocket echo timed out after invite redemption")
        self.assertFalse(read_error, read_error)
        self.assertEqual(len(echoed), len(expected))
        self.assertEqual(hashlib.sha256(echoed).digest(), hashlib.sha256(expected).digest())

    def test_get_and_head_never_disclose_or_consume_join_secret(self):
        token = self.gateway.issue()
        for method in ("GET", "HEAD"):
            conn = http.client.HTTPConnection(*self.address, timeout=3)
            try:
                conn.request(method, "/join/" + token)
                response = conn.getresponse()
                body = response.read()
                self.assertEqual(response.status, 405)
                self.assertNotIn(PAYLOAD["secret"].encode(), body)
            finally:
                conn.close()
        self.assertEqual(self.gateway.status(token), "active")
        status, body, _ = post_invite(self.address, token)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), PAYLOAD)

    def test_invalid_upgrade_is_rejected_without_touching_upstream(self):
        conn = http.client.HTTPConnection(*self.address, timeout=3)
        try:
            conn.request("GET", "/not-root")
            response = conn.getresponse()
            self.assertEqual(response.status, 404)
            response.read()
        finally:
            conn.close()
        self.assertEqual(self.gateway.handshakes(), [])

    def test_grant_rotation_and_revoke_are_terminal(self):
        old = self.gateway.issue()
        new = self.gateway.issue()
        self.assertNotEqual(old, new)
        self.assertEqual(self.gateway.status(old), "superseded")
        status, body, _ = post_invite(self.address, old)
        self.assertEqual(status, 404)
        self.assertNotIn(PAYLOAD["secret"].encode(), body)
        self.assertEqual(self.gateway.control("revoke", new)["status"], "revoked")
        self.assertEqual(self.gateway.status(new), "revoked")
        status, body, _ = post_invite(self.address, new)
        self.assertEqual(status, 404)
        self.assertNotIn(PAYLOAD["secret"].encode(), body)
        self.assertIsNone(self.gateway.process.poll())

    def test_concurrent_claims_return_secret_at_most_once(self):
        token = self.gateway.issue()
        barrier = threading.Barrier(9)

        def claim():
            barrier.wait(timeout=3)
            return post_invite(self.address, token)

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(claim) for _ in range(8)]
            barrier.wait(timeout=3)
            results = [future.result(timeout=5) for future in futures]
        successes = [body for status, body, _ in results if status == 200]
        self.assertEqual(len(successes), 1)
        self.assertEqual(json.loads(successes[0]), PAYLOAD)
        self.assertEqual(self.gateway.status(token), "consumed")

    def test_root_control_socket_health_issue_status_revoke_and_mode(self):
        # Exercise the retained Python client against the Go-owned 0600 socket.
        with mock.patch.object(installer, "control_path", return_value=self.gateway.control_path):
            self.assertEqual(self.gateway.control_path.stat().st_mode & 0o777, 0o600)
            health = installer.control_call("health")
            self.assertEqual(health["gateway_version"], 3)
            self.assertEqual(health["domain"], PAYLOAD["domain"])
            self.assertRegex(health["instance_id"], r"^[0-9a-f]{32}$")
            issued = installer.control_call("issue")
            self.assertEqual(issued["domain"], PAYLOAD["domain"])
            self.assertEqual(issued["ttl"], 900)
            token = issued["token"]
            self.assertEqual(installer.control_call("status", token)["status"], "active")
            self.assertEqual(installer.control_call("revoke", token)["status"], "revoked")
            self.assertEqual(installer.control_call("status", token)["status"], "revoked")


if __name__ == "__main__":
    unittest.main(verbosity=2)
