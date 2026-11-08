#!/usr/bin/env python3
"""Local, root-only Go gateway / official EasyTier 2.6.4 integration check.

Example (build/download the binaries separately; this script never does so):
  python3 easytier/tests/check_go_gateway_runtime.py \
    --gateway /tmp/easytier-gateway-check \
    --core /path/to/easytier-core --cli /path/to/easytier-cli

Only loopback, fresh random credentials and a private /tmp directory are used.
No TUN, Cloudflare, DNS lookup, installer action, or remote host is required.
There are 1 MiB of random echo traffic BEFORE and 1 MiB AFTER the atomic claim,
using the same SOCKS TCP stream and the same gateway WebSocket TCP connection.
Optional strace is attached only to the Go process, never used as a dependency.
Exit status: 0 = PASS, 1 = FAIL (including prerequisites); stdout is one JSON.
"""

import argparse
import concurrent.futures
import errno
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
MIB = 1024 * 1024


class CheckFailure(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


def recv_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        data = connection.recv(size - len(result))
        require(data, "unexpected EOF in SOCKS/echo stream")
        result.extend(data)
    return bytes(result)


def private_write(path, text):
    with path.open("x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        stream.write(text)


def load_client():
    source = Path(__file__).resolve().parents[1] / "easytier-cf-debian.py"
    spec = importlib.util.spec_from_file_location("go_runtime_client", source)
    require(spec is not None and spec.loader is not None, "Python client not found")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def process_identity(pid):
    try:
        # comm may contain spaces; fields following the LAST ')' start at field 3.
        tail = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return tail[19]  # field 22: starttime, also detects PID reuse
    except (FileNotFoundError, ProcessLookupError):
        return None


def direct_children(pid):
    children = set()
    task_ids = {pid}
    supported = False
    for task in Path(f"/proc/{pid}/task").iterdir():
        task_ids.add(int(task.name))
        try:
            children.update(int(x) for x in (task / "children").read_text().split())
            supported = True
        except (FileNotFoundError, ProcessLookupError):
            pass
    if not supported:
        # Some Android kernels omit CONFIG_CHECKPOINT_RESTORE (task/children).
        # Inspect PPID only; never guess a PID from process names or credentials.
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                tail = (entry / "stat").read_text().rsplit(")", 1)[1].split()
                if int(tail[1]) in task_ids and int(entry.name) not in task_ids:
                    children.add(int(entry.name))
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
    return children


def owned_tcp_streams(pid, port):
    """Identify the Go-owned, established public TCP stream, not HTTP probes."""
    inodes = set()
    for fd in Path(f"/proc/{pid}/fd").iterdir():
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        match = re.fullmatch(r"socket:\[(\d+)\]", target)
        if match:
            inodes.add(match.group(1))
    try:
        table = Path(f"/proc/{pid}/net/tcp").read_text()
    except PermissionError:
        # Android SELinux may deny /proc/net/tcp even under PRoot uid 0.
        # Retain ALL owned socket inodes instead: replacement of the public WS
        # or its upstream must still lose an inode from this stable baseline.
        return "all_gateway_socket_inodes", inodes
    result = set()
    for line in table.splitlines()[1:]:
        fields = line.split()
        if (fields[3] == "01" and int(fields[1].split(":")[1], 16) == port
                and fields[9] in inodes):
            result.add(fields[9])
    return "public_established_tcp_inode", result


class RuntimeCheck:
    def __init__(self, args, root):
        self.args, self.root = args, root
        self.report = {"result": "FAIL", "scope": "local Linux root / no-TUN / no Cloudflare",
                       "checks": {}, "random_payload_bytes": 0}
        self.stage = "prerequisites"
        self.secret, self.network = secrets.token_hex(32), "runtime-" + secrets.token_hex(8)
        self.sensitive = [self.secret]
        self.env = {"PATH": os.defpath, "HOME": str(root), "TMPDIR": str(root),
                    "LANG": "C", "LC_ALL": "C", "RUST_LOG": "warn", "NO_COLOR": "1"}
        self.processes, self.sockets, self.logs, self.reservations = [], [], [], {}
        self.gateway = self.client_process = self.tracer = None
        self.core_pid = self.core_identity = None
        self.trace_attached = False
        self.echo_thread = None
        self.echo_errors = []
        self.echo_hash = hashlib.sha256()
        self.echo_bytes = 0
        self.client = load_client()
        self.client.TMP = root / "control"
        self.client.TMP.mkdir(mode=0o700)
        self.control = self.client.control_path()

    def checked(self, name, detail="PASS"):
        self.report["checks"][name] = detail

    def redact(self, text):
        for value in self.sensitive:
            text = text.replace(value, "[REDACTED]")
        return text

    def spawn(self, argv, name, **kwargs):
        log = self.root / (name + ".log")
        self.logs.append(log)
        with log.open("wb") as stream:
            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stream,
                                       stderr=subprocess.STDOUT, env=self.env,
                                       start_new_session=True, **kwargs)
        self.processes.append(process)
        return process

    def reserve_ports(self):
        for name in ("public", "server_rpc", "client_rpc", "socks", "echo"):
            connection = socket.socket()
            connection.bind(("127.0.0.1", 0))
            self.reservations[name] = connection
            self.sockets.append(connection)
        self.ports = {name: sock.getsockname()[1]
                      for name, sock in self.reservations.items()}

    def release(self, *names):
        for name in names:
            self.reservations[name].close()

    def http(self, method, path, marked=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.ports["public"], timeout=8)
        headers = {"Host": "mesh.example.test", "Cache-Control": "no-store"}
        if marked:
            headers["X-EasyTier-Join"] = "1"
        try:
            connection.request(method, path, body=b"", headers=headers)
            response = connection.getresponse()
            body = response.read(65537)
            require(len(body) <= 65536, "HTTP response exceeds bound")
            return response.status, body, dict(response.getheaders())
        finally:
            connection.close()

    def wait_for(self, description, predicate, timeout=None):
        deadline = time.monotonic() + (timeout or self.args.timeout)
        while time.monotonic() < deadline:
            if self.gateway is not None:
                require(self.gateway.poll() is None, "gateway exited while waiting for " + description)
            if self.client_process is not None:
                require(self.client_process.poll() is None, "client core exited while waiting for " + description)
            if predicate():
                return
            time.sleep(0.1)
        raise CheckFailure("timeout waiting for " + description)

    def versions(self):
        require(sys.platform.startswith("linux"), "Linux /proc and Unix sockets are required")
        require(os.geteuid() == 0, "run this integration check as root")
        for name in ("gateway", "core", "cli"):
            path = getattr(self.args, name)
            require(path.is_file() and os.access(path, os.X_OK), name + " is not executable")
            result = subprocess.run([str(path), "--version"], capture_output=True, text=True,
                                    timeout=10, env=self.env)
            version = result.stdout.strip()
            require(result.returncode == 0, name + " --version failed")
            expected = (r"easytier-gateway 1\.0\.0" if name == "gateway" else
                        r"easytier-" + name + r" 2\.6\.4(?:-[A-Za-z0-9.]+)?")
            require(re.fullmatch(expected, version), name + " has an unexpected version")
            self.report[name + "_version"] = version
        self.checked("binary_versions")

    def start_gateway(self):
        self.reserve_ports()
        self.payload = dict(format="easytier-cf-join-v1", domain="mesh.example.test",
                            network=self.network, secret=self.secret,
                            subnet="10.66.66.0/24", server_name="server")
        base = dict(self.payload, role="server", name="server", ip="10.66.66.1/24",
                    listen_port=self.ports["public"])
        server_text = self.client.render(base, "v2.6.4").replace("no_tun = false", "no_tun = true")
        server_text = server_text.replace("[flags]", '[[proxy_network]]\ncidr="127.0.0.1/32"\n'
                                          'mapped_cidr="10.77.77.1/32"\nallow=["tcp"]\n\n[flags]')
        server_cfg, client_cfg = self.root / "server.toml", self.root / "client.toml"
        private_write(server_cfg, server_text)
        client_text = self.client.render(dict(base, role="client", name="client", ip="10.66.66.2/24"),
                                         "v2.6.4").replace("no_tun = false", "no_tun = true")
        client_text = client_text.replace("wss://mesh.example.test:443/",
                                          f'ws://127.0.0.1:{self.ports["public"]}/')
        client_text = client_text.replace("[network_identity]",
                      f'socks5_proxy = "socks5://127.0.0.1:{self.ports["socks"]}"\n\n[network_identity]')
        private_write(client_cfg, client_text)
        boot = dict(listen_port=self.ports["public"], control_path=str(self.control),
                    domain=self.payload["domain"], payload=self.payload, core_path=str(self.args.core),
                    config_path=str(server_cfg), rpc_port=self.ports["server_rpc"], no_tun=True)
        raw = json.dumps(boot, separators=(",", ":")).encode()
        require(len(raw) <= 65536, "BootConfig exceeds 64 KiB")
        self.release("public", "server_rpc")
        read_fd, write_fd = os.pipe()
        try:
            self.gateway = self.spawn([str(self.args.gateway), "--config-fd", str(read_fd)],
                                      "gateway", pass_fds=(read_fd,))
            os.close(read_fd)
            read_fd = -1
            with os.fdopen(write_fd, "wb") as stream:
                write_fd = -1
                stream.write(raw)
        finally:
            if read_fd >= 0:
                os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)
        self.wait_for("Unix control readiness", self.control.exists)
        self.health = self.client.control_call("health")
        require(self.health.get("gateway_version") == 3 and self.health.get("port") == self.ports["public"]
                and self.health.get("domain") == self.payload["domain"]
                and re.fullmatch(r"[0-9a-f]{32}", str(self.health.get("instance_id"))),
                "Python control_call health mismatch")
        require(stat.S_ISSOCK(self.control.stat().st_mode)
                and stat.S_IMODE(self.control.stat().st_mode) == 0o600, "control socket must be 0600")
        children = direct_children(self.gateway.pid)
        require(len(children) == 1, "gateway must own exactly one official core child: " + str(sorted(children)))
        self.core_pid = children.pop()
        self.core_identity = process_identity(self.core_pid)
        argv = Path(f"/proc/{self.core_pid}/cmdline").read_bytes().split(b"\0")
        require(argv[0] == os.fsencode(self.args.core), "supervised child is not the requested official core")
        listener = argv[argv.index(b"--listeners") + 1].decode()
        require(re.fullmatch(r"ws://127\.0\.0\.1:[0-9]+", listener), "core listener is not local WS")
        self.core_port = int(listener.rsplit(":", 1)[1])
        require(b"--no-tun" in argv, "BootConfig no_tun was not passed to supervised core")
        self.checked("inherited_fd_boot_and_python_control_health")
        self.checked("official_core_supervision_no_tun")
        self.release("client_rpc", "socks")
        self.client_process = self.spawn([str(self.args.core), "-c", str(client_cfg), "--rpc-portal",
                    f'127.0.0.1:{self.ports["client_rpc"]}', "--console-log-level", "warn",
                    "--file-log-level", "off", "--no-tun"], "client")
        self.wait_for("official WS peer", self.peer_ready)
        self.start_trace()
        self.stream_mode, self.stream_inodes = owned_tcp_streams(self.gateway.pid, self.ports["public"])
        require(len(self.stream_inodes) == 1 if self.stream_mode == "public_established_tcp_inode"
                else len(self.stream_inodes) >= 4, "cannot identify stable Go-owned WebSocket sockets")
        self.report["stream_identity_method"] = self.stream_mode
        self.checked("official_ws_peer_via_public_port")

    def stream_stable(self):
        mode, current = owned_tcp_streams(self.gateway.pid, self.ports["public"])
        return mode == self.stream_mode and (current == self.stream_inodes
            if mode == "public_established_tcp_inode" else self.stream_inodes <= current)

    def peer_ready(self):
        try:
            result = subprocess.run([str(self.args.cli), "-p", f'127.0.0.1:{self.ports["client_rpc"]}',
                                     "-o", "json", "peer"], capture_output=True, text=True,
                                    timeout=3, env=self.env)
            peers = json.loads(result.stdout) if result.returncode == 0 else []
        except (ValueError, subprocess.TimeoutExpired):
            return False
        return isinstance(peers, list) and any(isinstance(peer, dict) and peer.get("hostname") == "server"
                                      and peer.get("tunnel_proto") == "ws" for peer in peers)

    def start_trace(self):
        self.trace_path = self.root / "splice.trace"
        executable = shutil.which("strace")
        if self.args.no_strace or executable is None:
            self.report["splice"] = {"result": "SKIP", "reason": "disabled or strace not installed"}
            return
        self.tracer = self.spawn([executable, "-f", "-qq", "-e", "trace=splice", "-o",
                                  str(self.trace_path), "-p", str(self.gateway.pid)], "strace")
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline and self.tracer.poll() is None:
            status = Path(f"/proc/{self.gateway.pid}/status").read_text()
            match = re.search(r"^TracerPid:\s+(\d+)", status, re.MULTILINE)
            if match and int(match.group(1)) == self.tracer.pid:
                self.trace_attached = True
                return
            time.sleep(0.05)
        self.report["splice"] = {"result": "SKIP", "reason": "ptrace attach unavailable"}

    def finish_trace(self):
        if self.tracer is None:
            return
        try:
            self.tracer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.tracer.terminate()
            try:
                self.tracer.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.tracer.kill()
                self.tracer.wait(timeout=3)
        text = self.trace_path.read_text(errors="replace") if self.trace_path.exists() else ""
        positive = re.findall(r"(?:splice\(.*|<\.\.\. splice resumed>.*)\s+=\s+([1-9][0-9]*)\b", text)
        if positive:
            self.report["splice"] = {"result": "PASS", "positive_calls": len(positive),
                                     "kernel_bytes": sum(map(int, positive))}
        else:
            require(not self.trace_attached, "strace attached successfully but observed no positive splice")
            self.report["splice"] = {"result": "SKIP", "reason": "ptrace unavailable or no usable trace"}

    def secret_process_check(self):
        for label, pid in (("gateway", self.gateway.pid), ("supervised core", self.core_pid),
                           ("client core", self.client_process.pid)):
            for entry in ("cmdline", "environ"):
                data = Path(f"/proc/{pid}/{entry}").read_bytes()
                require(data, label + " " + entry + " could not be inspected")
                for value in self.sensitive:
                    require(value.encode() not in data, label + " leaked test credentials in " + entry)
                require(self.network.encode() not in data, label + " leaked network name in " + entry)
        self.checked("proc_argv_env_no_network_secret_or_invite_tokens")

    def issue(self):
        result = self.client.control_call("issue")
        token = result.get("token")
        require(isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64}", token), "invalid issued token")
        self.sensitive.append(token)
        require(result.get("domain") == self.payload["domain"] and result.get("ttl") == 900,
                "Python control_call issue fields mismatch")
        require(self.client.control_call("status", token).get("status") == "active", "new token is not active")
        return token

    def proof_and_prefetch(self, token):
        nonce = secrets.token_hex(16)
        path = "/join/check/" + nonce
        for method in ("GET", "HEAD"):
            for target in ("/join/" + token, path):
                # Link previewers do not send the join marker; neither may a
                # caller with the marker consume via an unsafe method.
                for marked in (False, True):
                    status, body, _ = self.http(method, target, marked=marked)
                    require(status == 405 and not body, method + " must not disclose/consume invitation")
                    require(self.client.control_call("status", token).get("status") == "active",
                            method + " consumed invitation")
        status, body, _ = self.http("POST", "/join/" + token, marked=False)
        require(status == 404 and not body, "unmarked POST must not consume invitation")
        require(self.client.control_call("status", token).get("status") == "active", "unmarked POST consumed token")
        status, body, headers = self.http("POST", path)
        require(status == 200, "non-secret instance proof POST failed")
        proof = json.loads(body)
        require(proof == {"format": "easytier-cf-gateway-v1", "nonce": nonce,
                          "instance_id": self.health["instance_id"]}, "proof/control instance mismatch or extra fields")
        require(self.secret.encode() not in body and self.network.encode() not in body
                and token.encode() not in body, "proof disclosed network credential/token")
        require("no-store" in headers.get("Cache-Control", ""), "proof can be cached")
        require(self.client.control_call("status", token).get("status") == "active", "proof consumed invitation")
        instance = self.client.probe_tunnel_endpoint(f'http://127.0.0.1:{self.ports["public"]}' + path, nonce)
        require(instance == self.health["instance_id"], "Python probe did not match Unix control instance")
        self.checked("get_head_and_unmarked_post_do_not_consume")
        self.checked("nonsecret_nonce_proof_matches_control_instance")

    def start_echo(self):
        listener = self.reservations["echo"]
        listener.listen(1)
        listener.settimeout(self.args.timeout + 30)
        self.echo_connection = None

        def echo():
            try:
                connection, _ = listener.accept()
                self.echo_connection = connection
                self.sockets.append(connection)
                connection.settimeout(self.args.timeout + 30)
                with connection:
                    while True:
                        data = connection.recv(65536)
                        if not data:
                            break
                        self.echo_hash.update(data)
                        self.echo_bytes += len(data)
                        connection.sendall(data)
            except OSError as exc:
                self.echo_errors.append(type(exc).__name__)
            finally:
                listener.close()

        self.echo_thread = threading.Thread(target=echo, name="local-random-echo", daemon=True)
        self.echo_thread.start()
        deadline = time.monotonic() + self.args.timeout
        while True:
            try:
                stream = socket.create_connection(("127.0.0.1", self.ports["socks"]), timeout=2)
                break
            except OSError:
                require(time.monotonic() < deadline, "SOCKS listener not ready")
                require(self.client_process.poll() is None, "client exited before SOCKS readiness")
                time.sleep(0.1)
        self.sockets.append(stream)
        stream.settimeout(self.args.timeout)
        stream.sendall(b"\x05\x01\x00")
        require(recv_exact(stream, 2) == b"\x05\x00", "SOCKS authentication negotiation failed")
        stream.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("10.77.77.1")
                       + self.ports["echo"].to_bytes(2, "big"))
        header = recv_exact(stream, 4)
        require(header[:3] == b"\x05\x00\x00", "SOCKS connection to EasyTier mapped route failed")
        sizes = {1: 4, 4: 16}
        size = recv_exact(stream, 1)[0] if header[3] == 3 else sizes.get(header[3])
        require(size is not None, "invalid SOCKS bind address type")
        recv_exact(stream, size + 2)
        self.echo_stream = stream
        self.sent_hash, self.received_hash = hashlib.sha256(), hashlib.sha256()

    def transfer(self, label):
        sent, received = hashlib.sha256(), hashlib.sha256()
        for _ in range(16):
            payload = os.urandom(65536)
            self.echo_stream.sendall(payload)
            echoed = recv_exact(self.echo_stream, len(payload))
            require(echoed == payload, "EasyTier echo payload mismatch " + label)
            sent.update(payload)
            received.update(echoed)
            self.sent_hash.update(payload)
            self.received_hash.update(echoed)
        require(sent.digest() == received.digest(), "EasyTier SHA-256 mismatch " + label)
        require(self.stream_stable(),
                "gateway WebSocket TCP stream reconnected " + label)
        self.report[label] = {"bytes": MIB, "sha256_sent": sent.hexdigest(),
                              "sha256_received": received.hexdigest()}
        self.report["random_payload_bytes"] += MIB

    def atomic_claim(self, token):
        attempts = 16
        barrier = threading.Barrier(attempts)

        def claim(_):
            barrier.wait(timeout=10)
            return self.http("POST", "/join/" + token)

        with concurrent.futures.ThreadPoolExecutor(max_workers=attempts) as pool:
            results = list(pool.map(claim, range(attempts)))
        statuses = [status for status, _, _ in results]
        require(statuses.count(200) == 1 and statuses.count(404) == attempts - 1,
                "concurrent claim was not atomic: " + str(statuses))
        for status, body, headers in results:
            if status == 200:
                require(json.loads(body) == self.payload, "claimed six-field payload mismatch")
                require(self.client.parse_join(body) == self.payload, "Python join parser incompatible")
                require("no-store" in headers.get("Cache-Control", ""), "invitation response can be cached")
            else:
                require(not body, "rejected claimant received a response body")
        require(self.client.control_call("status", token).get("status") == "consumed",
                "Python status did not observe atomic consumption")
        status, body, _ = self.http("POST", "/join/" + token)
        require(status == 404 and not body, "consumed invitation could be replayed")
        self.checked("atomic_once_claim_and_replay", {"result": "PASS", "concurrent_posts": attempts,
                                                     "successes": 1, "rejected": attempts - 1})

    def management(self):
        old, current = self.issue(), self.issue()
        require(old != current, "successive issue returned duplicate token")
        require(self.client.control_call("status", old).get("status") == "superseded", "old token not superseded")
        require(self.client.control_call("revoke", old).get("status") == "superseded", "stale revoke status mismatch")
        require(self.client.control_call("status", current).get("status") == "active", "stale revoke revoked new token")
        require(self.client.control_call("revoke", current).get("status") == "revoked", "Python revoke incompatible")
        require(self.client.control_call("status", current).get("status") == "revoked", "revoked status mismatch")
        for token in (old, current):
            status, body, _ = self.http("POST", "/join/" + token)
            require(status == 404 and not body, "superseded/revoked token remained claimable")
        self.checked("python_control_issue_status_revoke_supersession")

    def finish_echo(self):
        self.echo_stream.shutdown(socket.SHUT_WR)
        require(self.echo_stream.recv(1) == b"", "echo stream did not half-close")
        self.echo_stream.close()
        self.echo_thread.join(timeout=5)
        require(not self.echo_thread.is_alive() and not self.echo_errors, "echo worker did not finish cleanly")
        require(self.echo_bytes == 2 * MIB and self.echo_hash.digest() == self.sent_hash.digest()
                == self.received_hash.digest(), "end-to-end 2 MiB hashes/size mismatch")
        self.report["sha256_sent"] = self.sent_hash.hexdigest()
        self.report["sha256_received"] = self.received_hash.hexdigest()
        self.report["sha256_echo_server"] = self.echo_hash.hexdigest()
        self.checked("two_mib_random_echo_same_tcp_stream_across_claim")

    @staticmethod
    def expect_eof(connection, description):
        connection.settimeout(2)
        try:
            require(connection.recv(1) == b"", description + " remained open")
        except ConnectionResetError:
            pass

    def shutdown_check(self):
        require(self.stream_stable(),
                "WebSocket TCP changed before shutdown")
        # Keep incomplete requests open so shutdown must close accepted connections
        # as well as unlinking the control pathname and closing listening sockets.
        held_control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sockets.append(held_control)
        held_control.settimeout(2)
        held_control.connect(str(self.control))
        held_control.sendall(b"{")
        held_http = socket.create_connection(("127.0.0.1", self.ports["public"]), timeout=2)
        self.sockets.append(held_http)
        held_http.sendall(b"GET /")
        time.sleep(0.05)
        self.gateway.send_signal(signal.SIGTERM)
        require(self.gateway.wait(timeout=15) == 0, "gateway SIGTERM exit status was not zero")
        require(not self.control.exists(), "SIGTERM left the Unix control socket behind")
        require(process_identity(self.core_pid) != self.core_identity, "SIGTERM did not reap supervised core")
        self.expect_eof(held_control, "accepted control connection")
        self.expect_eof(held_http, "accepted HTTP connection")
        for port in (self.ports["public"], self.core_port, self.ports["server_rpc"]):
            with socket.socket() as connection:
                connection.settimeout(1)
                result = connection.connect_ex(("127.0.0.1", port))
                require(result in (errno.ECONNREFUSED, errno.ENOENT), "gateway/core listener survived SIGTERM")
        self.checked("sigterm_reaps_core_unlinks_control_and_closes_listeners")
        self.checked("sigterm_closes_accepted_http_and_control_connections")
        self.finish_trace()

    def run(self):
        self.stage = "versions"
        self.versions()
        self.stage = "gateway/core startup"
        self.start_gateway()
        self.stage = "process argv/environment inspection"
        self.secret_process_check()
        self.stage = "non-consuming HTTP and instance proof"
        token = self.issue()
        self.proof_and_prefetch(token)
        self.stage = "SOCKS mapped EasyTier route"
        self.start_echo()
        self.stage = "random traffic before claim"
        self.transfer("before_claim")
        self.stage = "concurrent same-port claim"
        self.atomic_claim(token)
        self.stage = "random traffic after claim"
        self.transfer("after_claim")
        self.stage = "Python control management"
        self.management()
        self.secret_process_check()
        self.stage = "end-to-end payload hash"
        self.finish_echo()
        self.stage = "SIGTERM cleanup"
        self.shutdown_check()
        self.report["result"] = "PASS"

    def cleanup(self):
        errors = []
        # First give the real supervisor a chance to stop its own child, even on
        # an earlier assertion failure. Fall back only for test-owned processes.
        for process in reversed(self.processes):
            if process.poll() is None:
                try:
                    process.terminate()
                    process.wait(timeout=12)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        process.kill()
                        process.wait(timeout=3)
                    except (OSError, subprocess.TimeoutExpired):
                        errors.append("test-owned process could not be reaped")
        if self.core_pid is not None and process_identity(self.core_pid) == self.core_identity:
            try:
                os.kill(self.core_pid, signal.SIGKILL)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and process_identity(self.core_pid) == self.core_identity:
                    time.sleep(0.05)
                if process_identity(self.core_pid) == self.core_identity:
                    errors.append("orphaned supervised core remains")
            except ProcessLookupError:
                pass
        for connection in self.sockets:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass
        if self.echo_thread is not None:
            self.echo_thread.join(timeout=3)
            if self.echo_thread.is_alive():
                errors.append("echo worker remains")
        return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gateway", required=True, type=Path, help="Go gateway executable")
    parser.add_argument("--core", required=True, type=Path, help="official EasyTier 2.6.4 core")
    parser.add_argument("--cli", required=True, type=Path, help="official EasyTier 2.6.4 CLI")
    parser.add_argument("--timeout", type=float, default=30, help="readiness / stream timeout in seconds (default: 30)")
    parser.add_argument("--no-strace", action="store_true", help="skip optional splice syscall observation")
    args = parser.parse_args()
    if not 5 <= args.timeout <= 120:
        parser.error("--timeout must be between 5 and 120 seconds")
    for name in ("gateway", "core", "cli"):
        setattr(args, name, getattr(args, name).resolve())
    previous_umask = os.umask(0o077)
    report = {"result": "FAIL"}
    check = None
    tmp_path = None
    original_handlers = {}

    def interrupted(signum, _frame):
        raise CheckFailure("verification interrupted by signal " + str(signum))

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            original_handlers[signum] = signal.signal(signum, interrupted)
        # /tmp is deliberate: do not trust inherited TMPDIR with world-writable
        # or symlink ancestors; the Go control server verifies its full path.
        with tempfile.TemporaryDirectory(prefix="et-go-check-", dir="/tmp") as directory:
            tmp_path = Path(directory)
            try:
                check = RuntimeCheck(args, tmp_path)
                report = check.report
                check.run()
            except Exception as exc:
                report["result"] = "FAIL"
                report["stage"] = check.stage if check else "initialization"
                message = type(exc).__name__ + ": " + str(exc)
                report["error"] = check.redact(message) if check else message
                if check:
                    report["log_tails"] = {path.name: check.redact(path.read_text(errors="replace")[-2500:])
                                           for path in check.logs if path.exists()}
            finally:
                if check:
                    cleanup_errors = check.cleanup()
                    if cleanup_errors:
                        report["result"] = "FAIL"
                        report["cleanup_errors"] = cleanup_errors
        require(tmp_path is None or not tmp_path.exists(), "private temporary directory was not removed")
        report["private_tmp_removed"] = True
    except Exception as exc:
        report["result"] = "FAIL"
        report["cleanup_error"] = type(exc).__name__ + ": " + str(exc)
    finally:
        os.umask(previous_umask)
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)
    print(json.dumps(report, sort_keys=True, ensure_ascii=False))
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
