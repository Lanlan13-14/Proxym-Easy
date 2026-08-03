#!/usr/bin/env python3
"""Runtime test for unlock-socks5d RFC1929 auth with free-charset credentials."""
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PORT = 19081
# Deliberately ugly credentials: symbols, colon, space, CJK, email-like.
USER = "用户@Foo:Bar 1!"
PASSWORD = "p@ss:词 字/\\~`'\""


def find_binary():
    env = os.environ.get("SOCKS5D_BIN")
    if env and Path(env).is_file() and os.access(env, os.X_OK):
        return env
    for candidate in (
        shutil.which("unlock-socks5d"),
        ROOT / "bin" / "unlock-socks5d",
        ROOT / "scripts" / "unlock-socks5d",
        Path("/usr/local/bin/unlock-socks5d"),
    ):
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    # Build on the fly for local/CI without image.
    src = ROOT / "scripts" / "socks5d.c"
    out = Path(tempfile.mkdtemp()) / "unlock-socks5d"
    subprocess.run(
        ["gcc", "-O2", "-Wall", "-Wextra", "-o", str(out), str(src)],
        check=True,
    )
    return str(out)


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        data += chunk
    return data


def socks5_handshake(user: str, password: str, expect_auth_ok: bool):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.settimeout(5)
    # methods: only user/pass
    s.sendall(b"\x05\x01\x02")
    ver, method = recv_exact(s, 2)
    if ver != 0x05 or method != 0x02:
        raise RuntimeError(f"bad method select: {ver=} {method=}")
    ub = user.encode("utf-8")
    pb = password.encode("utf-8")
    s.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
    aver, astatus = recv_exact(s, 2)
    if aver != 0x01:
        raise RuntimeError(f"bad auth ver {aver}")
    if expect_auth_ok and astatus != 0x00:
        raise RuntimeError(f"auth rejected unexpectedly status={astatus}")
    if not expect_auth_ok:
        if astatus == 0x00:
            raise RuntimeError("auth accepted bad credentials")
        s.close()
        return
    # CONNECT to 127.0.0.1:9 (discard) — may fail at TCP, but reply must be SOCKS shaped.
    # Use example.com IP path via domain ATYP for broader path coverage.
    host = b"example.com"
    req = b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", 80)
    s.sendall(req)
    # VER REP RSV ATYP ...
    hdr = recv_exact(s, 4)
    if hdr[0] != 0x05:
        raise RuntimeError(f"bad reply ver {hdr[0]}")
    # drain bound addr
    atyp = hdr[3]
    if atyp == 1:
        recv_exact(s, 4 + 2)
    elif atyp == 3:
        ln = recv_exact(s, 1)[0]
        recv_exact(s, ln + 2)
    elif atyp == 4:
        recv_exact(s, 16 + 2)
    s.close()
    # rep 0 success or 4/5 network errors both prove auth+request parsing worked
    if hdr[1] not in (0x00, 0x01, 0x03, 0x04, 0x05, 0x06):
        raise RuntimeError(f"unexpected SOCKS rep {hdr[1]}")


def main():
    binary = find_binary()
    env = os.environ.copy()
    env["SOCKS5_USERNAME"] = USER
    env["SOCKS5_PASSWORD"] = PASSWORD
    log = tempfile.NamedTemporaryFile("wb", delete=False)
    proc = subprocess.Popen(
        [binary, "--port", str(PORT), "--bind-ip", "127.0.0.1"],
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                    break
            except OSError:
                if proc.poll() is not None:
                    log.flush()
                    raise RuntimeError(Path(log.name).read_text(errors="replace"))
                time.sleep(0.05)
        else:
            raise RuntimeError("server did not listen")

        socks5_handshake(USER, PASSWORD, expect_auth_ok=True)
        socks5_handshake(USER, PASSWORD + "x", expect_auth_ok=False)
        socks5_handshake("wrong", PASSWORD, expect_auth_ok=False)
        print("SOCKS5_AUTH_PASS")
        print(f"USER_BYTES={len(USER.encode('utf-8'))}")
        print(f"PASS_BYTES={len(PASSWORD.encode('utf-8'))}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
        try:
            os.unlink(log.name)
        except OSError:
            pass


if __name__ == "__main__":
    main()
