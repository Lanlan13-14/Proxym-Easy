#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vps-substore-traffic.py

通过 VPS 网卡统计 Sub-Store 订阅流量信息。
支持统计方式：
- outbound: 仅出站 tx_bytes
- inbound : 仅入站 rx_bytes
- both    : 入站 + 出站

HTTP/HEAD 输出 Sub-Store subscription-userinfo：
  upload=<upload>; download=<used>; total=<quota>; expire=<unix>; reset_day=<days>; plan_name=<name>; app_url=<url>

说明：
- upload 字段默认输出 0，也可以在配置中固定设置。
- download 字段输出当前周期已用流量，单位字节。
- total 字段输出套餐总流量，单位字节。
- expire 必须是 Unix 时间戳，例如 4115721600。
- reset_at 可设置流量重置 Unix 时间；到点后自动清零。
- expire 延长时，如果 auto_reset_on_renewal=true，会视为续费并自动清零。
"""

import argparse
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
    "expire": 0,
    "reset_at": 0,
    "plan_name": "VPS",
    "app_url": "",
    "auto_reset_on_renewal": True,
    "admin_token": "change-me",
    "state_file": "/var/lib/vps-substore-traffic/state.json"
}

VALID_MODES = {"outbound", "inbound", "both"}


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
    # 兼容旧配置 expire_at，但新配置以 expire 为准。
    if cfg.get("expire") in (None, "", 0, "0") and cfg.get("expire_at") not in (None, "", 0, "0"):
        cfg["expire"] = cfg.get("expire_at")
    cfg["expire"] = parse_time(cfg.get("expire"))
    cfg["expire_at"] = cfg["expire"]
    cfg["reset_at"] = parse_time(cfg.get("reset_at"))
    cfg["quota_bytes"] = parse_int_like(cfg.get("quota_bytes"), 0)
    if cfg.get("manual_used_bytes") in (None, ""):
        cfg["manual_used_bytes"] = None
    else:
        cfg["manual_used_bytes"] = parse_int_like(cfg.get("manual_used_bytes"), 0)
    cfg["upload_bytes"] = parse_int_like(cfg.get("upload_bytes"), 0)
    cfg["port"] = parse_int_like(cfg.get("port"), 8899)
    cfg["traffic_mode"] = str(cfg.get("traffic_mode") or "outbound").strip().lower()
    if cfg["traffic_mode"] not in VALID_MODES:
        cfg["traffic_mode"] = "outbound"
    return cfg


def read_counter(path):
    with open(path, "r", encoding="ascii") as f:
        return int(f.read().strip())


def read_iface_counters(iface):
    base = f"/sys/class/net/{iface}/statistics"
    return {
        "rx": read_counter(os.path.join(base, "rx_bytes")),
        "tx": read_counter(os.path.join(base, "tx_bytes")),
    }


def counter_value(counters, mode):
    if mode == "inbound":
        return int(counters["rx"])
    if mode == "both":
        return int(counters["rx"]) + int(counters["tx"])
    return int(counters["tx"])


def days_until(ts):
    if not ts:
        return 0
    return max(0, int((int(ts) - now_ts() + 86399) // 86400))


def reset_reference_ts(cfg):
    return int(cfg.get("reset_at") or cfg.get("expire") or 0)


def initial_state(cfg, current_value, counters, reason="init"):
    return {
        "baseline_value": current_value,
        "last_value": current_value,
        "last_rx": int(counters.get("rx", 0)),
        "last_tx": int(counters.get("tx", 0)),
        "carried_used_bytes": 0,
        "cycle_started_at": now_ts(),
        "last_expire": int(cfg.get("expire") or 0),
        "last_reset_at": int(cfg.get("reset_at") or 0),
        "last_traffic_mode": cfg.get("traffic_mode", "outbound"),
        "last_reset_reason": reason
    }


def reset_state(cfg, current_value, counters, reason):
    return initial_state(cfg, current_value, counters, reason)


def update_state(cfg, st, current_value, counters):
    expire = int(cfg.get("expire") or 0)
    reset_at = int(cfg.get("reset_at") or 0)
    last_expire = int(st.get("last_expire") or 0)
    last_reset_at = int(st.get("last_reset_at") or 0)
    mode = cfg.get("traffic_mode", "outbound")

    # 切换统计方式后，旧 baseline 无意义，自动开新周期。
    if st.get("last_traffic_mode") and st.get("last_traffic_mode") != mode:
        return reset_state(cfg, current_value, counters, "traffic_mode_changed")

    # 到达手动设置的重置时间：自动清零。避免同一个 reset_at 反复清零。
    if reset_at and now_ts() >= reset_at and reset_at != last_reset_at:
        return reset_state(cfg, current_value, counters, "scheduled_reset_at")

    # 到期时间向后延长：视为续费，自动清零。
    if cfg.get("auto_reset_on_renewal", True) and expire and last_expire and expire > last_expire:
        return reset_state(cfg, current_value, counters, "renewal_expire_extended")

    # 配置里显式设置 manual_used_bytes 时，以当前网卡计数作为新 baseline，手动值作为 carried。
    if cfg.get("manual_used_bytes") is not None and int(cfg.get("manual_used_bytes") or 0) != int(st.get("manual_used_bytes_applied", -1)):
        new_st = reset_state(cfg, current_value, counters, "manual_used_config")
        new_st["carried_used_bytes"] = int(cfg.get("manual_used_bytes") or 0)
        new_st["manual_used_bytes_applied"] = int(cfg.get("manual_used_bytes") or 0)
        return new_st

    baseline = int(st.get("baseline_value", current_value))
    last_value = int(st.get("last_value", current_value))
    carried = int(st.get("carried_used_bytes") or 0)

    # 计数器变小：VPS 重启、网卡重置、容器网络重建或回绕。
    if current_value < last_value:
        carried += max(0, last_value - baseline)
        baseline = current_value

    st["baseline_value"] = baseline
    st["last_value"] = current_value
    st["last_rx"] = int(counters.get("rx", 0))
    st["last_tx"] = int(counters.get("tx", 0))
    st["carried_used_bytes"] = carried
    st["last_expire"] = expire
    st["last_reset_at"] = reset_at
    st["last_traffic_mode"] = mode
    return st


def calc_used(st, current_value):
    carried = int(st.get("carried_used_bytes") or 0)
    baseline = int(st.get("baseline_value") or current_value)
    return carried + max(0, current_value - baseline)


def userinfo(cfg, st, current_value):
    used = calc_used(st, current_value)
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
    server_version = "VpsSubStoreTraffic/2.0"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (datetime.now().isoformat(timespec="seconds"), fmt % args))

    def _load(self):
        cfg = normalize_config(load_json(self.server.config_path, DEFAULT_CONFIG))
        counters = read_iface_counters(cfg["iface"])
        current_value = counter_value(counters, cfg["traffic_mode"])
        st = load_json(cfg["state_file"], initial_state(cfg, current_value, counters))
        st = update_state(cfg, st, current_value, counters)
        save_json(cfg["state_file"], st)
        return cfg, st, current_value, counters

    def _send_userinfo(self, head_only=False):
        cfg, st, current_value, _counters = self._load()
        info = userinfo(cfg, st, current_value)
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
            cfg, st, current_value, counters = self._load()
            used = calc_used(st, current_value)
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
                "expire": int(cfg.get("expire") or 0),
                "reset_at": int(cfg.get("reset_at") or 0),
                "reset_day": days_until(reset_reference_ts(cfg)),
                "state": st,
                "subscription_userinfo": userinfo(cfg, st, current_value)
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
            current_value = counter_value(counters, cfg["traffic_mode"])
            st = reset_state(cfg, current_value, counters, "manual_api")
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
    server = ThreadingHTTPServer((cfg["listen"], int(cfg["port"])), Handler)
    server.config_path = args.config
    print(f"listening on http://{cfg['listen']}:{cfg['port']} iface={cfg['iface']} mode={cfg['traffic_mode']}")
    server.serve_forever()


if __name__ == "__main__":
    main()
