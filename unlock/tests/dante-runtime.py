#!/usr/bin/env python3
"""Runtime test for Dante SOCKS5 username/password authentication (TCP)."""
import os
import pwd
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

USER = "sockstest"
PASSWORD = "TestPass_123"
PORT = 19080


def command(*names):
    for name in names:
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError(f"missing command: {names}")


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        data += chunk
    return data


danted = command("danted", "sockd")
chpasswd = command("chpasswd")
useradd, userdel = shutil.which("useradd"), shutil.which("userdel")
adduser, deluser = shutil.which("adduser"), shutil.which("deluser")
created = False
proc = None

try:
    try:
        pwd.getpwnam(USER)
    except KeyError:
        if useradd:
            subprocess.run([useradd, "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", USER], check=True)
        elif adduser:
            subprocess.run([adduser, "-D", "-H", USER], check=True)
        else:
            raise RuntimeError("no user creation command")
        created = True
    subprocess.run([chpasswd], input=f"{USER}:{PASSWORD}\n", text=True, check=True)

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        conf = td / "danted.conf"
        log = td / "danted.log"
        conf.write_text(f"""logoutput: stderr
internal: 127.0.0.1 port = {PORT}
external: 127.0.0.1
socksmethod: username
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass {{
 from: 127.0.0.1/32 to: 0.0.0.0/0
}}
socks pass {{
 from: 127.0.0.1/32 to: 0.0.0.0/0
 command: connect
 protocol: tcp
 socksmethod: username
}}
""")
        with log.open("wb") as lf:
            proc = subprocess.Popen([danted, "-f", str(conf)], stdout=lf, stderr=lf)
            time.sleep(0.8)
            if proc.poll() is not None:
                raise RuntimeError(log.read_text(errors="replace"))
            with socket.create_connection(("127.0.0.1", PORT), 3) as sock:
                sock.settimeout(3)
                sock.sendall(b"\x05\x01\x02")
                assert recv_exact(sock, 2) == b"\x05\x02"
                ub, pb = USER.encode(), PASSWORD.encode()
                sock.sendall(bytes((1, len(ub))) + ub + bytes((len(pb),)) + pb)
                assert recv_exact(sock, 2) == b"\x01\x00"
                print("DANTE_AUTH_PASS")
finally:
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
    if created:
        if userdel:
            subprocess.run([userdel, USER], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif deluser:
            subprocess.run([deluser, USER], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
