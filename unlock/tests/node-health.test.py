#!/usr/bin/env python3
"""Offline/sandbox regressions: never invoke real WARP, nft or routing."""
import asyncio
import importlib.util
import json
import os
import pathlib
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import AsyncMock, patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("control_agent", ROOT / "scripts/control-agent.py")
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)


class HealthTests(unittest.TestCase):
    def test_warp_status_bounded_and_strict(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "warp-ready").touch()
            executable(tmp / "pgrep", "#!/bin/sh\nexit 0\n")
            executable(tmp / "curl", "#!/bin/sh\necho warp=on\n")
            env = dict(os.environ, PATH=f"{tmp}:" + os.environ["PATH"], RUNTIME_DIR=str(tmp), WARP_CLI_TIMEOUT="0.1")
            for content in ["echo Disconnected", "echo Connected; exit 1", "exec /bin/sleep 20"]:
                executable(tmp / "warp-cli", "#!/bin/sh\n" + content + "\n")
                result = subprocess.run(["sh", str(ROOT / "scripts/warp-zt.sh"), "status"], env=env, timeout=3, capture_output=True)
                self.assertNotEqual(result.returncode, 0, content)
            executable(tmp / "warp-cli", "#!/bin/sh\necho 'Status update: Connected'\n")
            self.assertEqual(subprocess.run(["sh", str(ROOT / "scripts/warp-zt.sh"), "status"], env=env, timeout=3).returncode, 0)
            executable(tmp / "curl", "#!/bin/sh\necho warp=off\n")
            self.assertNotEqual(subprocess.run(["sh", str(ROOT / "scripts/warp-zt.sh"), "status"], env=env, timeout=3).returncode, 0)

    def test_dns_static_rule_and_validation(self):
        for address, good in [("203.0.113.4", True), ("203.0.113.5", False)]:
            with tempfile.TemporaryDirectory() as tmp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.bind(("127.0.0.1", 0))
                pathlib.Path(tmp, "smartdns.conf").write_text(f"bind 127.0.0.1:{sock.getsockname()[1]}\naddress /custom.invalid/203.0.113.4\n")
                sock.settimeout(3)
                def reply():
                    wire, peer = sock.recvfrom(4096)
                    header = struct.pack("!HHHHHH", struct.unpack("!H", wire[:2])[0], 0x8180, 1, 1, 0, 0)
                    rr = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 10, 4) + socket.inet_aton(address)
                    sock.sendto(header + wire[12:] + rr, peer)
                thread = threading.Thread(target=reply)
                thread.start()
                result = subprocess.run(["python3", str(ROOT / "scripts/dns-health.py")], env=dict(os.environ, CONF_DIR=tmp, DNS_UDP_PORT=str(sock.getsockname()[1])), capture_output=True, timeout=4)
                thread.join()
                self.assertEqual(result.returncode == 0, good)

    def test_dns_no_response_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("127.0.0.1", 0))
            pathlib.Path(tmp, "smartdns.conf").write_text(f"bind 127.0.0.1:{sock.getsockname()[1]}\naddress /custom.invalid/203.0.113.4\n")
            result = subprocess.run(["python3", str(ROOT / "scripts/dns-health.py")], env=dict(os.environ, CONF_DIR=tmp, DNS_UDP_PORT=str(sock.getsockname()[1])), capture_output=True, timeout=4)
            self.assertEqual(result.returncode, 1)

    def test_dns_multiv4_ipv6_and_nonloopback_listener_are_compatible(self):
        cases = [(socket.AF_INET, "127.0.0.2", "203.0.113.4,203.0.113.5", "203.0.113.5", 1),
                 (socket.AF_INET6, "::1", "2001:db8::4", "2001:db8::4", 28)]
        for family, host, configured, answer, kind in cases:
            with self.subTest(configured=configured), tempfile.TemporaryDirectory() as tmp, socket.socket(family, socket.SOCK_DGRAM) as sock:
                try:
                    sock.bind((host, 0))
                except OSError:
                    if family == socket.AF_INET6:
                        continue
                    raise
                sock.settimeout(3)
                bind = f"[{host}]:{sock.getsockname()[1]}" if family == socket.AF_INET6 else f"{host}:{sock.getsockname()[1]}"
                pathlib.Path(tmp, "smartdns.conf").write_text(f"bind {bind}\naddress /custom.invalid/{configured}\n")
                def reply():
                    wire, peer = sock.recvfrom(4096)
                    self.assertEqual(struct.unpack("!H", wire[-4:-2])[0], kind)
                    header = struct.pack("!HHHHHH", struct.unpack("!H", wire[:2])[0], 0x8180, 1, 1, 0, 0)
                    data = socket.inet_pton(family, answer)
                    sock.sendto(header + wire[12:] + b"\xc0\x0c" + struct.pack("!HHIH", kind, 1, 10, len(data)) + data, peer)
                thread = threading.Thread(target=reply); thread.start()
                result = subprocess.run(["python3", str(ROOT / "scripts/dns-health.py")], env=dict(os.environ, CONF_DIR=tmp), capture_output=True, timeout=4)
                thread.join()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_dns_not_applicable_is_distinct_from_liveness_failure(self):
        for config in ["bind 127.0.0.1:5533 -force-aaaa-soa\naddress /custom.invalid/2001:db8::4\n",
                       "address /custom.invalid/203.0.113.4\n"]:
            with tempfile.TemporaryDirectory() as tmp:
                pathlib.Path(tmp, "smartdns.conf").write_text(config)
                result = subprocess.run(["python3", str(ROOT / "scripts/dns-health.py")], env=dict(os.environ, CONF_DIR=tmp), capture_output=True, timeout=4)
                self.assertEqual(result.returncode, 2)

    def test_entrypoint_recovers_only_after_consecutive_failures(self):
        for failures, expected_starts, probe_code in [("{1, 3}", 1, 1), ("{1, 2, 3}", 2, 1), ("set(range(1, 20))", 1, 2)]:
            with tempfile.TemporaryDirectory() as name:
                tmp = pathlib.Path(name)
                scripts = tmp / "scripts"
                scripts.mkdir()
                shutil.copy2(ROOT / "scripts/smartdns-process.py", scripts / "smartdns-process.py")
                for script in ["cert-manager.sh", "gen-configs.sh", "control-agent.sh", "start-socks.sh"]:
                    executable(scripts / script, "#!/bin/sh\nexit 0\n")
                executable(scripts / "domain-updater.sh", "#!/bin/sh\nif [ \"$1\" = loop ]; then while :; do sleep 3600; done; fi\nexit 0\n")
                (tmp / "domains").write_text("custom.invalid\n")
                executable(tmp / "mkdir", "#!/usr/bin/python3\nimport os,sys\nargs=[arg for arg in sys.argv[1:] if arg != '/var/log/unlock']\nos.execv('/bin/mkdir', ['mkdir']+args)\n")
                executable(scripts / "warp-zt.sh", "#!/bin/sh\nif [ \"$1\" = status ]; then\n n=$(cat \"$RUNTIME_DIR/checks\" 2>/dev/null || echo 0); n=$((n+1)); echo $n >\"$RUNTIME_DIR/checks\"; [ $n -le 7 ]; fi\n")
                (scripts / "dns-health.py").write_text("import os,pathlib,sys\np=pathlib.Path(os.environ['RUNTIME_DIR'])/'probes'\nn=int(p.read_text())+1 if p.exists() else 1\np.write_text(str(n))\nsys.exit(" + str(probe_code) + " if n in " + failures + " else 0)\n")
                executable(tmp / "sleep", "#!/usr/bin/python3\nimport time\ntime.sleep(.03)\n")
                for service in ["smartdns", "sniproxy"]:
                    executable(tmp / service, "#!/usr/bin/python3\nimport os,pathlib,time\np=pathlib.Path(os.environ['RUNTIME_DIR'])/'" + service + "-starts'\nwith p.open('a') as f: f.write('start\\n')\nwith p.with_name('" + service + "-pids').open('a') as f: f.write(str(os.getpid())+'\\n')\nwhile True: time.sleep(1)\n")
                env = dict(os.environ, PATH=f"{tmp}:" + os.environ['PATH'], UNLOCK_ROOT=str(tmp), RUNTIME_DIR=str(tmp / "run"), CONF_DIR=str(tmp), DOMAINS_FILE=str(tmp / "domains"), UPSTREAM_DNS="1.1.1.1", ENABLE_ACL="0", ENABLE_DOT="0", ENABLE_DOH="0", ENABLE_SOCKS5="0", CONTROL_CENTER_URL="", WARP_ORGANIZATION="test", ALLOWED_IPS="192.0.2.1")
                proc = subprocess.Popen(["sh", str(ROOT / "scripts/entrypoint.sh")], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    output, _ = proc.communicate(timeout=10)
                    self.assertEqual(proc.returncode, 1, output.decode())
                    self.assertEqual((tmp / "run/smartdns-starts").read_text().count("start"), expected_starts, output.decode())
                finally:
                    # SmartDNS is deliberately in its own session. Clean both
                    # the original and recovery workers, not just the entrypoint
                    # group, even if the temporary directory will be removed.
                    starts = tmp / "run/smartdns-pids"
                    if starts.exists():
                        for value in starts.read_text().splitlines():
                            try: os.killpg(int(value), signal.SIGKILL)
                            except ProcessLookupError: pass
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    proc.wait()


    def test_control_shell_supervisor_survives_nonzero_agent_exit(self):
        with tempfile.TemporaryDirectory() as name:
            tmp = pathlib.Path(name)
            scripts = tmp / "scripts"; scripts.mkdir()
            runtime = tmp / "run"; runtime.mkdir()
            target = scripts / "control-agent.sh"
            shutil.copy2(ROOT / "scripts/control-agent.sh", target)
            target.chmod(0o755)
            executable(tmp / "python3", "#!/bin/sh\nif [ \"$1\" = -c ]; then exit 0; fi\nprintf 'attempt\\n' >>\"$RUNTIME_DIR/attempts\"\nexit 7\n")
            executable(tmp / "sleep", "#!/bin/sh\nexec /bin/sleep .02\n")
            env = dict(os.environ, PATH=str(tmp)+":"+os.environ["PATH"], UNLOCK_ROOT=str(tmp), RUNTIME_DIR=str(runtime), CONTROL_CENTER_URL="wss://test.invalid/control", CONTROL_TOKEN="test", CONTROL_NODE_ID="test-1")
            proc = subprocess.Popen(["sh", "-c", '"$UNLOCK_ROOT/scripts/control-agent.sh" start; wait'], env=env, start_new_session=True)
            supervisor = None
            try:
                deadline = time.monotonic()+3
                while time.monotonic() < deadline:
                    attempts = runtime / "attempts"
                    if attempts.exists() and len(attempts.read_text().splitlines()) >= 2: break
                    time.sleep(.02)
                else: self.fail("nonzero agent exit terminated the supervisor")
                supervisor = int((runtime / "control-agent.pid").read_text())
            finally:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                if supervisor is not None:
                    try: os.kill(supervisor, signal.SIGKILL)
                    except ProcessLookupError: pass


class ControlTests(unittest.IsolatedAsyncioTestCase):
    async def test_command_timeout_reaps_descendants(self):
        with tempfile.TemporaryDirectory() as name:
            tmp = pathlib.Path(name)
            executable(tmp / "hang", "#!/bin/sh\nsleep 60 &\necho $! >\"$1\"\nwait\n")
            with patch.object(agent, "COMMAND_TIMEOUT", .1):
                with self.assertRaises(asyncio.TimeoutError):
                    await asyncio.wait_for(agent.run_command(str(tmp / "hang"), str(tmp / "child")), 3)
            pid = int((tmp / "child").read_text())
            state = pathlib.Path(f"/proc/{pid}/stat")
            self.assertTrue(not state.exists() or state.read_text().split()[2] == "Z")
            await agent.run_command("/bin/true")

    async def test_capacity_and_disconnect_cancel(self):
        class WS:
            subprotocol = agent.PROTOCOL
            sent = []
            def __init__(self): self.n = 0
            def __aiter__(self): return self
            async def __anext__(self):
                if self.n == 6: raise StopAsyncIteration
                self.n += 1
                await asyncio.sleep(0)
                return json.dumps({"type": "query", "id": self.n, "dns_message_b64": "AA"})
            async def send(self, value): self.sent.append(json.loads(value))
        ws = WS()
        cancelled = []
        async def blocked(*args):
            try: await asyncio.Event().wait()
            finally: cancelled.append(True)
        class Connect:
            async def __aenter__(self): return ws
            async def __aexit__(self, *args): pass
        with patch.object(agent.websockets, "connect", return_value=Connect()), patch.object(agent, "answer_query", blocked), patch.object(agent, "MAX_QUERIES", 2):
            await asyncio.wait_for(agent.run_once(), 2)
        self.assertEqual(len(cancelled), 2)
        self.assertEqual(sum("capacity" in x.get("error", "") for x in ws.sent), 4)

    async def test_send_is_bounded(self):
        class WS:
            async def send(self, value): await asyncio.Event().wait()
        with patch.object(agent, "SEND_TIMEOUT", .01):
            with self.assertRaises(asyncio.TimeoutError): await agent.send(WS(), {})

    async def test_dns_budget_includes_executor_queue(self):
        async def queued(*args):
            await asyncio.Event().wait()
        with patch.object(agent, "QUERY_TIMEOUT", .02), patch.object(agent.asyncio, "to_thread", queued):
            started = time.monotonic()
            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(agent.resolve_dns(b"request"), .2)
            self.assertLess(time.monotonic() - started, .15)

    async def test_main_reconnects_after_failure(self):
        calls = []
        async def once():
            calls.append(True)
            if len(calls) == 2: raise asyncio.CancelledError
            raise TimeoutError("mock ACL timeout")
        with patch.object(agent, "validate_config"), patch.object(agent, "run_once", once), patch.object(agent.asyncio, "sleep", AsyncMock()):
            with self.assertRaises(asyncio.CancelledError): await agent.main()
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
