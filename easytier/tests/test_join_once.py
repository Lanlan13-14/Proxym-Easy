"""Independent stdlib tests for EasyTier one-time join credential handling."""
import concurrent.futures
import http.client
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "easytier-cf-debian.py"
spec = importlib.util.spec_from_file_location("easytier_cf_debian_under_test", SCRIPT)
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)

PAYLOAD = {
    "format": "easytier-cf-join-v1",
    "domain": "mesh.example.test",
    "network": "unit-test-net",
    "secret": "SECRET_SENTINEL_" + "s" * 48,
    "subnet": "10.66.66.0/24",
    "server_name": "vps",
}


def request(address, method, path, headers=None, timeout=2):
    """Make one loopback HTTP request; return (status, body), or (None, b'')."""
    conn = http.client.HTTPConnection(address[0], address[1], timeout=timeout)
    try:
        headers = dict(headers or {})
        headers.setdefault("Cache-Control", "no-store")
        conn.request(method, path, body=b"" if method == "POST" else None, headers=headers)
        response = conn.getresponse()
        return response.status, response.read()
    except (OSError, http.client.HTTPException):
        return None, b""
    finally:
        conn.close()


class JoinOnceTests(unittest.TestCase):
    def launch(self, ttl=900):
        server, thread, token, consumed = installer.make_join_server(dict(PAYLOAD), ttl=ttl)
        self.assertRegex(token, r"^[0-9a-f]{64}$")
        self.assertEqual(server.server_address[0], "127.0.0.1", "join service must bind loopback only")
        self.assertGreater(server.server_address[1], 0, "tests require an ephemeral bound port")
        self.addCleanup(self.cleanup_server, server, thread)
        return server, thread, token, consumed

    @staticmethod
    def cleanup_server(server, thread):
        if thread.is_alive():
            try:
                server.shutdown()
            except (OSError, RuntimeError):
                pass
            thread.join(timeout=2)
        try:
            server.server_close()
        except OSError:
            pass

    def assert_closed(self, server, thread):
        # The server owns expiry/consumption shutdown and socket closure.
        thread.join(timeout=4)
        self.assertFalse(thread.is_alive(), "one-time server thread did not terminate")
        self.assertEqual(server.fileno(), -1, "server did not independently close its socket")

    def test_valid_token_returns_payload_once_and_closes_server(self):
        server, thread, token, consumed = self.launch()
        path = "/join/" + token
        headers = {"X-EasyTier-Join": "1", "Content-Length": "0"}
        status, body = request(server.server_address, "POST", path, headers)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), PAYLOAD)
        self.assertTrue(consumed.wait(1), "consumed event was not signalled")
        repeat_status, repeat_body = request(server.server_address, "POST", path, headers)
        self.assertNotEqual(repeat_status, 200, "same token succeeded more than once")
        self.assertNotIn(PAYLOAD["secret"].encode(), repeat_body)
        self.assert_closed(server, thread)

    def test_two_concurrent_gets_have_at_most_one_success(self):
        server, thread, token, consumed = self.launch()
        path = "/join/" + token
        barrier = threading.Barrier(3)
        headers = {"X-EasyTier-Join": "1", "Content-Length": "0"}

        def fetch():
            barrier.wait(timeout=3)
            return request(server.server_address, "POST", path, headers)

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(fetch) for _ in range(2)]
            barrier.wait(timeout=3)
            results = [f.result(timeout=4) for f in futures]
        successes = [(status, body) for status, body in results if status == 200]
        self.assertLessEqual(len(successes), 1, "concurrent requests both received the secret")
        if successes:
            self.assertEqual(json.loads(successes[0][1]), PAYLOAD)
            self.assertTrue(consumed.wait(1))
        self.assert_closed(server, thread)

    def test_wrong_path_and_head_do_not_consume_valid_token(self):
        server, thread, token, consumed = self.launch()
        wrong_status, wrong_body = request(server.server_address, "POST", "/join/" + "0" * 64,
                                           {"X-EasyTier-Join": "1", "Content-Length": "0"})
        self.assertNotEqual(wrong_status, 200)
        self.assertNotIn(PAYLOAD["secret"].encode(), wrong_body)
        get_status, get_body = request(server.server_address, "GET", "/join/" + token)
        self.assertEqual(get_status, 405, "GET must be rejected for safe link previews")
        self.assertNotIn(PAYLOAD["secret"].encode(), get_body)
        head_status, head_body = request(server.server_address, "HEAD", "/join/" + token)
        self.assertNotEqual(head_status, 200, "HEAD must not disclose or consume credentials")
        self.assertNotIn(PAYLOAD["secret"].encode(), head_body)
        self.assertFalse(consumed.is_set(), "invalid path or HEAD consumed token")
        status, body = request(server.server_address, "POST", "/join/" + token,
                               {"X-EasyTier-Join": "1", "Content-Length": "0"})
        self.assertEqual(status, 200, "valid POST should still work after invalid path and HEAD")
        self.assertEqual(json.loads(body), PAYLOAD)
        self.assertTrue(consumed.wait(1))
        self.assert_closed(server, thread)

    def test_expired_token_never_returns_secret_and_server_closes(self):
        server, thread, token, consumed = self.launch(ttl=0.15)
        time.sleep(0.35)
        status, body = request(server.server_address, "POST", "/join/" + token,
                               {"X-EasyTier-Join": "1", "Content-Length": "0"})
        self.assertNotEqual(status, 200, "expired token returned credentials")
        self.assertNotIn(PAYLOAD["secret"].encode(), body)
        self.assertFalse(consumed.is_set(), "expiry must not signal successful consumption")
        self.assert_closed(server, thread)


class JoinParsingTests(unittest.TestCase):
    def test_dry_run_refuses_link_without_fetching(self):
        args = type("Args", (), {
            "join": None,
            "join_link": "https://unit-test.trycloudflare.com/join/" + "a" * 64,
            "role": "client", "name": None, "ip": None, "update": False,
            "domain": None, "network": None, "dry_run": True,
        })()
        with mock.patch.object(installer, "fetch_join_link") as fetch:
            with self.assertRaises(installer.SetupError):
                installer.get_config(args, None, "v1.2.3")
        fetch.assert_not_called()

    def test_parse_join_accepts_valid_payload_and_rejects_bad_inputs(self):
        raw = json.dumps(PAYLOAD)
        self.assertEqual(installer.parse_join(raw), PAYLOAD)
        for invalid in (
            "not-json",
            json.dumps({**PAYLOAD, "format": "wrong"}),
            json.dumps({**PAYLOAD, "subnet": "10.66.66.1/24"}),
            json.dumps({**PAYLOAD, "subnet": "2001:db8::/64"}),
            json.dumps({**PAYLOAD, "secret": "short"}),
            " " * 32769,
        ):
            with self.subTest(invalid=invalid[:32]):
                with self.assertRaises(installer.SetupError):
                    installer.parse_join(invalid)

    def test_join_file_get_config_prompts_are_mocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "join.json"
            path.write_text(json.dumps(PAYLOAD))
            path.chmod(0o600)
            args = type("Args", (), {
                "join": str(path), "join_link": None, "role": "client",
                "name": None, "ip": None, "update": False,
                "domain": None, "network": None, "dry_run": False,
            })()
            with mock.patch("builtins.input", side_effect=["test-client", "10.66.66.7"]):
                config = installer.get_config(args, None, "v1.2.3")
        self.assertEqual(config["name"], "test-client")
        self.assertEqual(config["ip"], "10.66.66.7/24")
        self.assertEqual(config["secret"], PAYLOAD["secret"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
