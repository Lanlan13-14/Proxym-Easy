"""Read-only regression tests for same-origin EasyTier gateway behavior."""
import concurrent.futures
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import socketserver
import sys
import tempfile
import threading
import unittest
from unittest import mock

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


def read_http_headers(sock, limit=32768):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        part = sock.recv(1)
        if not part:
            break
        data.extend(part)
        if len(data) > limit:
            raise AssertionError("HTTP headers exceeded limit")
    return bytes(data)


class EchoWebSocketUpstream(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 32


class EchoWebSocketHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data = bytearray()
        while b"\r\n\r\n" not in data and len(data) < 32768:
            part = self.request.recv(1)
            if not part:
                return
            data.extend(part)
        self.server.received_handshakes.append(bytes(data))
        self.request.sendall(
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Accept: test-accept\r\nX-Upstream: untouched\r\n\r\n"
        )
        while True:
            part = self.request.recv(65536)
            if not part:
                return
            self.request.sendall(part)


class SameDomainGatewayTests(unittest.TestCase):
    def setUp(self):
        self.upstream = EchoWebSocketUpstream(("127.0.0.1", 0), EchoWebSocketHandler)
        self.upstream.received_handshakes = []
        self.upstream_thread = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.upstream_thread.start()
        self.grant = installer.JoinGrant()
        self.gateway = installer.build_gateway(0, self.upstream.server_address[1], self.grant)
        self.gateway_thread = threading.Thread(target=self.gateway.serve_forever, daemon=True)
        self.gateway_thread.start()
        self.address = self.gateway.server_address
        self.assertEqual(self.address[0], "127.0.0.1")
        self.addCleanup(self.cleanup_servers)

    def cleanup_servers(self):
        self.gateway.close_streams()
        self.gateway.shutdown()
        self.gateway.server_close()
        self.gateway_thread.join(timeout=3)
        self.upstream.shutdown()
        self.upstream.server_close()
        self.upstream_thread.join(timeout=3)

    def test_invitation_is_one_time_on_gateway_origin_without_dropping_ws(self):
        issued = self.grant.issue(dict(PAYLOAD), ttl=60)
        token = issued["token"]
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
        self.assertEqual(len(self.upstream.received_handshakes), 1)
        self.assertIn(b"X-Test-Header: preserve-me\r\n", self.upstream.received_handshakes[0])
        self.assertEqual(self.upstream.received_handshakes[0].split(b"\r\n", 1)[0], b"GET / HTTP/1.1")

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
        self.assertEqual(self.grant.status(token), "consumed")
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
        issued = self.grant.issue(dict(PAYLOAD), ttl=60)
        token = issued["token"]
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
        self.assertEqual(self.grant.status(token), "active")
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
        self.assertEqual(self.upstream.received_handshakes, [])

    def test_grant_rotation_expiry_and_revoke_are_terminal(self):
        old = self.grant.issue(dict(PAYLOAD), ttl=60)["token"]
        new = self.grant.issue(dict(PAYLOAD), ttl=60)["token"]
        self.assertNotEqual(old, new)
        self.assertEqual(self.grant.status(old), "superseded")
        self.assertIsNone(self.grant.claim(old))
        self.assertEqual(self.grant.revoke(new), "revoked")
        self.assertIsNone(self.grant.claim(new))

        expiring = self.grant.issue(dict(PAYLOAD), ttl=0.01)["token"]
        threading.Event().wait(0.03)
        self.assertEqual(self.grant.status(expiring), "expired")
        self.assertIsNone(self.grant.claim(expiring))

    def test_concurrent_claims_return_secret_at_most_once(self):
        token = self.grant.issue(dict(PAYLOAD), ttl=60)["token"]
        barrier = threading.Barrier(9)

        def claim():
            barrier.wait(timeout=3)
            return self.grant.claim(token)

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(claim) for _ in range(8)]
            barrier.wait(timeout=3)
            results = [future.result(timeout=3) for future in futures]
        successes = [result for result in results if result is not None]
        self.assertEqual(len(successes), 1)
        self.assertEqual(json.loads(successes[0]), PAYLOAD)

    def test_root_control_socket_health_issue_status_revoke_and_mode(self):
        # The implementation owns this path in deployment; patch only its
        # base for a safe, disposable test socket (no /etc writes).
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(installer, "TMP", Path(tmp)):
            server = installer.make_control_server(
                self.gateway, lambda: dict(PAYLOAD), "mesh.example.test"
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                path = installer.control_path()
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                health = installer.control_call("health")
                self.assertEqual(health["gateway_version"], 2)
                self.assertEqual(health["domain"], PAYLOAD["domain"])
                issued = installer.control_call("issue")
                self.assertEqual(issued["domain"], PAYLOAD["domain"])
                token = issued["token"]
                self.assertEqual(installer.control_call("status", token)["status"], "active")
                self.assertEqual(installer.control_call("revoke", token)["status"], "revoked")
                self.assertEqual(installer.control_call("status", token)["status"], "revoked")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
