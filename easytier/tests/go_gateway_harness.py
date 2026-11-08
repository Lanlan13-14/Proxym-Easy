"""Native Go gateway integration fixture; never imports the retired Python gateway.

EASYTIER_GATEWAY_BIN overrides /tmp/easytier-gateway-local-test. Missing/non-native
binaries FAIL (not skip); this local executable is never a release/download asset.
Only --config-fd carries the invitation JSON. A disposable Python *fake core*
implements WS echo, not a production supervisor or gateway. All files live in /tmp.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import time


def gateway_binary():
    path = Path(os.environ.get("EASYTIER_GATEWAY_BIN", "/tmp/easytier-gateway-local-test"))
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError("Native Go test binary required: set EASYTIER_GATEWAY_BIN or build /tmp/easytier-gateway-local-test")
    result = subprocess.run([str(path), "--version"], capture_output=True, timeout=5, check=True)
    if result.stdout.strip() != b"easytier-gateway 1.0.0":
        raise RuntimeError("Expected native easytier-gateway 1.0.0 test binary")
    return path.resolve()


def free_port(excluded=()):
    for _ in range(16):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        if port not in excluded:
            return port
    raise RuntimeError("Cannot reserve distinct loopback test ports")


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


class GoGateway:
    def __init__(self, payload, *, through_installer=False):
        self.payload = dict(payload)
        self.through_installer = through_installer
        self.process = None
        self._temp = None
        self._log = None

    def __enter__(self):
        try:
            self.start()
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, *exc):
        self.close()

    def start(self):
        binary = gateway_binary()
        self._temp = tempfile.TemporaryDirectory(prefix="et-go-", dir="/tmp")
        self.root = Path(self._temp.name)
        self.root.chmod(0o700)
        self.control_path = self.root / "control.sock"
        self.handshake_log = self.root / "handshakes.jsonl"
        self.config_path = self.root / "fake-core.json"
        self.config_path.write_text(json.dumps({"handshake_log": str(self.handshake_log)}))
        self.config_path.chmod(0o600)
        core = self.root / "fake-core"
        core.write_text("#!" + sys.executable + "\nimport sys\nsys.path.insert(0, "
                        + repr(str(Path(__file__).resolve().parent))
                        + ")\nfrom go_gateway_harness import fake_core_main\nfake_core_main()\n")
        core.chmod(0o700)
        port = free_port()
        rpc = free_port((port,))
        self.address = ("127.0.0.1", port)
        self.boot = dict(listen_port=port, control_path=str(self.control_path),
                         domain=self.payload["domain"], payload=self.payload,
                         core_path=str(core), config_path=str(self.config_path),
                         rpc_port=rpc, no_tun=True)
        self._log = (self.root / "gateway.log").open("w+b")
        self._start_process(binary)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self._log.seek(0)
                diagnostic = self._log.read(4096).decode(errors="replace")
                diagnostic = diagnostic.replace(self.payload["secret"], "[REDACTED]")
                raise RuntimeError("Native Go gateway exited before readiness: " + diagnostic)
            try:
                self.health = self.control("health")
                if self.health.get("gateway_version") != 3 or self.health.get("port") != port:
                    raise RuntimeError("Wrong Go gateway health response")
                return self
            except (OSError, ValueError):
                # Bounded local startup polling, not a skipped readiness check.
                threading_event_wait(0.02)
        raise RuntimeError("Native Go gateway/control socket readiness timed out")

    def _start_process(self, binary):
        if self.through_installer:
            launcher = self.root / "installer-launch.py"
            installer_script = Path(__file__).resolve().parents[1] / "easytier-cf-debian.py"
            # Paths only: this launcher never contains the secret or boot JSON.
            source = ("import importlib.util, os\nfrom pathlib import Path\n"
                      + "s=importlib.util.spec_from_file_location('exec_fixture', " + repr(str(installer_script)) + ")\n"
                      + "m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                      + "m.ROOT=Path(" + repr(str(self.root)) + ")\n"
                      + "m.STATE=m.ROOT/'settings.json'\nm.TMP=m.ROOT\n"
                      + "m.CFG=Path(" + repr(str(self.config_path)) + ")\n"
                      + "m.CORE=Path(" + repr(self.boot['core_path']) + ")\n"
                      + "m.GATEWAY=Path(" + repr(str(binary)) + ")\n"
                      + "m.RPC=" + str(self.boot['rpc_port']) + "\n"
                      + "m.control_path=lambda: m.ROOT/'control.sock'\n"
                      + "m.os.geteuid=lambda: 0\nm.serve_gateway()\n")
            state = dict(self.payload, role="server", name="server", ip="10.66.66.1/24",
                         listen_port=self.boot["listen_port"], version="v2.6.4")
            state.pop("secret")
            state["format"] = "easytier-cf-state-v1"
            state_path = self.root / "settings.json"
            state_path.write_text(json.dumps(state))
            state_path.chmod(0o600)
            with self.config_path.open("a") as config:
                config.write('\nnetwork_secret="' + self.payload["secret"] + '"\n')
            launcher.write_text(source)
            launcher.chmod(0o600)
            self.process = subprocess.Popen([sys.executable, str(launcher)], stdout=self._log,
                                            stderr=self._log, start_new_session=True)
            return
        fd = os.memfd_create("test-go-gateway-boot", os.MFD_CLOEXEC)
        try:
            os.write(fd, json.dumps(self.boot).encode())
            os.lseek(fd, 0, os.SEEK_SET)
            self.process = subprocess.Popen([str(binary), "--config-fd", str(fd)],
                                            pass_fds=(fd,), stdout=self._log,
                                            stderr=self._log, start_new_session=True)
        finally:
            os.close(fd)

    def control(self, command, token=None):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(2)
            connection.connect(str(self.control_path))
            connection.sendall(json.dumps(dict(command=command, token=token or "")).encode() + b"\n")
            with connection.makefile("rb") as stream:
                raw = stream.readline(4097)
        if len(raw) > 4096 or not raw.endswith(b"\n"):
            raise ValueError("Invalid bounded Go control response")
        result = json.loads(raw)
        if not result.get("ok"):
            raise ValueError("Go control command failed")
        return result

    def issue(self):
        return self.control("issue")["token"]

    def status(self, token):
        return self.control("status", token)["status"]

    def handshakes(self):
        if not self.handshake_log.exists():
            return []
        return [bytes.fromhex(line) for line in self.handshake_log.read_text().splitlines()]

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
        if self._log is not None:
            self._log.close()
        if self._temp is not None:
            self._temp.cleanup()


def threading_event_wait(seconds):
    # Event.wait avoids a busy startup loop and is also interruptible.
    import threading
    threading.Event().wait(seconds)


class EchoWebSocketHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        data = read_http_headers(self.request)
        if not data:
            return  # Go supervisor's TCP readiness probe.
        if b"\r\n\r\n" not in data:
            return
        with self.server.log_lock:
            with self.server.handshake_log.open("a") as log:
                log.write(data.hex() + "\n")
        headers = {}
        for line in data.split(b"\r\n")[1:]:
            if b":" in line:
                key, value = line.split(b":", 1)
                headers[key.lower()] = value.strip()
        accept = base64.b64encode(hashlib.sha1(headers.get(b"sec-websocket-key", b"")
                                             + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        self.request.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                             b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept
                             + b"\r\nX-Upstream: untouched\r\n\r\n")
        try:
            while True:
                part = self.request.recv(65536)
                if not part:
                    return
                self.request.sendall(part)
        except (ConnectionError, TimeoutError):
            return


class EchoWebSocketCore(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64


def fake_core_main():
    """Test-only executable accepting exactly the Go supervisor's core arguments."""
    import threading
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", required=True)
    parser.add_argument("--listeners", required=True)
    parser.add_argument("--rpc-portal", required=True)
    parser.add_argument("--console-log-level")
    parser.add_argument("--file-log-level")
    parser.add_argument("--no-tun", action="store_true")
    args = parser.parse_args()
    with Path(args.c).open() as config:
        settings = json.loads(config.readline())
    listener = args.listeners.removeprefix("ws://127.0.0.1:")
    with EchoWebSocketCore(("127.0.0.1", int(listener)), EchoWebSocketHandler) as core:
        core.handshake_log = Path(settings["handshake_log"])
        core.log_lock = threading.Lock()
        core.serve_forever(poll_interval=0.05)


if __name__ == "__main__":
    fake_core_main()
