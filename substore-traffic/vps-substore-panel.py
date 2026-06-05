#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SSH 终端配置面板：VPS Sub-Store 流量统计
"""

import calendar
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from datetime import datetime

CONFIG_PATH = "/etc/vps-substore-traffic.json"
SCRIPT_PATH = "/usr/local/bin/vps-substore-traffic"
SERVICE_PATH = "/etc/systemd/system/vps-substore-traffic.service"
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

MODE_NAMES = {
    "outbound": "仅出站 tx_bytes",
    "inbound": "仅入站 rx_bytes",
    "both": "入站 + 出站",
    "max": "出入取大 max(rx, tx)"
}
CYCLE_NAMES = {"month": "月付", "quarter": "季付", "year": "年付"}
CYCLE_MONTHS = {"month": 1, "quarter": 3, "year": 12}


def run(cmd):
    return subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def clear():
    os.system("clear")


def pause():
    input("\n按回车继续...")


def add_months(ts, months):
    if not ts:
        return 0
    dt = datetime.fromtimestamp(int(ts))
    month_index = dt.month - 1 + int(months)
    year = dt.year + month_index // 12
    month = month_index % 12 + 1
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return int(dt.replace(year=year, month=month, day=day).timestamp())


def calc_expire(cfg):
    start = int(cfg.get("billing_start") or 0)
    if not start:
        return int(cfg.get("expire") or 0)
    cycle = cfg.get("billing_cycle", "month")
    periods = max(1, int(cfg.get("billing_periods") or 1))
    return add_months(start, CYCLE_MONTHS.get(cycle, 1) * periods)


def load_config():
    if not os.path.exists(CONFIG_PATH):
        data = dict(DEFAULT_CONFIG)
    else:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        data = dict(DEFAULT_CONFIG)
        data.update(cfg)
    if "expire_at" in data and not data.get("expire"):
        data["expire"] = data.get("expire_at") or 0
    if "auto_renew" not in data:
        data["auto_renew"] = bool(data.get("auto_reset_on_renewal", True))
    if data.get("billing_start"):
        data["expire"] = calc_expire(data)
    return data


def save_config(cfg):
    if cfg.get("billing_start"):
        cfg["expire"] = calc_expire(cfg)
        cfg["expire_at"] = cfg["expire"]
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)


def input_default(prompt, default):
    val = input(f"{prompt} [{default}]: ").strip()
    return default if val == "" else val


def input_int(prompt, default):
    while True:
        val = input_default(prompt, default)
        try:
            return int(str(val).replace(" ", ""))
        except Exception:
            print("请输入整数，例如 8899 或 4115721600")


def input_bool(prompt, default=True):
    val = input_default(prompt, "y" if default else "n")
    return str(val).lower() in ("y", "yes", "1", "true", "是")


def parse_traffic_size(value):
    if value is None:
        return 0
    s = str(value).strip().replace(" ", "")
    if not s:
        return 0
    m = re.fullmatch(r"(?i)(\d+(?:\.\d+)?)(B|KB|K|MB|M|GB|G|TB|T|PB|P)?", s)
    if not m:
        raise ValueError("流量格式错误")
    num = float(m.group(1))
    unit = (m.group(2) or "B").upper()
    factors = {"B": 1, "K": 1024, "KB": 1024, "M": 1024**2, "MB": 1024**2, "G": 1024**3, "GB": 1024**3, "T": 1024**4, "TB": 1024**4, "P": 1024**5, "PB": 1024**5}
    return int(num * factors[unit])


def input_traffic_size(prompt, default_bytes):
    default_text = f"{default_bytes} / {human_bytes(default_bytes)}"
    while True:
        val = input(f"{prompt} [{default_text}]: ").strip()
        if val == "":
            return int(default_bytes or 0)
        try:
            return parse_traffic_size(val)
        except Exception:
            print("请输入流量大小，例如：10240、10KB、500MB、1GB、1TB。换算按 1KB=1024B。")


def human_bytes(n):
    try:
        n = float(n)
    except Exception:
        n = 0
    for unit in ["B", "KB", "MB", "GB", "TB", "PB"]:
        if n < 1024 or unit == "PB":
            return f"{n:.2f} {unit}"
        n /= 1024


def ts_text(ts):
    try:
        ts = int(ts)
    except Exception:
        ts = 0
    if not ts:
        return "未设置"
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def list_ifaces():
    base = "/sys/class/net"
    if not os.path.isdir(base):
        return []
    return [n for n in sorted(os.listdir(base)) if n != "lo" and os.path.exists(os.path.join(base, n, "statistics", "rx_bytes")) and os.path.exists(os.path.join(base, n, "statistics", "tx_bytes"))]


def detect_default_iface():
    r = run("ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==\"dev\") print $(i+1)}' | head -n1")
    iface = r.stdout.strip().splitlines()[0] if r.stdout.strip() else ""
    return iface or "eth0"


def read_counter(iface, name):
    path = f"/sys/class/net/{iface}/statistics/{name}"
    try:
        with open(path, "r", encoding="ascii") as f:
            return int(f.read().strip())
    except Exception:
        return 0


def current_used_from_state(cfg, rx, tx):
    state_file = cfg.get("state_file", DEFAULT_CONFIG["state_file"])
    if not os.path.exists(state_file):
        return 0
    try:
        with open(state_file, "r", encoding="utf-8") as f:
            st = json.load(f)
        rx_delta = max(0, rx - int(st.get("baseline_rx", rx)))
        tx_delta = max(0, tx - int(st.get("baseline_tx", tx)))
        mode = cfg.get("traffic_mode", "outbound")
        if mode == "inbound":
            delta = rx_delta
        elif mode == "both":
            delta = rx_delta + tx_delta
        elif mode == "max":
            delta = max(rx_delta, tx_delta)
        else:
            delta = tx_delta
        return int(st.get("carried_used_bytes") or 0) + delta
    except Exception:
        return 0


def ensure_admin_token(cfg):
    if not cfg.get("admin_token") or cfg.get("admin_token") == "change-me":
        cfg["admin_token"] = secrets.token_urlsafe(24)
    return cfg


def set_manual_used_bytes(cfg, used_bytes):
    state_file = cfg.get("state_file", DEFAULT_CONFIG["state_file"])
    iface = cfg.get("iface", "eth0")
    rx = read_counter(iface, "rx_bytes")
    tx = read_counter(iface, "tx_bytes")
    state = {
        "baseline_rx": rx,
        "baseline_tx": tx,
        "last_rx": rx,
        "last_tx": tx,
        "carried_used_bytes": int(used_bytes),
        "cycle_started_at": int(time.time()),
        "last_expire": int(cfg.get("expire") or 0),
        "last_reset_at": int(cfg.get("reset_at") or 0),
        "last_traffic_mode": cfg.get("traffic_mode", "outbound"),
        "last_billing_periods": int(cfg.get("billing_periods") or 1),
        "last_reset_reason": "manual_set_used"
    }
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, state_file)


def install_systemd():
    service = f"""[Unit]
Description=VPS Sub-Store Traffic Userinfo Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={SCRIPT_PATH} --config {CONFIG_PATH}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
"""
    with open(SERVICE_PATH, "w", encoding="utf-8") as f:
        f.write(service)
    run("systemctl daemon-reload")
    run("systemctl enable --now vps-substore-traffic")


def restart_service():
    if shutil.which("systemctl"):
        run("systemctl restart vps-substore-traffic")


def service_status():
    if not shutil.which("systemctl"):
        return "systemctl 不可用"
    r = run("systemctl is-active vps-substore-traffic 2>/dev/null")
    return r.stdout.strip() or "unknown"


def show_status(cfg):
    iface = cfg.get("iface", "eth0")
    rx = read_counter(iface, "rx_bytes")
    tx = read_counter(iface, "tx_bytes")
    used = current_used_from_state(cfg, rx, tx)
    print("=" * 64)
    print("VPS Sub-Store 流量统计 SSH 面板")
    print("=" * 64)
    print(f"服务状态     : {service_status()}")
    print(f"监听地址     : {cfg.get('listen')}:{cfg.get('port')}")
    print(f"订阅信息接口 : http://VPS_IP:{cfg.get('port')}/sub-userinfo")
    print(f"网卡         : {iface}")
    print(f"当前 rx      : {human_bytes(rx)}")
    print(f"当前 tx      : {human_bytes(tx)}")
    print(f"统计方式     : {MODE_NAMES.get(cfg.get('traffic_mode'), cfg.get('traffic_mode'))}")
    print(f"已用 download: {used} ({human_bytes(used)})")
    print(f"总流量 total : {cfg.get('quota_bytes')} ({human_bytes(cfg.get('quota_bytes'))})")
    print(f"固定 upload  : {cfg.get('upload_bytes')} ({human_bytes(cfg.get('upload_bytes'))})")
    print(f"计费开始     : {cfg.get('billing_start')} ({ts_text(cfg.get('billing_start'))})")
    print(f"计费周期     : {CYCLE_NAMES.get(cfg.get('billing_cycle'), cfg.get('billing_cycle'))}")
    print(f"已开通周期数 : {cfg.get('billing_periods')}")
    print(f"自动续订     : {'开启' if cfg.get('auto_renew') else '关闭'}")
    print(f"到期 expire  : {cfg.get('expire')} ({ts_text(cfg.get('expire'))})")
    print(f"重置 reset_at: {cfg.get('reset_at')} ({ts_text(cfg.get('reset_at'))})")
    print(f"套餐名       : {cfg.get('plan_name')}")
    print(f"app_url      : {cfg.get('app_url')}")
    print("=" * 64)


def edit_basic(cfg):
    clear()
    print("基础配置")
    cfg["listen"] = input_default("监听地址", cfg.get("listen", "0.0.0.0"))
    cfg["port"] = input_int("监听端口", cfg.get("port", 8899))
    ifaces = list_ifaces()
    print("\n可用网卡：")
    for i, name in enumerate(ifaces, 1):
        print(f"  {i}. {name}")
    print("  0. 手动输入")
    choice = input_default("选择网卡编号", "1" if ifaces else "0")
    if choice.isdigit() and int(choice) > 0 and int(choice) <= len(ifaces):
        cfg["iface"] = ifaces[int(choice) - 1]
    elif choice == "0" or not ifaces:
        cfg["iface"] = input_default("网卡名", cfg.get("iface") or detect_default_iface())
    save_config(ensure_admin_token(cfg))
    print("已保存。")
    pause()


def edit_mode(cfg):
    clear()
    print("选择统计流量方式")
    print("1. 仅出站 tx_bytes")
    print("2. 仅入站 rx_bytes")
    print("3. 双向 rx_bytes + tx_bytes")
    print("4. 出入取大 max(rx_delta, tx_delta)")
    choice = input_default("请选择", "1")
    cfg["traffic_mode"] = {"2": "inbound", "3": "both", "4": "max"}.get(choice, "outbound")
    save_config(ensure_admin_token(cfg))
    print("已保存。切换统计方式后服务会自动开启新统计周期。")
    pause()


def edit_plan(cfg):
    clear()
    print("套餐与 Sub-Store 输出配置")
    print("流量输入支持：10240、10KB、500MB、1GB、1TB；换算按 1KB=1024B。\n")
    cfg["upload_bytes"] = input_traffic_size("固定 upload，通常填 0", int(cfg.get("upload_bytes", 0) or 0))
    cfg["quota_bytes"] = input_traffic_size("套餐总流量 total", int(cfg.get("quota_bytes", 1099511627776) or 0))
    if input_bool("是否手动设置当前已用流量 download？y/n", False):
        used_bytes = input_traffic_size("当前已用流量 download", 0)
        set_manual_used_bytes(cfg, used_bytes)
        print(f"已把当前已用流量设置为：{used_bytes} ({human_bytes(used_bytes)})")
    cfg["plan_name"] = input_default("plan_name 套餐名", cfg.get("plan_name", "VPS"))
    cfg["app_url"] = input_default("app_url 跳转链接，可空", cfg.get("app_url", ""))
    save_config(ensure_admin_token(cfg))
    print("已保存。")
    pause()


def edit_billing(cfg):
    clear()
    print("续费周期 / 到期时间配置")
    print("说明：expire 由 计费开始时间 + 已开通周期数 × 计费周期 自动计算。")
    print("计费开始时间是用户手动输入的开始日期 Unix 时间戳。\n")
    cfg["billing_start"] = input_int("手动输入计费开始时间 Unix 时间戳", cfg.get("billing_start", 0))
    print("\n选择计费周期：")
    print("1. 月付：每次续期 1 个月")
    print("2. 季付：每次续期 3 个月")
    print("3. 年付：每次续期 12 个月")
    c = input_default("请选择", "1")
    cfg["billing_cycle"] = {"2": "quarter", "3": "year"}.get(c, "month")
    cfg["billing_periods"] = max(1, input_int("初次设置时已经开通了几个计费周期", cfg.get("billing_periods", 1)))
    cfg["auto_renew"] = input_bool("开启自动续订？到期后按周期自动延长并清零 y/n", bool(cfg.get("auto_renew", True)))
    cfg["auto_reset_on_renewal"] = cfg["auto_renew"]
    cfg["expire"] = calc_expire(cfg)
    cfg["reset_at"] = input_int("额外 reset_at 重置 Unix 时间戳，0 表示不用", cfg.get("reset_at", 0))
    save_config(ensure_admin_token(cfg))
    print(f"已保存。当前计算出的 expire：{cfg['expire']} ({ts_text(cfg['expire'])})")
    pause()


def manual_reset(cfg):
    clear()
    print("手动清零当前周期流量")
    yes = input_default("确认清零？输入 yes", "no")
    if yes != "yes":
        print("已取消。")
        pause()
        return
    state_file = cfg.get("state_file", DEFAULT_CONFIG["state_file"])
    try:
        if os.path.exists(state_file):
            backup = state_file + ".bak." + str(int(time.time()))
            shutil.copy2(state_file, backup)
            os.remove(state_file)
            print(f"已删除状态文件并备份到：{backup}")
        else:
            print("状态文件不存在，无需删除。")
        restart_service()
    except Exception as e:
        print("清零失败：", e)
    pause()


def install_or_update(cfg):
    clear()
    print("安装/更新 systemd 服务")
    cfg = ensure_admin_token(cfg)
    save_config(cfg)
    if os.path.abspath(sys.argv[0]) != "/usr/local/bin/vps-substore-panel" and os.path.exists(sys.argv[0]):
        try:
            shutil.copy2(sys.argv[0], "/usr/local/bin/vps-substore-panel")
            os.chmod("/usr/local/bin/vps-substore-panel", 0o755)
        except Exception:
            pass
    if not os.path.exists(SCRIPT_PATH):
        print(f"没有找到服务脚本：{SCRIPT_PATH}")
        print("请先执行：sudo install -m 755 vps-substore-traffic.py /usr/local/bin/vps-substore-traffic")
        pause()
        return
    install_systemd()
    print("systemd 服务已安装并启动。")
    pause()


def view_config(cfg):
    clear()
    print(json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True))
    pause()


def main():
    if os.geteuid() != 0:
        print("建议使用 root 运行：sudo python3 vps-substore-panel.py")
        pause()
    cfg = load_config()
    if not cfg.get("iface") or cfg.get("iface") == "eth0":
        cfg["iface"] = detect_default_iface()
    cfg = ensure_admin_token(cfg)
    save_config(cfg)
    while True:
        cfg = load_config()
        clear()
        show_status(cfg)
        print("1. 修改监听端口 / 监听地址 / 网卡")
        print("2. 选择统计方式：仅出站 / 入站 / 双向 / 出入取大")
        print("3. 设置套餐流量 / 手动已用流量 / plan_name")
        print("4. 设置续费周期 / 开始时间 / 初始周期数 / 自动续订")
        print("5. 手动清零当前周期流量")
        print("6. 安装或更新 systemd 服务")
        print("7. 重启服务")
        print("8. 查看配置 JSON")
        print("0. 退出")
        choice = input("\n请选择: ").strip()
        if choice == "1":
            edit_basic(cfg)
        elif choice == "2":
            edit_mode(cfg)
        elif choice == "3":
            edit_plan(cfg)
        elif choice == "4":
            edit_billing(cfg)
        elif choice == "5":
            manual_reset(cfg)
        elif choice == "6":
            install_or_update(cfg)
        elif choice == "7":
            restart_service()
            print("已执行重启。")
            pause()
        elif choice == "8":
            view_config(cfg)
        elif choice == "0":
            break
        else:
            pause()


if __name__ == "__main__":
    main()
