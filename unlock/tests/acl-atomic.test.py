#!/usr/bin/env python3
"""Offline ACL transaction regressions; nft is always a stateful stub."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/apply-acl.sh"
STUB = r'''import json, os, pathlib, sys
root = pathlib.Path(os.environ["MOCK_ROOT"])
args = sys.argv[1:]
with (root / "calls").open("a") as output:
    output.write(json.dumps(args) + "\n")
state = root / "state"
if args == ["list", "table", "inet", "unlock_acl"]:
    sys.exit(0 if state.exists() else 1)
if args != ["-f", "-"]:
    state.write_text("UNSAFE INDIVIDUAL MUTATION")
    sys.exit(90)
batch = sys.stdin.read()
(root / "batch").write_text(batch)
assert state.read_text() == "old rules" if state.exists() else True
lines = batch.splitlines()
if state.exists():
    assert lines.pop(0) == "delete table inet unlock_acl"
assert lines.pop(0) == "create table inet unlock_acl"
assert lines[0].startswith("add chain inet unlock_acl input {")
assert all(line.startswith("add rule inet unlock_acl input ") for line in lines[1:])
# Simulate kernel rejecting a batch after parsing the delete and all adds:
# state is replaced only after acceptance, never as individual commands run.
if os.environ.get("MOCK_FAIL") == "1":
    sys.exit(1)
state.write_text(batch)
'''


class AtomicACL(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "state").write_text("old rules")
        (self.root / "mock.py").write_text(STUB)
        nft = self.root / "nft"
        nft.write_text('#!/bin/sh\nexec "' + sys.executable + '" "$MOCK_ROOT/mock.py" "$@"\n')
        nft.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                        MOCK_ROOT=str(self.root), MOCK_FAIL="0", RUNTIME_DIR=str(self.root),
                        ALLOWED_IPS="203.0.113.7/32,2001:db8:1::/48", ENABLE_ACL="1",
                        CONTROL_CENTER_URL="", CONTROL_ALLOWED_IPS_FILE=str(self.root / "center"),
                        ENABLE_DNS="1", DNS_UDP_PORT="5353", ENABLE_DOT="1", DOT_PORT="9853",
                        ENABLE_DOH="1", DOH_PORT="9443", ENABLE_SOCKS5="1", SOCKS5_PORT="1081",
                        SOCKS5_ALLOWED_IPS="198.51.100.9,2001:db8:2::/48")

    def run_acl(self, **changes):
        return subprocess.run(["sh", str(SCRIPT)], env=dict(self.env, **changes),
                              capture_output=True, text=True, timeout=10)

    def calls(self):
        path = self.root / "calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def batch(self):
        return (self.root / "batch").read_text()

    def assert_transaction(self):
        self.assertEqual(self.calls(), [["list", "table", "inet", "unlock_acl"], ["-f", "-"]])

    def test_atomic_replacement_ports_families_and_independent_socks(self):
        result = self.run_acl(HTTP_PORT="8080", HTTPS_PORT="8443")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_transaction()
        self.assertTrue(self.batch().startswith("delete table inet unlock_acl\ncreate table inet unlock_acl\n"))
        self.assertIn("priority filter - 10; policy accept;", self.batch())
        self.assertIn("input iif lo accept", self.batch())
        for proto, ports in (("tcp", (80, 443, 5353, 9853, 9443, 1081)), ("udp", (80, 443, 5353))):
            for port in ports:
                suffix = f"{proto} dport {port}"
                self.assertIn(suffix + " drop\n", self.batch())
                sources = ("198.51.100.9/32", "2001:db8:2::/48") if port == 1081 else ("203.0.113.7/32", "2001:db8:1::/48")
                for source in sources:
                    family = "ip6" if ":" in source else "ip"
                    self.assertIn(f"{family} saddr {source} {suffix} accept\n", self.batch())
        for line in self.batch().splitlines():
            if "saddr" in line:
                self.assertEqual("dport 1081 " in line, "198.51.100.9" in line or "2001:db8:2::" in line)
        for absent in ("dport 8080", "dport 8443", "udp dport 9853", "udp dport 9443", "udp dport 1081"):
            self.assertNotIn(absent, self.batch())
        self.assertIn("plain DNS ACL applied: UDP/TCP 5353", result.stdout)
        self.assertIn("DNS/SNI ACL applied for DNS=5353 DoT=9853 DoH=9443 HTTP=80 HTTPS=443", result.stdout)

    def test_nft_failure_preserves_old_rules(self):
        result = self.run_acl(MOCK_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_transaction()
        self.assertEqual((self.root / "state").read_text(), "old rules")
        self.assertNotIn("ACL applied", result.stdout)

    def test_first_install_and_center_bootstrap_fail_closed(self):
        (self.root / "state").unlink()
        result = self.run_acl(ALLOWED_IPS="", CONTROL_CENTER_URL="wss://center", ENABLE_SOCKS5="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_transaction()
        self.assertNotIn("delete table", self.batch())
        self.assertNotIn("saddr", self.batch())
        self.assertIn("tcp dport 443 drop", self.batch())
        self.assertIn("waiting for first center ACL snapshot", result.stdout)

    def test_local_and_center_merge(self):
        (self.root / "center").write_text("192.0.2.0/24,2001:db8:3::/48\n")
        result = self.run_acl(CONTROL_CENTER_URL="wss://center")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_transaction()
        for source in ("192.0.2.0/24", "2001:db8:3::/48", "203.0.113.7/32", "2001:db8:1::/48"):
            self.assertIn("saddr " + source + " tcp dport 443 accept", self.batch())

    def test_invalid_input_never_invokes_nft(self):
        cases = [dict(ALLOWED_IPS=value) for value in
                 ("1.2.3.4;flush ruleset", "1.2.3.4\nflush ruleset", "999.0.0.1", "::/129", "1.2.3.4/33", "fe80::1%eth0")]
        cases += [dict(SOCKS5_ALLOWED_IPS="1.2.3.4;flush ruleset")]
        cases += [{name: value} for name in ("DNS_UDP_PORT", "DOT_PORT", "DOH_PORT", "SOCKS5_PORT")
                  for value in ("0", "65536", "53;flush ruleset", "53\nflush ruleset", "-1")]
        for changes in cases:
            with self.subTest(changes=changes):
                result = self.run_acl(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertEqual((self.root / "state").read_text(), "old rules")

    def test_zero_padded_service_ports_remain_compatible(self):
        result = self.run_acl(DNS_UDP_PORT="000053", DOT_PORT="0009853", DOH_PORT="0009443", SOCKS5_PORT="0001081")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("udp dport 53 drop", self.batch())
        self.assertIn("tcp dport 1081 drop", self.batch())

    def test_socks_numeric_port_alias_cannot_share_dns_or_sni_acl(self):
        script = SCRIPT.parent / "start-socks.sh"
        for alias in ("0443", "00080", "05353", "09853", "09443"):
            with self.subTest(port=alias):
                result = self.run_acl(SOCKS5_PORT=alias)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                env = dict(self.env, SOCKS5_PORT=alias, SOCKS5_USERNAME="test", SOCKS5_PASSWORD="test")
                result = subprocess.run(["sh", str(script), "env"], env=env, capture_output=True, text=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("conflicts", result.stderr)

    def test_disabled_services_and_acl(self):
        result = self.run_acl(ENABLE_DNS="0", ENABLE_DOT="0", ENABLE_SOCKS5="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        for port in (5353, 9853, 1081):
            self.assertNotIn(f"dport {port}", self.batch())
        (self.root / "calls").unlink()
        result = self.run_acl(ENABLE_ACL="0", ALLOWED_IPS="")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
