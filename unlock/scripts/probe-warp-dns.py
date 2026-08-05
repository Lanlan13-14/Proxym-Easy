#!/usr/bin/env python3
"""Probe WARP egress + recursive DNS without dig/nslookup.

Tests the hop that unlock other-passthrough depends on:
  SmartDNS (or direct) → UPSTREAM (default 1.1.1.1) via WARP tunnel.

Usage (inside unlock container or any host with Python 3):
  python3 /opt/unlock/scripts/probe-warp-dns.py
  python3 probe-warp-dns.py --loops 50 --names youtube.com,example.com
  python3 probe-warp-dns.py --no-warp-check   # DNS only
  python3 probe-warp-dns.py --json

Exit codes:
  0  all required checks ok
  1  DNS failures above threshold / no answers
  2  WARP not on (when warp check enabled)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import socket
import struct
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Sequence, Tuple

DEFAULT_UPSTREAMS = ("1.1.1.1", "1.0.0.1", "8.8.8.8")
DEFAULT_NAMES = ("youtube.com", "example.com", "github.com", "cloudflare.com")
TRACE_URLS = (
    "https://1.1.1.1/cdn-cgi/trace",
    "https://cloudflare.com/cdn-cgi/trace",
)


def encode_name(name: str) -> bytes:
    out = bytearray()
    for label in name.rstrip(".").split("."):
        if not label or len(label) > 63:
            raise ValueError(f"bad label in {name!r}")
        b = label.encode("idna")
        out.append(len(b))
        out.extend(b)
    out.append(0)
    return bytes(out)


def build_query(qname: str, qtype: int = 1) -> Tuple[bytes, int]:
    """A=1, AAAA=28. Returns (wire, txid)."""
    txid = random.randint(1, 0xFFFF)
    # RD=1
    header = struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    question = encode_name(qname) + struct.pack("!HH", qtype, 1)  # IN
    return header + question, txid


def skip_name(buf: bytes, offset: int) -> int:
    n = len(buf)
    while offset < n:
        length = buf[offset]
        if length == 0:
            return offset + 1
        if length & 0xC0 == 0xC0:  # compression pointer
            return offset + 2
        offset += 1 + length
    raise ValueError("truncated name")


def parse_a_answers(buf: bytes, expect_txid: int) -> Tuple[str, List[str], int]:
    """Return (rcode_name, a_records, ancount)."""
    if len(buf) < 12:
        raise ValueError("short response")
    txid, flags, _qd, an, _ns, _ar = struct.unpack("!HHHHHH", buf[:12])
    if txid != expect_txid:
        raise ValueError(f"txid mismatch {txid:#x}!={expect_txid:#x}")
    rcode = flags & 0xF
    rcode_name = {
        0: "NOERROR",
        1: "FORMERR",
        2: "SERVFAIL",
        3: "NXDOMAIN",
        4: "NOTIMP",
        5: "REFUSED",
    }.get(rcode, f"RCODE{rcode}")
    offset = 12
    # skip questions
    qd = _qd
    for _ in range(qd):
        offset = skip_name(buf, offset)
        offset += 4  # type class
    addrs: List[str] = []
    for _ in range(an):
        offset = skip_name(buf, offset)
        if offset + 10 > len(buf):
            break
        rtype, _rclass, _ttl, rdlen = struct.unpack("!HHIH", buf[offset : offset + 10])
        offset += 10
        rdata = buf[offset : offset + rdlen]
        offset += rdlen
        if rtype == 1 and rdlen == 4:  # A
            addrs.append(socket.inet_ntoa(rdata))
        elif rtype == 28 and rdlen == 16:  # AAAA
            addrs.append(socket.inet_ntop(socket.AF_INET6, rdata))
    return rcode_name, addrs, an


def dns_query(
    server: str,
    qname: str,
    *,
    port: int = 53,
    timeout: float = 2.0,
    qtype: int = 1,
    use_tcp: bool = False,
) -> Dict[str, Any]:
    wire, txid = build_query(qname, qtype)
    t0 = time.perf_counter()
    try:
        if use_tcp:
            with socket.create_connection((server, port), timeout=timeout) as sock:
                sock.settimeout(timeout)
                sock.sendall(struct.pack("!H", len(wire)) + wire)
                hdr = _recvexact(sock, 2)
                (length,) = struct.unpack("!H", hdr)
                if length > 65535:
                    raise ValueError("bad tcp length")
                resp = _recvexact(sock, length)
        else:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(timeout)
                sock.sendto(wire, (server, port))
                resp, _ = sock.recvfrom(65535)
        ms = (time.perf_counter() - t0) * 1000
        rcode, addrs, an = parse_a_answers(resp, txid)
        ok = rcode == "NOERROR" and (bool(addrs) or an == 0)
        # for A lookups we want at least one A for "success" of connectivity
        if qtype == 1:
            ok = rcode == "NOERROR" and bool(addrs)
        return {
            "ok": ok,
            "server": server,
            "port": port,
            "tcp": use_tcp,
            "qname": qname,
            "rcode": rcode,
            "addrs": addrs,
            "ms": round(ms, 1),
            "error": None,
        }
    except Exception as exc:  # noqa: BLE001 — probe tool, surface any failure
        ms = (time.perf_counter() - t0) * 1000
        return {
            "ok": False,
            "server": server,
            "port": port,
            "tcp": use_tcp,
            "qname": qname,
            "rcode": None,
            "addrs": [],
            "ms": round(ms, 1),
            "error": f"{type(exc).__name__}: {exc}",
        }


def _recvexact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("tcp closed")
        buf.extend(chunk)
    return bytes(buf)


def fetch_warp_trace(timeout: float = 10.0) -> Dict[str, Any]:
    last_err: Optional[str] = None
    for url in TRACE_URLS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "probe-warp-dns/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", "replace")
            fields = {}
            for line in body.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    fields[k.strip()] = v.strip()
            warp = fields.get("warp", "")
            return {
                "ok": warp in {"on", "plus"},
                "url": url,
                "warp": warp,
                "ip": fields.get("ip"),
                "loc": fields.get("loc"),
                "colo": fields.get("colo"),
                "gateway": fields.get("gateway"),
                "raw": fields,
                "error": None,
            }
        except Exception as exc:  # noqa: BLE001
            last_err = f"{type(exc).__name__}: {exc}"
    return {
        "ok": False,
        "url": None,
        "warp": None,
        "ip": None,
        "loc": None,
        "colo": None,
        "gateway": None,
        "raw": {},
        "error": last_err or "trace failed",
    }


def parse_upstreams(env_val: Optional[str]) -> List[str]:
    if not env_val:
        return list(DEFAULT_UPSTREAMS)
    out: List[str] = []
    for part in env_val.split(","):
        part = part.strip()
        if not part:
            continue
        # host or host:port or https://host — keep host only for UDP 53 probe
        if "://" in part:
            part = part.split("://", 1)[1]
        host = part.split("/")[0].split(":")[0]
        if host:
            out.append(host)
    return out or list(DEFAULT_UPSTREAMS)


def run_once(
    servers: Sequence[Tuple[str, int, bool]],
    names: Sequence[str],
    timeout: float,
) -> List[Dict[str, Any]]:
    results = []
    for server, port, use_tcp in servers:
        for name in names:
            results.append(
                dns_query(server, name, port=port, timeout=timeout, use_tcp=use_tcp)
            )
    return results


def summarize(results: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    by_server: Dict[str, Dict[str, int]] = {}
    for r in results:
        key = f"{r['server']}:{r['port']}{'/tcp' if r['tcp'] else '/udp'}"
        slot = by_server.setdefault(key, {"ok": 0, "fail": 0})
        if r["ok"]:
            slot["ok"] += 1
        else:
            slot["fail"] += 1
    return by_server


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Probe WARP + recursive DNS without dig")
    p.add_argument(
        "--names",
        default=",".join(DEFAULT_NAMES),
        help="comma-separated domains (default: youtube + other-like names)",
    )
    p.add_argument(
        "--upstreams",
        default=os.environ.get("UPSTREAM_DNS", ",".join(DEFAULT_UPSTREAMS)),
        help="comma-separated recursive resolvers (default: $UPSTREAM_DNS or 1.1.1.1…)",
    )
    p.add_argument(
        "--smartdns",
        default="127.0.0.1",
        help="SmartDNS address (default 127.0.0.1). Empty to skip.",
    )
    p.add_argument(
        "--smartdns-port",
        type=int,
        default=int(os.environ.get("DNS_UDP_PORT", "53")),
        help="SmartDNS port (default $DNS_UDP_PORT or 53)",
    )
    p.add_argument("--timeout", type=float, default=2.0, help="per-query timeout seconds")
    p.add_argument("--loops", type=int, default=1, help="repeat DNS probes N times")
    p.add_argument("--tcp", action="store_true", help="also try DNS-over-TCP to upstreams")
    p.add_argument("--no-warp-check", action="store_true", help="skip cdn-cgi/trace")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    p.add_argument(
        "--unlock-ip",
        default=os.environ.get("UNLOCK_IP", ""),
        help="if set, warn when other-domain resolves to this IP (hijack leak)",
    )
    args = p.parse_args(argv)

    names = [n.strip().rstrip(".") for n in args.names.split(",") if n.strip()]
    upstreams = parse_upstreams(args.upstreams)
    servers: List[Tuple[str, int, bool]] = [(u, 53, False) for u in upstreams]
    if args.tcp:
        servers.extend((u, 53, True) for u in upstreams)
    if args.smartdns:
        servers.append((args.smartdns, args.smartdns_port, False))

    report: Dict[str, Any] = {
        "warp": None,
        "loops": args.loops,
        "names": names,
        "upstreams": upstreams,
        "results": [],
        "summary": {},
        "hijack_warnings": [],
    }

    if not args.no_warp_check:
        report["warp"] = fetch_warp_trace()

    all_results: List[Dict[str, Any]] = []
    for i in range(max(1, args.loops)):
        batch = run_once(servers, names, args.timeout)
        for r in batch:
            r["loop"] = i + 1
        all_results.extend(batch)

    report["results"] = all_results
    report["summary"] = summarize(all_results)

    unlock_ip = (args.unlock_ip or "").strip()
    if unlock_ip:
        for r in all_results:
            if r["ok"] and unlock_ip in r["addrs"] and r["qname"] not in {
                # only warn for names that should be real CDN, not stream hijacks
            }:
                # any success resolving other names to UNLOCK_IP is wrong for this probe's defaults
                if r["qname"] in set(DEFAULT_NAMES) or r["server"] in upstreams:
                    report["hijack_warnings"].append(
                        {
                            "qname": r["qname"],
                            "server": r["server"],
                            "addrs": r["addrs"],
                            "unlock_ip": unlock_ip,
                        }
                    )

    # verdict
    warp_ok = True if args.no_warp_check else bool(report["warp"] and report["warp"]["ok"])
    # require at least one successful direct upstream query for youtube-like names
    direct_ok = any(
        r["ok"] and r["server"] in upstreams and not r["tcp"] for r in all_results
    )
    smartdns_ok = True
    if args.smartdns:
        smartdns_ok = any(
            r["ok"] and r["server"] == args.smartdns for r in all_results
        )
    # failure rate on direct UDP upstreams
    direct = [r for r in all_results if r["server"] in upstreams and not r["tcp"]]
    fail_n = sum(1 for r in direct if not r["ok"])
    total_n = len(direct) or 1
    fail_rate = fail_n / total_n

    report["verdict"] = {
        "warp_ok": warp_ok,
        "direct_upstream_ok": direct_ok,
        "smartdns_ok": smartdns_ok,
        "direct_fail_rate": round(fail_rate, 4),
        "direct_fail": fail_n,
        "direct_total": len(direct),
    }

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        _print_human(report)

    if not warp_ok:
        return 2
    if not direct_ok or fail_rate > 0.2 or (args.smartdns and not smartdns_ok):
        return 1
    return 0


def _print_human(report: Dict[str, Any]) -> None:
    w = report.get("warp")
    if w is not None:
        if w["ok"]:
            print(
                f"[WARP] ok  warp={w.get('warp')} ip={w.get('ip')} "
                f"loc={w.get('loc')} colo={w.get('colo')} via={w.get('url')}"
            )
        else:
            print(f"[WARP] FAIL  error={w.get('error')} warp={w.get('warp')}")

    print(f"[DNS] loops={report['loops']} names={','.join(report['names'])}")
    print(f"[DNS] upstreams={','.join(report['upstreams'])}")

    # compact per-query lines
    for r in report["results"]:
        mode = "tcp" if r["tcp"] else "udp"
        if r["ok"]:
            addrs = ",".join(r["addrs"][:4])
            more = "" if len(r["addrs"]) <= 4 else f"+{len(r['addrs'])-4}"
            print(
                f"  OK  L{r['loop']} {r['server']}:{r['port']}/{mode} "
                f"{r['qname']} {r['rcode']} {r['ms']}ms → {addrs}{more}"
            )
        else:
            err = r["error"] or r["rcode"] or "?"
            print(
                f"  FAIL L{r['loop']} {r['server']}:{r['port']}/{mode} "
                f"{r['qname']} {err} {r['ms']}ms"
            )

    print("[SUMMARY]")
    for server, slot in report["summary"].items():
        print(f"  {server}: ok={slot['ok']} fail={slot['fail']}")

    for h in report.get("hijack_warnings") or []:
        print(
            f"[WARN] {h['qname']} via {h['server']} returned UNLOCK_IP {h['unlock_ip']} "
            f"(addrs={h['addrs']}) — unexpected for other passthrough"
        )

    v = report["verdict"]
    print(
        f"[VERDICT] warp_ok={v['warp_ok']} direct_ok={v['direct_upstream_ok']} "
        f"smartdns_ok={v['smartdns_ok']} direct_fail_rate={v['direct_fail_rate']} "
        f"({v['direct_fail']}/{v['direct_total']})"
    )


if __name__ == "__main__":
    sys.exit(main())
