#!/usr/bin/env python3
"""Bounded liveness probe using the current static rules and UDP listener.

Exit 2 means the config has no applicable static probe, not that DNS is dead.
Never turn a supported custom config into a container restart loop.
"""
import ipaddress
import os
import pathlib
import re
import secrets
import socket
import struct
import sys


class ProbeUnavailable(ValueError):
    pass


def skip_name(data, pos):
    for _ in range(128):
        length = data[pos]
        if length == 0:
            return pos + 1
        if length & 0xc0 == 0xc0:
            if pos + 1 >= len(data):
                raise ValueError("short DNS pointer")
            return pos + 2
        if length > 63 or pos + length + 1 >= len(data):
            raise ValueError("bad DNS label")
        pos += length + 1
    raise ValueError("bad DNS name")


def probe_target(lines):
    for line in lines:
        fields = line.split()
        if len(fields) < 2 or fields[0] != "bind":
            continue
        host, port = fields[1].rsplit(":", 1)
        host = host.strip("[]")
        if host in ("", "*", "0.0.0.0"):
            host = "127.0.0.1"
        elif host == "::":
            host = "::1"
        try:
            address = ipaddress.ip_address(host)
            port = int(port)
            if not 1 <= port <= 65535:
                raise ValueError("invalid listener port")
        except ValueError as exc:
            raise ProbeUnavailable("unsupported UDP listener") from exc
        return (socket.AF_INET6 if address.version == 6 else socket.AF_INET,
                str(address), port, "-force-aaaa-soa" in fields[2:])
    raise ProbeUnavailable("no UDP listener to probe")


def static_question(lines, force_aaaa_soa):
    for line in lines:
        fields = line.split()
        if len(fields) != 2 or fields[0] != "address":
            continue
        parts = fields[1].split("/")
        if len(parts) != 3:
            continue
        name = parts[1].rstrip(".")
        labels = name.split(".")
        if not name or any(not re.fullmatch(r"[A-Za-z0-9_-]{1,63}", label) for label in labels):
            continue
        addresses = []
        for value in parts[2].split(","):
            try:
                addresses.append(ipaddress.ip_address(value))
            except ValueError:
                pass
        for version, qtype in ((4, 1), (6, 28)):
            if version == 6 and force_aaaa_soa:
                continue
            expected = {address.packed for address in addresses if address.version == version}
            if expected:
                question = b"".join(bytes([len(label)]) + label.encode("ascii") for label in labels)
                return question + b"\0" + struct.pack("!HH", qtype, 1), qtype, expected
    raise ProbeUnavailable("no applicable static unlock rule; liveness recovery skipped")


def probe():
    config = pathlib.Path(os.environ.get("CONF_DIR", "/etc/unlock")) / "smartdns.conf"
    lines = config.read_text().splitlines()
    family, host, port, force_aaaa_soa = probe_target(lines)
    question, qtype, expected = static_question(lines, force_aaaa_soa)
    txid = secrets.randbelow(65536)
    wire = struct.pack("!HHHHHH", txid, 0x100, 1, 0, 0, 0) + question
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2)
        sock.connect((host, port))
        sock.send(wire)
        data = sock.recv(65535)
    ident, flags, qd, an, _, _ = struct.unpack("!HHHHHH", data[:12])
    if ident != txid or not flags & 0x8000 or flags & 0x020f or qd != 1:
        raise ValueError("invalid DNS response")
    pos = skip_name(data, 12) + 4
    for _ in range(an):
        pos = skip_name(data, pos)
        kind, cls, _, size = struct.unpack("!HHIH", data[pos:pos + 10])
        pos += 10
        value = data[pos:pos + size]
        pos += size
        if kind == qtype and cls == 1 and value in expected:
            return
    raise ValueError("static unlock address missing")


if __name__ == "__main__":
    try:
        probe()
    except ProbeUnavailable as exc:
        print(f" >> [dns-health] not applicable: {exc}", file=sys.stderr)
        sys.exit(2)
    except Exception as exc:
        print(f" >> [dns-health] {exc}", file=sys.stderr)
        sys.exit(1)
