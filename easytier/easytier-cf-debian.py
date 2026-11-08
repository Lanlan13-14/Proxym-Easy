import datetime as dt
import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

ROOT = Path('/etc/easytier')
BACKUPS = ROOT / 'backups'
TMP = ROOT / 'tmp'
CORE = ROOT / 'easytier-core'
CLI = ROOT / 'easytier-cli'
CFG = ROOT / 'config.toml'
STATE = ROOT / 'settings.json'
JOIN = ROOT / 'join.json'
SCRIPT = ROOT / 'easytier-cf-debian.py'
UNIT_FILE = ROOT / 'easytier-cf.service'
UNIT = 'easytier-cf.service'
UNIT_LINK = Path('/etc/systemd/system') / UNIT
RPC = 15888
API = 'https://api.github.com/repos/EasyTier/EasyTier/releases/latest'
MARK = '# Managed by easytier-cf-debian.py'
MANAGED = (CFG, STATE, JOIN, CORE, CLI, SCRIPT, UNIT_FILE)
ARCHES = {'x86_64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}


class SetupError(Exception):
    pass


def run(argv, timeout=30, check=True):
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, timeout=timeout, check=False)
    except FileNotFoundError:
        raise SetupError('系统缺少命令：' + str(argv[0])) from None
    except subprocess.TimeoutExpired:
        raise SetupError('命令超时：' + str(argv[0])) from None
    if check and p.returncode:
        raise SetupError(f'{argv[0]} 失败，退出码 {p.returncode}。')
    return p


def atom(path, data, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise SetupError('拒绝覆盖符号链接：' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix='.new-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data if isinstance(data, bytes) else data.encode())
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def latest_release():
    machine = platform.machine().lower()
    if machine not in ARCHES:
        raise SetupError('仅支持 Debian x86_64/aarch64。')
    arch = ARCHES[machine]
    req = urllib.request.Request(API, headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'easytier-cf-debian'})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            raw = r.read(2_000_001)
    except Exception as exc:
        raise SetupError('查询 GitHub 最新稳定版失败：' + type(exc).__name__) from None
    if len(raw) > 2_000_000:
        raise SetupError('GitHub release 清单过大。')
    try:
        rel = json.loads(raw)
    except (ValueError, UnicodeError):
        raise SetupError('GitHub release JSON 无效。') from None
    tag = rel.get('tag_name')
    if rel.get('draft') is not False or rel.get('prerelease') is not False or not isinstance(tag, str) or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise SetupError('GitHub 最新 release 不是正式稳定版 SemVer。')
    asset = f'easytier-linux-{arch}-{tag}.zip'
    matches = [a for a in rel.get('assets', []) if isinstance(a, dict) and a.get('name') == asset]
    if len(matches) != 1:
        raise SetupError('最新版缺少唯一匹配本机架构的官方资产。')
    a = matches[0]
    digest = a.get('digest')
    url = f'https://github.com/EasyTier/EasyTier/releases/download/{tag}/{asset}'
    if a.get('browser_download_url') != url or not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest) or not isinstance(a.get('size'), int) or not 1_000_000 <= a['size'] <= 100_000_000:
        raise SetupError('官方 release 的下载 URL、摘要或文件大小异常。')
    return {'tag': tag, 'arch': arch, 'asset': asset, 'url': url, 'digest': digest[7:], 'size': a['size']}


def download(rel, stage):
    TMP.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(TMP, 0o700)
    stage.mkdir(mode=0o700)
    archive = stage / rel['asset']
    h, total = hashlib.sha256(), 0
    req = urllib.request.Request(rel['url'], headers={'User-Agent': 'easytier-cf-debian', 'Accept': 'application/octet-stream'})
    try:
        with urllib.request.urlopen(req, timeout=45) as r, archive.open('xb') as out:
            while True:
                block = r.read(262144)
                if not block:
                    break
                total += len(block)
                if total > 100_000_000:
                    raise SetupError('下载包过大。')
                h.update(block)
                out.write(block)
            out.flush()
            os.fsync(out.fileno())
    except SetupError:
        raise
    except Exception as exc:
        raise SetupError('下载失败：' + type(exc).__name__) from None
    if total != rel['size'] or not secrets.compare_digest(h.hexdigest(), rel['digest']):
        raise SetupError('官方发行包大小或 SHA-256 不匹配。')
    try:
        z = zipfile.ZipFile(archive)
        entries = z.infolist()
    except (OSError, zipfile.BadZipFile):
        raise SetupError('官方 ZIP 无效。') from None
    if len(entries) > 2000 or sum(x.file_size for x in entries) > 150_000_000:
        raise SetupError('ZIP 超过安全尺寸上限。')
    prefix = f"easytier-linux-{rel['arch']}/"
    wanted = {prefix + 'easytier-core', prefix + 'easytier-cli'}
    chosen = {}
    for info in entries:
        n = info.filename
        if n.startswith('/') or '\\' in n or '..' in Path(n).parts or ((info.external_attr >> 16) & 0o170000) == stat.S_IFLNK:
            raise SetupError('官方 ZIP 含不安全路径/链接。')
        if n in wanted:
            if info.is_dir() or info.file_size > 30_000_000:
                raise SetupError('可执行文件尺寸异常。')
            chosen[n.rsplit('/', 1)[-1]] = info
    if set(chosen) != {'easytier-core', 'easytier-cli'}:
        raise SetupError('ZIP 缺少预期的 core/cli。')
    outdir = stage / 'bin'
    outdir.mkdir(mode=0o700)
    for name, info in chosen.items():
        p = outdir / name
        with z.open(info) as f, p.open('xb') as out:
            shutil.copyfileobj(f, out, 262144)
        os.chmod(p, 0o755)
    if rel['tag'].lstrip('v') not in run([str(outdir/'easytier-core'), '--version'], timeout=8).stdout:
        raise SetupError('二进制版本号与 release tag 不符。')
    return outdir / 'easytier-core', outdir / 'easytier-cli'


def validate(s):
    try:
        ip = ipaddress.IPv4Interface(s['ip'])
    except (KeyError, ValueError):
        raise SetupError('虚拟 IPv4 格式错误。') from None
    if ip.network.prefixlen != 24 or ip.ip in (ip.network.network_address, ip.network.broadcast_address):
        raise SetupError('请使用未占用 RFC1918 /24 主机 IP。')
    if not any(ip.ip in ipaddress.ip_network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')):
        raise SetupError('虚拟 IP 必须为私有地址。')
    s['ip'] = str(ip)
    for key in ('name','network','server_name'):
        if not isinstance(s.get(key), str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,62}', s[key]):
            raise SetupError('名称只能使用 ASCII 字母数字、点、下划线、短横线。')
    domain = str(s.get('domain','')).strip().lower().rstrip('.')
    if len(domain)>253 or '.' not in domain or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',x) for x in domain.split('.')):
        raise SetupError('请输入完整 Tunnel hostname（不含协议、端口）。')
    s['domain']=domain
    if not isinstance(s.get('secret'),str) or not 32<=len(s['secret'])<=256 or any(not 33<=ord(c)<=126 for c in s['secret']):
        raise SetupError('网络密钥需 32-256 个可打印 ASCII 字符。')
    if s.get('role') == 'client' and len(s['secret']) < 40:
        raise SetupError('客户端网络密钥长度不足；请用服务端生成的 320-bit 密钥。')
    return s


def q(x):
    return json.dumps(x,ensure_ascii=True)


def render(s,version):
    listener='["ws://127.0.0.1:11011"]' if s['role']=='server' else '[]'
    t=f'''# EasyTier {version}, generated by installer
instance_name = "cf-mesh"
hostname = {q(s['name'])}
ipv4 = {q(s['ip'])}
dhcp = false
listeners = {listener}
stun_servers = []
stun_servers_v6 = []

[network_identity]
network_name = {q(s['network'])}
network_secret = {q(s['secret'])}
'''
    if s['role']=='client':
        t+='\n[[peer]]\nuri = '+q('wss://'+s['domain']+':443/')+'\n'
    return t+'''
[flags]
dev_name = "etcf0"
default_protocol = "wss"
enable_encryption = true
encryption_algorithm = "aes-gcm"
private_mode = true
mtu = 1380
multi_thread = true
multi_thread_count = 2
data_compress_algo = 1
disable_p2p = true
need_p2p = false
disable_udp_hole_punching = true
disable_tcp_hole_punching = true
disable_upnp = true
enable_kcp_proxy = false
disable_kcp_input = true
enable_quic_proxy = false
disable_quic_input = true
no_tun = false
enable_exit_node = false
relay_all_peer_rpc = false
accept_dns = false
'''


def unit_text():
    return f'''{MARK}
[Unit]
Description=EasyTier Cloudflare Tunnel TCP LAN
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
UMask=0077
Environment=RUST_LOG=warn
WorkingDirectory={ROOT}
ExecStartPre={CORE} -c {CFG} --check-config
ExecStart={CORE} -c {CFG} --rpc-portal 127.0.0.1:15888 --console-log-level warn --file-log-level off
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
'''


def svc_state():
    a=run(['systemctl','is-active',UNIT],check=False).stdout.strip()
    e=run(['systemctl','is-enabled',UNIT],check=False).stdout.strip()
    return {'active':a=='active','enabled':e in ('enabled','enabled-runtime','linked','linked-runtime')}


def snapshot():
    ROOT.mkdir(parents=True,exist_ok=True,mode=0o700);os.chmod(ROOT,0o700)
    BACKUPS.mkdir(mode=0o700,exist_ok=True);os.chmod(BACKUPS,0o700)
    d=BACKUPS/(dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(4))
    fdir=d/'files';fdir.mkdir(parents=True,mode=0o700)
    present=[]
    for p in MANAGED:
        if p.is_symlink(): raise SetupError('拒绝备份符号链接：'+str(p))
        if p.exists():
            if not p.is_file(): raise SetupError('受管路径不是文件：'+str(p))
            shutil.copy2(p,fdir/p.name);present.append(p.name)
    meta={'format':'easytier-cf-backup-v1','present':present,'link':os.path.realpath(UNIT_LINK) if UNIT_LINK.is_symlink() else None,'systemd':svc_state()}
    atom(d/'backup.json',json.dumps(meta,indent=2),0o600)
    return d


def load_state():
    if not STATE.exists(): return None
    if STATE.is_symlink() or STATE.stat().st_mode & 0o077: raise SetupError('状态文件不是安全的 root 私有文件。')
    d=json.loads(STATE.read_text())
    if d.get('format')!='easytier-cf-state-v1': raise SetupError('现有状态不属于此脚本。')
    return d


def join_payload(s):
    return {'format':'easytier-cf-join-v1','domain':s['domain'],'network':s['network'],'secret':s['secret'],'subnet':s['subnet'],'server_name':s['server_name']}


def read_secret_from_config():
    text=CFG.read_text()
    m=re.search(r'^network_secret\s*=\s*("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')\s*$',text,re.M)
    if not m: raise SetupError('现有网络密钥格式不支持；拒绝更新。')
    value=m.group(1)
    if value.startswith("'"): value='"'+value[1:-1].replace('"','\\"')+'"'
    try: return json.loads(value)
    except ValueError: raise SetupError('现有网络密钥解析失败。') from None



def read_join(path):
    p=Path(path)
    if not p.is_absolute() or p.is_symlink() or not p.is_file() or p.stat().st_mode & 0o077 or p.stat().st_size>32768:
        raise SetupError('加入文件需是 0600 普通文件。')
    j=json.loads(p.read_text())
    if j.get('format')!='easytier-cf-join-v1': raise SetupError('加入 JSON 格式不匹配。')
    net=ipaddress.ip_network(j.get('subnet',''),strict=True)
    if net.version!=4 or net.prefixlen!=24: raise SetupError('加入文件只支持 IPv4 /24。')
    return j


def get_config(args,old,version):
    if args.join:
        j=read_join(args.join)
        if args.role=='server': raise SetupError('--join 只用于客户端。')
        if str(Path(args.join).resolve()) == str(JOIN.resolve()): raise SetupError('该文件含 VPS 本机服务端密钥；请显式粘贴客户端安全接收的网络密钥，禁止把服务端文件当客户端加入文件。')
        name=args.name or input('设备名 [client-1]: ').strip() or 'client-1'
        ip=args.ip or input(f"虚拟 IP，必须是 {j['subnet']} 内未占用地址: ").strip()
        if not ip: raise SetupError('每台客户端必须指定唯一虚拟 IP。')
        if '/' not in ip: ip+='/24'
        return validate({'role':'client','name':name,'ip':ip,'domain':j['domain'],'network':j['network'],'secret':j['secret'],'subnet':j['subnet'],'server_name':j['server_name'],'version':version})
    if old and args.update:
        if args.role and args.role!=old['role']: raise SetupError('更新不能无提示改变节点角色。')
        s=dict(old);s['version']=version;s['secret']=read_secret_from_config()
        if args.domain:s['domain']=args.domain
        if args.ip:s['ip']=args.ip
        if args.name:s['name']=args.name
        if args.network:s['network']=args.network
        return validate(s)
    role=args.role
    if not role:
        role={'1':'server','2':'client'}.get(input('选择 1/2: ').strip())
    if role not in ('server','client'):
        raise SetupError('必须选择 VPS 服务端或加入客户端。')
    if args.no_prompt and not all((args.domain,args.ip,args.name,args.network)):
        raise SetupError('--no-prompt 需提供 --domain --ip --name --network。')
    host=re.sub(r'[^A-Za-z0-9_.-]','-',socket.gethostname().lower())[:63].strip('-.') or ('vps' if role=='server' else 'client-1')
    name=args.name or input(f'设备名 [{host}]: ').strip() or host
    if role == 'server':
        domain=args.domain or input('CF Tunnel 公网主机名（例如 mesh.example.com）: ').strip()
        ip=args.ip or input('本机虚拟 IPv4 [10.66.66.1/24]: ').strip() or '10.66.66.1/24'
        network=args.network or input('私有网络名 [my-cf-mesh]: ').strip() or 'my-cf-mesh'
        subnet=str(ipaddress.ip_interface(ip).network)
        secret=secrets.token_urlsafe(40)
        print('已生成 320-bit 随机组网密钥；只保存在 root-only /etc/easytier/join.json，不显示在终端。')
        return validate({'role':'server','name':name,'ip':ip,'domain':domain,'network':network,'secret':secret,'subnet':subnet,'server_name':'vps','version':version})
    domain=args.domain or input('VPS 的 CF Tunnel 公网主机名: ').strip()
    network=args.network or input('服务端设置的私有网络名: ').strip()
    ip=args.ip or input('本机虚拟 IPv4，必须和 VPS 使用同一 /24 [10.66.66.2/24]: ').strip() or '10.66.66.2/24'
    subnet=str(ipaddress.ip_interface(ip).network)
    server_name='vps'
    secret=getpass.getpass('输入 VPS 安装时安全传来的 320-bit 组网密钥（不会回显）: ')
    return validate({'role':'client','name':name,'ip':ip,'domain':domain,'network':network,'secret':secret,'subnet':subnet,'server_name':server_name,'version':version})


def env_check(for_write=True):
    if os.geteuid()!=0: raise SetupError('请使用 sudo 运行。')
    if not Path('/etc/debian_version').is_file() or not Path('/run/systemd/system').is_dir(): raise SetupError('要求 Debian + systemd。')
    if ROOT.is_symlink(): raise SetupError('/etc/easytier 是符号链接，拒绝写入。')
    if not Path('/dev/net/tun').exists(): raise SetupError('未发现 /dev/net/tun，先在 VPS 开启 TUN。')
    for x in ('systemctl','ip','tar'):
        if not shutil.which(x): raise SetupError('缺少 Debian 命令：'+x)
    if for_write and shutil.disk_usage('/etc').free < 512 * 1024 * 1024:
        raise SetupError('根分区可用空间不足 512 MiB；拒绝安装/更新。先清理磁盘再重试。')
    if for_write and run(['systemctl','is-system-running'],check=False).stdout.strip() in ('offline','unknown'):
        raise SetupError('systemd 未处于可管理状态。')
    for x in ('curl','unzip'):
        if not shutil.which(x): raise SetupError('缺少依赖 '+x+'；本脚本不自动修改 APT 源。请用 Debian apt 安装。')
    p=run(['systemctl','is-system-running'],check=False)
    if p.returncode not in (0,1) or p.stdout.strip() in ('offline','unknown'): raise SetupError('systemd 未处于可管理状态。')

def ownership():
    if UNIT_FILE.is_symlink() or (UNIT_FILE.exists() and MARK not in UNIT_FILE.read_text(errors='replace')): raise SetupError('service 文件不属于本脚本，拒绝覆盖。')
    if UNIT_LINK.is_symlink() and os.path.realpath(UNIT_LINK)!=str(UNIT_FILE): raise SetupError('同名 systemd unit 指向其他服务。')
    if UNIT_LINK.exists() and not UNIT_LINK.is_symlink(): raise SetupError('systemd unit 普通文件冲突。')
    for p in MANAGED:
        if p.is_symlink(): raise SetupError('受管路径是符号链接：'+str(p))


def rollback(path):
    d=Path(path)
    if d.is_symlink() or not d.is_dir() or BACKUPS.resolve(strict=True) not in d.resolve(strict=True).parents: raise SetupError('回滚只能使用 /etc/easytier/backups 中的目录。')
    meta_path=d/'backup.json'
    if meta_path.is_symlink() or not meta_path.is_file() or meta_path.stat().st_mode & 0o077: raise SetupError('备份元数据缺失或权限过宽。')
    meta=json.loads(meta_path.read_text()); names=meta.get('present'); allowed={x.name for x in MANAGED}; files=d/'files'
    if meta.get('format')!='easytier-cf-backup-v1' or not isinstance(names,list) or len(names)!=len(set(names)) or not set(names)<=allowed or {x.name for x in files.iterdir()}!=set(names): raise SetupError('回滚清单与备份文件不匹配。')
    current=snapshot();run(['systemctl','stop',UNIT],check=False)
    for p in MANAGED:
        if p.name not in names and p.exists():
            if p.is_symlink() or not p.is_file():raise SetupError('回滚遇到非普通文件。')
            p.unlink()
    for name in names:
        src=files/name
        if src.is_symlink() or not src.is_file():raise SetupError('拒绝恢复符号链接。')
        dst=next(x for x in MANAGED if x.name==name)
        mode=0o755 if dst in (CORE,CLI,SCRIPT) else 0o600
        atom(dst,src.read_bytes(),mode)
    if UNIT_LINK.is_symlink() and os.path.realpath(UNIT_LINK)==str(UNIT_FILE):UNIT_LINK.unlink()
    elif UNIT_LINK.exists():raise SetupError('systemd unit 由其他进程替换。')
    if meta.get('link')==str(UNIT_FILE):UNIT_LINK.symlink_to(UNIT_FILE)
    run(['systemctl','daemon-reload'])
    st=meta.get('systemd',{})
    run(['systemctl','enable' if st.get('enabled') else 'disable',UNIT],check=False)
    run(['systemctl','start' if st.get('active') else 'stop',UNIT],check=False)
    print('回滚完成；当前状态已另存：'+str(current))


def install(args,rel):
    if args.dry_run:
        if args.role == 'client' and (not args.join or str(Path(args.join).resolve()) == str(JOIN.resolve())):
            raise SetupError('客户端加入须指向 VPS 导出的 join.json，不可指向本机保留的网络密钥文件。')
        if args.no_prompt and args.role is None: raise SetupError('--no-prompt 时必须提供 --role。')
        env_check(for_write=False)
        if args.no_prompt and args.role is None: raise SetupError('--no-prompt 时必须提供 --role。')
        env_check(for_write=False)
        old=load_state() if ROOT.exists() else None
        s=get_config(args,old,rel['tag'])
        for path in MANAGED:
            if path.is_symlink():raise SetupError('受管路径是符号链接，dry-run 拒绝：'+str(path))
        if ROOT.exists() and any(path.exists() for path in MANAGED) and not old:
            raise SetupError('/etc/easytier 存在非本脚本文件；dry-run 拒绝覆盖。')
        print(f"dry-run PASS：{s['role']} {s['ip']} / {rel['tag']}；不下载、不写入、不动 systemd。")
        return
    env_check(for_write=True);os.umask(0o077);ROOT.mkdir(parents=True,exist_ok=True,mode=0o700);os.chmod(ROOT,0o700)
    lock=ROOT/'.installer.lock'
    with lock.open('a') as lf:
        os.chmod(lock,0o600);fcntl.flock(lf,fcntl.LOCK_EX);ownership()
        old=load_state();occupied=[p for p in MANAGED if p.exists()]
        if occupied and not old:raise SetupError('/etc/easytier 存在非本脚本文件；拒绝覆盖。')
        if old and not args.update and not args.join:raise SetupError('已安装；升级请明确加 --update。')
        s=get_config(args,old,rel['tag'])
        bak=snapshot();print('已备份：'+str(bak))
        TMP.mkdir(mode=0o700,exist_ok=True);os.chmod(TMP,0o700)
        stage=Path(tempfile.mkdtemp(prefix='stage-',dir=TMP));was=svc_state()
        try:
            core_new,cli_new=download(rel,stage)
            check=stage/'check.toml';check.write_text(render(s,rel['tag']))
            if run([str(core_new),'-c',str(check),'--check-config'],check=False).returncode:raise SetupError('最新官方二进制 TOML 校验失败；旧服务未停止。')
            atom(CFG,render(s,rel['tag']),0o600);atom(CORE,core_new.read_bytes(),0o755);atom(CLI,cli_new.read_bytes(),0o755);atom(SCRIPT,Path(__file__).read_bytes(),0o700);atom(UNIT_FILE,unit_text(),0o600)
            state={k:s[k] for k in ('role','name','ip','domain','network','subnet','server_name')};state.update({'format':'easytier-cf-state-v1','version':rel['tag'],'backup':str(bak)})
            atom(STATE,json.dumps(state,indent=2),0o600)
            if s['role']=='server' and not JOIN.exists():atom(JOIN,json.dumps({'format':'easytier-cf-join-v1','domain':s['domain'],'network':s['network'],'secret':s['secret'],'subnet':s['subnet'],'server_name':s['server_name']},indent=2),0o600)
            elif s['role']=='client' and JOIN.exists():raise SetupError('此机已有服务端加入文件，拒绝覆盖/换角色。')
            if args.join_output:
                if s['role']!='server':raise SetupError('--join-output 仅服务端使用。')
                dst=Path(args.join_output)
                if dst!=JOIN:
                    if not dst.is_absolute() or dst.exists() or dst.is_symlink() or dst.parent.stat().st_uid!=0 or dst.parent.stat().st_mode & 0o077:raise SetupError('加入文件路径必须是新文件、父目录 root 所有且权限 0700。')
                    atom(dst,JOIN.read_bytes(),0o600)
            if not UNIT_LINK.exists():UNIT_LINK.symlink_to(UNIT_FILE)
            run(['systemctl','daemon-reload'])
            if was['active']:run(['systemctl','stop',UNIT])
            run(['systemctl','enable',UNIT]);run(['systemctl','start',UNIT]);health()
            print(f"安装成功：EasyTier {rel['tag']}，{s['role']} {s['name']} / {s['ip']}")
            if s['role']=='server':
                print('CF Tunnel 你自己配置：回源 http://127.0.0.1:11011，cloudflared 固定 --protocol http2。')
                print('加入文件：/etc/easytier/join.json（root-only，通过 SSH/SCP 传输）。')
            else:print(peer_check())
            print('状态：sudo python3 /etc/easytier/easytier-cf-debian.py --status')
            print('回滚：sudo python3 /etc/easytier/easytier-cf-debian.py --rollback '+str(bak))
        except Exception as exc:
            print('安装失败，正在回滚：'+str(bak),file=sys.stderr)
            try:rollback(bak)
            except Exception as e:print('自动回滚失败：'+type(e).__name__+'；保留备份。',file=sys.stderr)
            raise
        finally:shutil.rmtree(stage,ignore_errors=True)


def health():
    end=time.monotonic()+20
    while time.monotonic()<end:
        if run(['systemctl','is-active',UNIT],check=False).stdout.strip()=='active' and run([str(CLI),'-p',f'127.0.0.1:{RPC}','node','info'],timeout=5,check=False).returncode==0:return
        time.sleep(1)
    raise SetupError('服务健康检查失败；使用回滚备份目录。')


def peer_check():
    end=time.monotonic()+15
    while time.monotonic()<end:
        p=run([str(CLI),'-p',f'127.0.0.1:{RPC}','-o','json','peer'],check=False)
        try:d=json.loads(p.stdout) if p.returncode==0 else []
        except ValueError:d=[]
        if any(x.get('hostname')=='vps' and x.get('tunnel_proto')=='wss' for x in d if isinstance(x,dict)):return 'WSS peer 已连接。'
        time.sleep(1)
    return '本地服务运行，但暂未确认 WSS peer。检查你的 Tunnel 已回源 127.0.0.1:11011，cloudflared 使用 HTTP/2。'


def status():
    s=load_state()
    if not s:raise SetupError('没有本脚本安装状态。')
    print(f"{s['version']} | {s['role']} {s['name']} | {s['ip']} | {run(['systemctl','is-active',UNIT],check=False).stdout.strip()}")
    if s['role']=='client':print(peer_check())
    print('只声明组网数据隧道使用 TCP；不承诺系统绝无 UDP socket。')


def main():
    p=argparse.ArgumentParser(description='Debian EasyTier 虚拟局域网；WSS/WS over TCP；不配置 Cloudflare Tunnel。')
    p.add_argument('--role',choices=('server','client'));p.add_argument('--domain');p.add_argument('--ip');p.add_argument('--name');p.add_argument('--network');p.add_argument('--join');p.add_argument('--join-output');p.add_argument('--no-prompt',action='store_true');p.add_argument('--update',action='store_true');p.add_argument('--dry-run',action='store_true');p.add_argument('--status',action='store_true');p.add_argument('--latest-version',action='store_true');p.add_argument('--rollback')
    args=p.parse_args()
    if args.latest_version:
        r=latest_release();print(r['tag'],r['asset'],'sha256:'+r['digest']);return 0
    if args.status:
        if os.geteuid()!=0:raise SetupError('请用 sudo。')
        status();return 0
    if args.dry_run:
        r=latest_release()
        install(args,r)
        return 0
    if args.rollback:env_check();rollback(args.rollback);return 0
    r=latest_release();install(args,r);return 0

if __name__ == '__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:print('中止；保留 /etc/easytier/backups。',file=sys.stderr);sys.exit(130)
    except SetupError as e:print('错误：'+str(e),file=sys.stderr);sys.exit(1)
    except Exception as e:print('内部错误：'+type(e).__name__+'；保留备份，不重复盲装。',file=sys.stderr);sys.exit(1)
