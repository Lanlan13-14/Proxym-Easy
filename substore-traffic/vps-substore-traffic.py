#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vps-substore-traffic.py

通过 VPS 网卡统计 Sub-Store 订阅流量信息。

统计方式：
- outbound: 仅出站 tx_bytes
- inbound : 仅入站 rx_bytes
- both    : 入站 + 出站
- max     : 出入取大，max(rx_delta, tx_delta)

计费/续费逻辑：
- 用户设置 billing_start：计费开始 Unix 时间戳。
- 用户设置 billing_cycle：month / quarter / year。
- 用户设置 billing_periods：初次已开通周期数。
- expire = billing_start + billing_periods * billing_cycle。
- auto_renew=true 且到期后，自动按 billing_cycle 往后延长 expire，并清零当前周期流量。

Sub-Store 输出：
  upload=<upload>; download=<used>; total=<quota>; expire=<unix>; reset_day=<days>; plan_name=<name>; app_url=<url>
"""

import argparse
import calendar
import json
import os
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DEFAULT_CONFIG = {
    "listen": "0.0.0.0",
    "port": 8899,
    "iface": "eth0",
    "traffic_mode": "outbound",
    "quota_bytes": 1024 * 1024 * 1024 * 1024,
    "manual_used_bytes": None,
    "upload_bytes": 0,
    "billing_start": 0,
    "billing_cycle": "month",
    "billing_periods": 1,
    "expire": 0,
    "reset_at": 0,
    "plan_name": "VPS",
    "app_url": "",
    "auto_renew": True,
    "auto_reset_on_renewal": True,
    "admin_token": "change-me",
    "state_file": "/var/lib/vps-substore-traffic/state.json"
}

VALID_MODES = {"outbound", "inbound", "both", "max"}
VALID_CYCLES = {"month": 1, "quarter": 3, "year": 12}


def now_ts():
    return int(time.time())


def parse_int_like(value, default=0):
    if value in (None, ""):
        return default
    return int(str(value).strip().replace(" ", ""))


def parse_time(value):
    if value in (None, "", 0, "0"):
        return 0
    if isinstance(value, int):
        return value
    s = str(value).strip()
    if s.isdigit():
        return int(s)
    if len(s) == 10:
        dt = datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    else:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def add_months(ts, months):
    if not ts:
        return 0
    dt = datetime.fromtimestamp(int(ts))
    month_index = dt.month - 1 + int(months)
    year = dt.year + month_index // 12
    month = month_index % 12 + 1
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return int(dt.replace(year=year, month=month, day=day).timestamp())


def load_json(path, default):
    if not os.path.exists(path):
        return dict(default)
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    merged = dict(default)
    merged.update(data)
    return merged


def save_json(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def normalize_config(cfg):
    if cfg.get("expire") in (None, "", 0, "0") and cfg.get("expire_at") not in (None, "", 0, "0"):
        cfg["expire"] = cfg.get("expire_at")
    if cfg.get("billing_start") in (None, "", 0, "0") and cfg.get("expire") not in (None, "", 0, "0"):
        # 兼容旧版本：没有开始时间时，把旧 expire 当作当前到期时间保留。
        cfg["billing_start"] = 0
    cfg["billing_start"] = parse_time(cfg.get("billing_start"))
    cfg["expire"] = parse_time(cfg.get("expire"))
    cfg["expire_at"] = cfg["expire"]
    cfg["reset_at"] = parse_time(cfg.get("reset_at"))
    cfg["quota_bytes"] = parse_int_like(cfg.get("quota_bytes"), 0)
    cfg["upload_bytes"] = parse_int_like(cfg.get("upload_bytes"), 0)
    cfg["port"] = parse_int_like(cfg.get("port"), 8899)
    cfg["billing_periods"] = max(1, parse_int_like(cfg.get("billing_periods"), 1))
    cfg["billing_cycle"] = str(cfg.get("billing_cycle") or "month").strip().lower()
    if cfg["billing_cycle"] not in VALID_CYCLES:
        cfg["billing_cycle"] = "month"
    if cfg.get("manual_used_bytes") in (None, ""):
        cfg["manual_used_bytes"] = None
    else:
        cfg["manual_used_bytes"] = parse_int_like(cfg.get("manual_used_bytes"), 0)
    cfg["traffic_mode"] = str(cfg.get("traffic_mode") or "outbound").strip().lower()
    if cfg["traffic_mode"] not in VALID_MODES:
        cfg["traffic_mode"] = "outbound"
    if "auto_renew" not in cfg:
        cfg["auto_renew"] = bool(cfg.get("auto_reset_on_renewal", True))
    if cfg["billing_start"]:
        cfg["expire"] = add_months(cfg["billing_start"], VALID_CYCLES[cfg["billing_cycle"]] * cfg["billing_periods"])
        cfg["expire_at"] = cfg["expire"]
    return cfg


def maybe_auto_renew(cfg):
    if not cfg.get("auto_renew", True):
        return cfg, False
    if not cfg.get("billing_start") or not cfg.get("expire"):
        return cfg, False
    renewed = False
    months = VALID_CYCLES[cfg["billing_cycle"]]
    now = now_ts()
    while int(cfg["expire"]) <= now:
        cfg["billing_periods"] = int(cfg.get("billing_periods") or 1) + 1
        cfg["expire"] = add_months(cfg["billing_start"], months * int(cfg["billing_periods"]))
        cfg["expire_at"] = cfg["expire"]
        renewed = True
    return cfg, renewed


def read_counter(path):
    with open(path, "r", encoding="ascii") as f:
        return int(f.read().strip())


def read_iface_counters(iface):
    base = f"/sys/class/net/{iface}/statistics"
    return {
        "rx": read_counter(os.path.join(base, "rx_bytes")),
        "tx": read_counter(os.path.join(base, "tx_bytes")),
    }


def delta_from_state(st, counters):
    rx_base = int(st.get("baseline_rx", st.get("baseline_value", counters["rx"])))
    tx_base = int(st.get("baseline_tx", st.get("baseline_value", counters["tx"])))
    rx_delta = max(0, int(counters["rx"]) - rx_base)
    tx_delta = max(0, int(counters["tx"]) - tx_base)
    return rx_delta, tx_delta


def used_delta(st, counters, mode):
    rx_delta, tx_delta = delta_from_state(st, counters)
    if mode == "inbound":
        return rx_delta
    if mode == "both":
        return rx_delta + tx_delta
    if mode == "max":
        return max(rx_delta, tx_delta)
    return tx_delta


def days_until(ts):
    if not ts:
        return 0
    return max(0, int((int(ts) - now_ts() + 86399) // 86400))


def reset_reference_ts(cfg):
    return int(cfg.get("reset_at") or cfg.get("expire") or 0)


def initial_state(cfg, counters, reason="init"):
    return {
        "baseline_rx": int(counters.get("rx", 0)),
        "baseline_tx": int(counters.get("tx", 0)),
        "last_rx": int(counters.get("rx", 0)),
        "last_tx": int(counters.get("tx", 0)),
        "carried_used_bytes": 0,
        "cycle_started_at": now_ts(),
        "last_expire": int(cfg.get("expire") or 0),
        "last_reset_at": int(cfg.get("reset_at") or 0),
        "last_traffic_mode": cfg.get("traffic_mode", "outbound"),
        "last_billing_periods": int(cfg.get("billing_periods") or 1),
        "last_reset_reason": reason
    }


def reset_state(cfg, counters, reason):
    return initial_state(cfg, counters, reason)


def update_state(cfg, st, counters, renewed=False):
    reset_at = int(cfg.get("reset_at") or 0)
    last_reset_at = int(st.get("last_reset_at") or 0)
    mode = cfg.get("traffic_mode", "outbound")

    if st.get("last_traffic_mode") and st.get("last_traffic_mode") != mode:
        return reset_state(cfg, counters, "traffic_mode_changed")

    if renewed:
        return reset_state(cfg, counters, "billing_cycle_auto_renew")

    if reset_at and now_ts() >= reset_at and reset_at != last_reset_at:
        return reset_state(cfg, counters, "scheduled_reset_at")

    if cfg.get("manual_used_bytes") is not None and int(cfg.get("manual_used_bytes") or 0) != int(st.get("manual_used_bytes_applied", -1)):
        new_st = reset_state(cfg, counters, "manual_used_config")
        new_st["carried_used_bytes"] = int(cfg.get("manual_used_bytes") or 0)
        new_st["manual_used_bytes_applied"] = int(cfg.get("manual_used_bytes") or 0)
        return new_st

    # 网卡计数器变小：VPS 重启、网卡重置或回绕。先固化旧周期增量，再以当前 rx/tx 作为新 baseline。
    last_rx = int(st.get("last_rx", counters["rx"]))
    last_tx = int(st.get("last_tx", counters["tx"]))
    if int(counters["rx"]) < last_rx or int(counters["tx"]) < last_tx:
        old_counters = {"rx": max(last_rx, int(st.get("baseline_rx", last_rx))), "tx": max(last_tx, int(st.get("baseline_tx", last_tx)))}
        st["carried_used_bytes"] = int(st.get("carried_used_bytes") or 0) + used_delta(st, old_counters, mode)
        st["baseline_rx"] = int(counters["rx"])
        st["baseline_tx"] = int(counters["tx"])

    st["last_rx"] = int(counters.get("rx", 0))
    st["last_tx"] = int(counters.get("tx", 0))
    st["last_expire"] = int(cfg.get("expire") or 0)
    st["last_reset_at"] = reset_at
    st["last_traffic_mode"] = mode
    st["last_billing_periods"] = int(cfg.get("billing_periods") or 1)
    return st


def calc_used(st, counters, mode):
    return int(st.get("carried_used_bytes") or 0) + used_delta(st, counters, mode)


def userinfo(cfg, st, counters):
    used = calc_used(st, counters, cfg.get("traffic_mode", "outbound"))
    total = int(cfg.get("quota_bytes") or 0)
    upload = int(cfg.get("upload_bytes") or 0)
    expire = int(cfg.get("expire") or 0)
    reset_ts = reset_reference_ts(cfg)
    parts = [
        f"upload={upload}",
        f"download={used}",
        f"total={total}",
        f"expire={expire}",
        f"reset_day={days_until(reset_ts)}",
    ]
    if cfg.get("plan_name"):
        parts.append("plan_name=" + str(cfg["plan_name"]))
    if cfg.get("app_url"):
        parts.append("app_url=" + str(cfg["app_url"]))
    return "; ".join(parts)


def human_bytes(n):
    n = float(n)
    for unit in ["B", "KB", "MB", "GB", "TB", "PB"]:
        if n < 1024 or unit == "PB":
            return f"{n:.2f} {unit}"
        n /= 1024


class Handler(BaseHTTPRequestHandler):
    server_version = "VpsSubStoreTraffic/3.0"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (datetime.now().isoformat(timespec="seconds"), fmt % args))

    def _load(self):
        cfg = normalize_config(load_json(self.server.config_path, DEFAULT_CONFIG))
        cfg, renewed = maybe_auto_renew(cfg)
        if renewed:
            save_json(self.server.config_path, cfg)
        counters = read_iface_counters(cfg["iface"])
        st = load_json(cfg["state_file"], initial_state(cfg, counters))
        st = update_state(cfg, st, counters, renewed=renewed)
        save_json(cfg["state_file"], st)
        return cfg, st, counters

    def _send_userinfo(self, head_only=False):
        cfg, st, counters = self._load()
        info = userinfo(cfg, st, counters)
        body = (info + "\n").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Subscription-Userinfo", info)
        self.send_header("Content-Length", str(0 if head_only else len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def do_HEAD(self):
        if urlparse(self.path).path in ("/", "/sub-userinfo", "/subscription-userinfo"):
            return self._send_userinfo(True)
        self.send_error(404)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/sub-userinfo", "/subscription-userinfo"):
            return self._send_userinfo(False)
        if parsed.path == "/status":
            cfg, st, counters = self._load()
            used = calc_used(st, counters, cfg.get("traffic_mode", "outbound"))
            out = {
                "listen": cfg["listen"],
                "port": cfg["port"],
                "iface": cfg["iface"],
                "traffic_mode": cfg["traffic_mode"],
                "rx_bytes": counters["rx"],
                "tx_bytes": counters["tx"],
                "used_bytes": used,
                "used_human": human_bytes(used),
                "upload_bytes": int(cfg.get("upload_bytes") or 0),
                "total_bytes": int(cfg.get("quota_bytes") or 0),
                "total_human": human_bytes(int(cfg.get("quota_bytes") or 0)),
                "billing_start": int(cfg.get("billing_start") or 0),
                "billing_cycle": cfg.get("billing_cycle"),
                "billing_periods": int(cfg.get("billing_periods") or 1),
                "auto_renew": bool(cfg.get("auto_renew", True)),
                "expire": int(cfg.get("expire") or 0),
                "reset_at": int(cfg.get("reset_at") or 0),
                "reset_day": days_until(reset_reference_ts(cfg)),
                "state": st,
                "subscription_userinfo": userinfo(cfg, st, counters)
            }
            body = json.dumps(out, ensure_ascii=False, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/admin/reset":
            qs = parse_qs(parsed.query)
            cfg = normalize_config(load_json(self.server.config_path, DEFAULT_CONFIG))
            token = qs.get("token", [""])[0]
            if not cfg.get("admin_token") or token != cfg.get("admin_token"):
                self.send_error(403, "bad token")
                return
            counters = read_iface_counters(cfg["iface"])
            st = reset_state(cfg, counters, "manual_api")
            save_json(cfg["state_file"], st)
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


def main():
    ap = argparse.ArgumentParser(description="VPS Sub-Store subscription-userinfo traffic exporter")
    ap.add_argument("--config", default="/etc/vps-substore-traffic.json")
    ap.add_argument("--init-config", action="store_true")
    args = ap.parse_args()

    if args.init_config:
        if os.path.exists(args.config):
            print(f"exists: {args.config}")
        else:
            save_json(args.config, DEFAULT_CONFIG)
            print(f"created: {args.config}")
        return

    cfg = normalize_config(load_json(args.config, DEFAULT_CONFIG))
    cfg, renewed = maybe_auto_renew(cfg)
    if renewed:
        save_json(args.config, cfg)
    server = ThreadingHTTPServer((cfg["listen"], int(cfg["port"])), Handler)
    server.config_path = args.config
    print(f"listening on http://{cfg['listen']}:{cfg['port']} iface={cfg['iface']} mode={cfg['traffic_mode']}")
    server.serve_forever()


if __name__ == "__main__":
    main()
