#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SSH 终端配置面板：VPS Sub-Store 流量统计

运行：
  sudo python3 vps-substore-panel.py

功能：
- 自定义监听端口
- 选择统计方式：仅出站 / 仅入站 / 双向
- 设置流量套餐、到期 Unix 时间、重置 Unix 时间
- 手动清零
- 生成 systemd 服务
"""

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
    "upload_bytes": 0,
    "expire": 0,
    "reset_at": 0,
    "plan_name": "VPS",
    "app_url": "",
    "auto_reset_on_renewal": True,
    "admin_token": "change-me",
    "state_file": "/var/lib/vps-substore-traffic/state.json"
}

MODE_NAMES = {
    "outbound": "仅出站 tx_bytes",
    "inbound": "仅入站 rx_bytes",
    "both": "入站 + 出站"
}


def run(cmd):
    return subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def clear():
    os.system("clear")


def pause():
    input("\n按回车继续...")


def load_config():
    if not os.path.exists(CONFIG_PATH):
        return dict(DEFAULT_CONFIG)
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    data = dict(DEFAULT_CONFIG)
    data.update(cfg)
    if "expire_at" in data and not data.get("expire"):
        data["expire"] = data.get("expire_at") or 0
    return data


def save_config(cfg):
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


def parse_traffic_size(value):
    """把 10KB/500MB/1GB/1TB/10240 转成字节。按 1024 进率。"""
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
    factors = {
        "B": 1,
        "K": 1024,
        "KB": 1024,
        "M": 1024 ** 2,
        "MB": 1024 ** 2,
        "G": 1024 ** 3,
        "GB": 1024 ** 3,
        "T": 1024 ** 4,
        "TB": 1024 ** 4,
        "P": 1024 ** 5,
        "PB": 1024 ** 5,
    }
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


def set_manual_used_bytes(cfg, used_bytes):
    """把当前周期已用流量手动设置为 used_bytes。"""
    state_file = cfg.get("state_file", DEFAULT_CONFIG["state_file"])
    iface = cfg.get("iface", "eth0")
    rx = read_counter(iface, "rx_bytes")
    tx = read_counter(iface, "tx_bytes")
    mode = cfg.get("traffic_mode", "outbound")
    if mode == "inbound":
        current_value = rx
    elif mode == "both":
        current_value = rx + tx
    else:
        current_value = tx
    state = {
        "baseline_value": current_value,
        "last_value": current_value,
        "last_rx": rx,
        "last_tx": tx,
        "carried_used_bytes": int(used_bytes),
        "cycle_started_at": int(time.time()),
        "last_expire": int(cfg.get("expire") or 0),
        "last_reset_at": int(cfg.get("reset_at") or 0),
        "last_traffic_mode": mode,
        "last_reset_reason": "manual_set_used"
    }
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, state_file)


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
    items = []
    for name in sorted(os.listdir(base)):
        if name == "lo":
            continue
        stat = os.path.join(base, name, "statistics")
        if os.path.exists(os.path.join(stat, "rx_bytes")) and os.path.exists(os.path.join(stat, "tx_bytes")):
            items.append(name)
    return items


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


def ensure_admin_token(cfg):
    if not cfg.get("admin_token") or cfg.get("admin_token") == "change-me":
        cfg["admin_token"] = secrets.token_urlsafe(24)
    return cfg


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
    print("=" * 60)
    print("VPS Sub-Store 流量统计 SSH 面板")
    print("=" * 60)
    print(f"服务状态     : {service_status()}")
    print(f"监听地址     : {cfg.get('listen')}:{cfg.get('port')}")
    print(f"订阅信息接口 : http://VPS_IP:{cfg.get('port')}/sub-userinfo")
    print(f"状态接口     : http://VPS_IP:{cfg.get('port')}/status")
    print(f"网卡         : {iface}")
    print(f"当前 rx      : {human_bytes(rx)}")
    print(f"当前 tx      : {human_bytes(tx)}")
    print(f"统计方式     : {MODE_NAMES.get(cfg.get('traffic_mode'), cfg.get('traffic_mode'))}")
    print(f"固定 upload  : {cfg.get('upload_bytes')} ({human_bytes(cfg.get('upload_bytes'))})")
    print(f"总流量 total : {cfg.get('quota_bytes')} ({human_bytes(cfg.get('quota_bytes'))})")
    state_file = cfg.get('state_file', DEFAULT_CONFIG['state_file'])
    if os.path.exists(state_file):
        try:
            with open(state_file, 'r', encoding='utf-8') as f:
                st = json.load(f)
            current = tx if cfg.get('traffic_mode') == 'outbound' else rx if cfg.get('traffic_mode') == 'inbound' else rx + tx
            used = int(st.get('carried_used_bytes') or 0) + max(0, current - int(st.get('baseline_value') or current))
            print(f"已用 download: {used} ({human_bytes(used)})")
        except Exception:
            pass
    print(f"到期 expire  : {cfg.get('expire')} ({ts_text(cfg.get('expire'))})")
    print(f"重置 reset_at: {cfg.get('reset_at')} ({ts_text(cfg.get('reset_at'))})")
    print(f"套餐名       : {cfg.get('plan_name')}")
    print(f"app_url      : {cfg.get('app_url')}")
    print(f"续费自动清零 : {'开启' if cfg.get('auto_reset_on_renewal') else '关闭'}")
    print("=" * 60)


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
    print("1. 仅出站 tx_bytes，适合代理订阅流量常见统计")
    print("2. 仅入站 rx_bytes")
    print("3. 双向 rx_bytes + tx_bytes")
    choice = input_default("请选择", "1")
    if choice == "2":
        cfg["traffic_mode"] = "inbound"
    elif choice == "3":
        cfg["traffic_mode"] = "both"
    else:
        cfg["traffic_mode"] = "outbound"
    save_config(ensure_admin_token(cfg))
    print("已保存。切换统计方式后服务会自动开启新统计周期。")
    pause()


def edit_plan(cfg):
    clear()
    print("套餐与 Sub-Store 输出配置")
    print("流量输入支持：10240、10KB、500MB、1GB、1TB；换算按 1KB=1024B，所以 10KB=10240。\n")
    cfg["upload_bytes"] = input_traffic_size("固定 upload，通常填 0", int(cfg.get("upload_bytes", 0) or 0))
    cfg["quota_bytes"] = input_traffic_size("套餐总流量 total", int(cfg.get("quota_bytes", 1099511627776) or 0))
    manual_used = input_default("是否手动设置当前已用流量 download？y/n", "n")
    if manual_used.lower() in ("y", "yes", "1", "true", "是"):
        used_bytes = input_traffic_size("当前已用流量 download", 0)
        set_manual_used_bytes(cfg, used_bytes)
        print(f"已把当前已用流量设置为：{used_bytes} ({human_bytes(used_bytes)})")
    cfg["expire"] = input_int("手动输入 expire 到期 Unix 时间戳，例如 4115721600", cfg.get("expire", 0))
    cfg["reset_at"] = input_int("手动输入 reset_at 重置 Unix 时间戳，0 表示不按时间自动重置", cfg.get("reset_at", 0))
    cfg["plan_name"] = input_default("plan_name 套餐名", cfg.get("plan_name", "VPS"))
    cfg["app_url"] = input_default("app_url 跳转链接，可空", cfg.get("app_url", ""))
    auto = input_default("续费后自动清零？y/n", "y" if cfg.get("auto_reset_on_renewal") else "n")
    cfg["auto_reset_on_renewal"] = auto.lower() in ("y", "yes", "1", "true", "是")
    save_config(ensure_admin_token(cfg))
    print("已保存。")
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
    if os.path.abspath(sys.argv[0]) != SCRIPT_PATH and os.path.exists(sys.argv[0]):
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
        print("2. 选择统计方式：仅出站 / 入站 / 双向")
        print("3. 设置套餐流量 / 到期时间 / 重置时间")
        print("4. 手动清零当前周期流量")
        print("5. 安装或更新 systemd 服务")
        print("6. 重启服务")
        print("7. 查看配置 JSON")
        print("0. 退出")
        choice = input("\n请选择: ").strip()
        if choice == "1":
            edit_basic(cfg)
        elif choice == "2":
            edit_mode(cfg)
        elif choice == "3":
            edit_plan(cfg)
        elif choice == "4":
            manual_reset(cfg)
        elif choice == "5":
            install_or_update(cfg)
        elif choice == "6":
            restart_service()
            print("已执行重启。")
            pause()
        elif choice == "7":
            view_config(cfg)
        elif choice == "0":
            break
        else:
            pause()


if __name__ == "__main__":
    main()
