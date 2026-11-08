#!/usr/bin/env python3
import datetime as dt
import argparse
import fcntl
import hashlib
import getpass
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import select
import struct
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
import ssl
from urllib.parse import urlsplit
import zipfile

ROOT = Path('/etc/easytier')
BACKUPS = ROOT / 'backups'
TMP = ROOT / 'tmp'
CORE = ROOT / 'easytier-core'
CLI = ROOT / 'easytier-cli'
GATEWAY = ROOT / 'easytier-gateway'
CFG = ROOT / 'config.toml'
STATE = ROOT / 'settings.json'
JOIN = ROOT / 'join.json'
SCRIPT = ROOT / 'easytier-cf-debian.py'
COMMAND = Path('/usr/local/bin/easytier-easy')
UNIT_FILE = ROOT / 'easytier-cf.service'
UNIT = 'easytier-cf.service'
UNIT_LINK = Path('/etc/systemd/system') / UNIT
RPC = 15888
API = 'https://api.github.com/repos/EasyTier/EasyTier/releases/latest'
MARK = '# Managed by easytier-cf-debian.py'
MANAGED = (CFG, STATE, CORE, CLI, GATEWAY, SCRIPT, UNIT_FILE)
ARCHES = {'x86_64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}
JOIN_TTL = 900
GATEWAY_VERSION = '1.0.0'
MINIMUM_GO_TOOLCHAIN = (1, 27, 3)
GATEWAY_BUILD = 'github-actions/go1.27.3-or-newer'
GATEWAY_BASE_URL = 'https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/easytier/'
GATEWAY_MANIFEST_URL = GATEWAY_BASE_URL + 'easytier-gateway-build.json'
HTTP_USER_AGENT = 'easytier-easy/4 (+https://github.com/Lanlan13-14/Proxym-Easy)'


class SetupError(Exception):
    pass


class CommandTimeout(SetupError):
    pass


def run(argv, timeout=30, check=True):
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace',
                           timeout=timeout, check=False)
    except FileNotFoundError:
        raise SetupError('系统缺少命令：' + str(argv[0])) from None
    except subprocess.TimeoutExpired:
        raise CommandTimeout('命令超时：' + str(argv[0])) from None
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
    if stage.is_symlink() or (stage.exists() and not stage.is_dir()):
        raise SetupError('下载暂存路径不是安全目录。')
    stage.mkdir(mode=0o700,exist_ok=True)
    if any(stage.iterdir()):
        raise SetupError('下载暂存目录必须为空。')
    os.chmod(stage,0o700)
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
    if s.get('subnet')!=str(ip.network):
        raise SetupError('本机虚拟 IP 必须位于服务端声明的同一 /24 子网。')
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
    if s.get('role')=='server':
        s['listen_port']=parse_port(s.get('listen_port',11011))
    return s


def parse_port(value):
    try: port=int(value)
    except (ValueError,TypeError): raise SetupError('回源端口必须为 1-65535 的整数。') from None
    if isinstance(value,bool) or not 1<=port<=65535 or port==RPC: raise SetupError('回源端口须为 1-65535，且不能与本机 RPC 端口冲突。')
    return port


def q(x):
    return json.dumps(x,ensure_ascii=True)


def render(s,version):
    listener=json.dumps(['ws://127.0.0.1:'+str(parse_port(s.get('listen_port',11011)))]) if s['role']=='server' else '[]'
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


def unit_text(s=None):
    s=s or load_state() or {}
    command=(str(SCRIPT)+' --serve-gateway') if s.get('role')=='server' else (str(CORE)+' -c '+str(CFG)+' --rpc-portal 127.0.0.1:15888 --console-log-level warn --file-log-level off')
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
ExecStart={command}
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
    meta={'format':'easytier-cf-backup-v1','present':present,'link':os.path.realpath(UNIT_LINK) if UNIT_LINK.is_symlink() else None,'systemd':svc_state(),'shortcut':COMMAND.is_symlink() and os.path.realpath(COMMAND)==str(SCRIPT)}
    atom(d/'backup.json',json.dumps(meta,indent=2),0o600)
    return d


def load_state():
    if not STATE.exists(): return None
    if STATE.is_symlink() or STATE.stat().st_mode & 0o077: raise SetupError('状态文件不是安全的 root 私有文件。')
    try:
        d=json.loads(STATE.read_text(encoding='utf-8'))
    except (UnicodeError,ValueError):
        raise SetupError('settings.json 不是有效 UTF-8 状态文件；拒绝安装/修复覆盖。卸载会按原始字节备份，不需要解析此文件。') from None
    if not isinstance(d,dict) or d.get('format')!='easytier-cf-state-v1': raise SetupError('现有状态不属于此脚本。')
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



def parse_join(raw):
    if len(raw)>32768: raise SetupError('加入数据超过限制。')
    try: j=json.loads(raw)
    except (ValueError,UnicodeError): raise SetupError('加入数据不是有效 JSON。') from None
    required=('domain','network','secret','subnet','server_name')
    if not isinstance(j,dict) or j.get('format')!='easytier-cf-join-v1' or any(not isinstance(j.get(k),str) for k in required):
        raise SetupError('加入数据格式不匹配。')
    try: net=ipaddress.ip_network(j['subnet'],strict=True)
    except ValueError: raise SetupError('加入子网格式错误。') from None
    if net.version!=4 or net.prefixlen!=24: raise SetupError('加入数据只支持 IPv4 /24。')
    validate(dict(j,role='client',name='client',ip=str(net.network_address+2)+'/24'))
    return j


def read_join(path):
    p=Path(path)
    if not p.is_absolute() or p.is_symlink() or not p.is_file() or p.stat().st_mode & 0o077 or p.stat().st_size>32768:
        raise SetupError('加入文件需是 0600 普通文件。')
    return parse_join(p.read_bytes())


def fetch_join_link(link):
    try:
        u=urlsplit(link)
        good=(u.scheme=='https' and u.port in (None,443) and u.hostname is not None
              and not u.hostname.endswith('.trycloudflare.com')
              and not re.fullmatch(r'[0-9.]+',u.hostname)
              and len(u.hostname)<=253 and '.' in u.hostname
              and all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',part) for part in u.hostname.split('.'))
              and not u.username and not u.password and not u.query and not u.fragment
              and re.fullmatch(r'/join/[0-9a-f]{64}',u.path))
    except ValueError: good=False
    if not good: raise SetupError('请输入最新版服务端生成的 https://你的Tunnel域名/join/<64位令牌>；旧随机域名链接已停用。')
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs): return None
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect)
    try:
        req=urllib.request.Request(link,method='POST',data=b'',headers={
            'User-Agent':HTTP_USER_AGENT,'Accept':'application/json',
            'Cache-Control':'no-store','X-EasyTier-Join':'1'})
        with opener.open(req,timeout=25) as r: raw=r.read(32769)
    except urllib.error.HTTPError as exc:
        # Inspect only bounded error content for a diagnostic code; never echo it or the URL.
        diagnostic=b''
        if exc.code==403:
            try: diagnostic=exc.read(16384)
            except (OSError,TimeoutError,ValueError): pass
        headers=exc.headers or {}
        ray=headers.get('CF-Ray','')
        ray='；Ray ID '+ray if re.fullmatch(r'[A-Za-z0-9-]{1,80}',ray) else ''
        meaning={301:'意外重定向',302:'意外重定向',403:'请求被拒绝，需查看边缘错误类型',404:'链接过期、已领取或不是最新版服务端入口',405:'领取方法被拒绝',502:'Tunnel 回源失败',503:'服务未就绪',504:'Tunnel 回源超时'}.get(exc.code,'HTTP 请求失败')
        if exc.code==403:
            if re.search(rb'(?:error\s*code\s*:\s*1010|\bError\s+1010\b)',diagnostic,re.I):
                meaning='边缘错误 1010：客户端签名被 Browser Integrity Check 拒绝；请更新客户端，不要关闭整站防护'
            elif headers.get('cf-mitigated','').lower()=='challenge':
                meaning='边缘返回人机挑战，程序无法完成；检查此路径的策略'
        raise SetupError(f'一次性领取失败：HTTP {exc.code}（{meaning}）{ray}；请勿发送完整令牌。') from None
    except urllib.error.URLError as exc:
        reason=exc.reason
        detail='TLS 证书校验失败' if isinstance(reason,ssl.SSLError) else ('DNS 解析失败' if isinstance(reason,socket.gaierror) else ('连接超时' if isinstance(reason,(TimeoutError,socket.timeout)) else '网络连接失败'))
        raise SetupError('一次性领取失败：'+detail+'；检查本机到自己 Tunnel 域名的 HTTPS，勿发送完整令牌。') from None
    except (OSError,TimeoutError): raise SetupError('一次性领取失败：连接中断或超时；凭据可能已领取，请重新生成链接。') from None
    if not raw.strip():
        raise SetupError('领取地址返回 HTTP 200 但响应为空；未收到凭据。请检查此域名 /join/* 是否被 Worker、其他回源或固定响应覆盖，不能将空 200 当作成功。')
    joined=parse_join(raw)
    if joined['domain'].lower()!=u.hostname.lower():
        raise SetupError('领取数据中的组网域名与链接域名不一致；拒绝安装，请核对服务端 Tunnel 配置。')
    return joined


def control_path(): return TMP/'invite-control.sock'


def control_call(command,token=None):
    try:
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
            connection.settimeout(5); connection.connect(str(control_path()))
            connection.sendall(json.dumps({'command':command,'token':token}).encode()+b'\n')
            with connection.makefile('rb') as stream: raw=stream.readline(4097)
        if len(raw)>4096: raise ValueError()
        result=json.loads(raw)
        if not isinstance(result,dict) or not result.get('ok'): raise ValueError()
        return result
    except (OSError,ValueError):
        raise SetupError('同域领取入口未运行；请先用最新版脚本 --repair 更新本机服务，不需重设密钥、IP 或 Tunnel。') from None


def probe_tunnel_endpoint(url,nonce):
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs): return None
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect)
    request=urllib.request.Request(url,method='POST',data=b'',headers={
        'User-Agent':HTTP_USER_AGENT,'Accept':'application/json','Cache-Control':'no-store','X-EasyTier-Join':'1'})
    try:
        with opener.open(request,timeout=10) as response:
            raw=response.read(4097)
    except urllib.error.HTTPError as exc:
        raise SetupError('回源校验返回 HTTP '+str(exc.code)+'；未签发邀请，未修改 Tunnel。') from None
    except (OSError,TimeoutError):
        raise SetupError('回源校验连接失败或超时；未签发邀请，未修改 Tunnel。') from None
    if not raw.strip(): raise SetupError('回源校验收到空 HTTP 200，未到可识别的领取网关；未签发邀请。')
    try: proof=json.loads(raw)
    except (ValueError,UnicodeError): raise SetupError('回源校验响应不是 JSON；未签发邀请。') from None
    if (len(raw)>4096 or not isinstance(proof,dict) or proof.get('format')!='easytier-cf-gateway-v1'
            or proof.get('nonce')!=nonce or not isinstance(proof.get('instance_id'),str)
            or not re.fullmatch(r'[0-9a-f]{32}',proof['instance_id'])):
        raise SetupError('回源校验响应不匹配；未签发邀请。')
    return proof['instance_id']


def check_tunnel():
    if os.geteuid()!=0: raise SetupError('请用 root 执行 --check-tunnel。')
    state=load_state()
    if not state or state.get('role')!='server': raise SetupError('请在已安装的服务端执行回源校验。')
    local=control_call('health')
    instance=local.get('instance_id')
    if not isinstance(instance,str) or not re.fullmatch(r'[0-9a-f]{32}',instance):
        raise SetupError('服务仍是旧版网关；请先用新脚本 --repair，再生成邀请。')
    port=parse_port(local['port']);nonce=secrets.token_hex(16);path='/join/check/'+nonce
    if probe_tunnel_endpoint('http://127.0.0.1:'+str(port)+path,nonce)!=instance:
        raise SetupError('本机回源端口不是当前实例，未签发邀请。')
    domain=local.get('domain')
    if domain!=state.get('domain'): raise SetupError('运行服务与保存域名不一致；请修复本机服务。')
    if probe_tunnel_endpoint('https://'+domain+path,nonce)!=instance:
        raise SetupError('公网域名指向其他网关实例；未签发邀请，请检查 Tunnel 回源。')
    print('回源校验通过：正式 HTTPS 域名与本机 127.0.0.1:'+str(port)+' 是同一实例（未领取凭据，不等于跨节点 TUN 已通过）。',flush=True)
    return local


def issue_join_link():
    if os.geteuid()!=0: raise SetupError('请使用 sudo 运行。')
    state=load_state()
    if not state or state['role']!='server': raise SetupError('请先安装本机服务端，再生成一次性链接。')
    print('签发前验证正式域名与本机网关（不消费邀请）…',flush=True)
    check_tunnel()
    purge_legacy_join(); result=control_call('issue'); token=result['token']
    print('\n一次性链接（粘贴到已更新的客户端向导）：\nhttps://'+result['domain']+'/join/'+token,flush=True)
    print('复用你设置的 Tunnel 和回源端口；15 分钟内单次有效。保持窗口运行，Ctrl+C 撤销；不会关闭组网。',flush=True)
    print('服务端虚拟 IP：'+state['ip']+'；客户端必须使用 '+state['subnet']+' 内未占用主机地址。',flush=True)
    try:
        while True:
            status=control_call('status',token)['status']
            if status!='active':
                print({'consumed':'已领取，领取入口已关闭；组网保持运行。','expired':'链接已到期。','revoked':'链接已撤销。','superseded':'链接已被新邀请替换。'}.get(status,'链接已失效。'),flush=True)
                return
            time.sleep(0.5)
    finally:
        try: control_call('revoke',token)
        except SetupError: pass


def fetch_gateway_manifest():
    request=urllib.request.Request(GATEWAY_MANIFEST_URL,headers={'User-Agent':HTTP_USER_AGENT,'Accept':'application/json'})
    try:
        with urllib.request.urlopen(request,timeout=15) as response: raw=response.read(32769)
    except Exception as exc: raise SetupError('获取 Go 网关构建清单失败：'+type(exc).__name__+'；未切换旧服务。') from None
    if len(raw)>32768: raise SetupError('Go 网关构建清单超过大小限制。')
    try: data=json.loads(raw)
    except (ValueError,UnicodeError): raise SetupError('Go 网关构建清单不是有效 JSON。') from None
    if not isinstance(data,dict) or data.get('format')!='easytier-gateway-build-v1' or data.get('go')!='1.27.3' or data.get('cgo') is not False:
        raise SetupError('Go 网关构建清单格式/Go 安全工具链版本不符，拒绝下载。')
    if not isinstance(data.get('commit'),str) or not re.fullmatch(r'[0-9a-f]{40}',data['commit']):
        raise SetupError('Go 网关构建清单缺少合法的源码提交。')
    run_url='https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/'
    if not isinstance(data.get('run'),str) or not data['run'].startswith(run_url) or not data['run'][len(run_url):].isdigit():
        raise SetupError('Go 网关构建清单不是来自该项目的 Actions 运行。')
    run_id=data['run'][len(run_url):]
    api_root='https://api.github.com/repos/Lanlan13-14/Proxym-Easy/'
    def api_json(url,limit):
        req=urllib.request.Request(url,headers={'User-Agent':HTTP_USER_AGENT,'Accept':'application/vnd.github+json'})
        with urllib.request.urlopen(req,timeout=12) as response: raw=response.read(limit+1)
        if len(raw)>limit: raise ValueError('GitHub API response too large')
        return json.loads(raw)
    try:
        run_meta=api_json(api_root+'actions/runs/'+run_id,32768)
    except Exception: raise SetupError('无法在线核验 Go 网关 Actions 运行及 main 最新源码提交，拒绝使用未验证二进制。') from None
    if (not isinstance(run_meta,dict) or run_meta.get('path')!='.github/workflows/build-easytier-gateway.yml'
            or run_meta.get('head_sha')!=data['commit'] or run_meta.get('event')!='push' or run_meta.get('head_branch')!='main'
            or run_meta.get('status')!='completed' or run_meta.get('conclusion')!='success'):
        raise SetupError('Go 网关不是 GitHub main 当前 Go 源码的成功 Actions 构建；等待 CI 完成后重试。')
    assets=data.get('assets')
    if not isinstance(assets,list) or len(assets)!=2: raise SetupError('Go 网关清单必须精确列出两个目标架构。')
    parsed={}
    for item in assets:
        if not isinstance(item,dict): raise SetupError('Go 网关资产记录无效。')
        name=item.get('name',''); match=re.fullmatch(r'easytier-gateway-linux-(amd64|arm64)',name)
        size=item.get('size'); digest=item.get('sha256')
        if (not match or not isinstance(size,int) or isinstance(size,bool) or not 100_000<=size<=20_000_000
                or not isinstance(digest,str) or not re.fullmatch(r'[0-9a-f]{64}',digest) or name in parsed):
            raise SetupError('Go 网关资产名称、大小或 SHA-256 不合法。')
        arch='x86_64' if match.group(1)=='amd64' else 'aarch64'
        parsed[arch]={'name':name,'size':size,'sha256':digest}
    if set(parsed)!= {'x86_64','aarch64'}: raise SetupError('Go 网关构建缺少固定支持的架构。')
    compare_url='https://api.github.com/repos/Lanlan13-14/Proxym-Easy/compare/'+data['commit']+'...main'
    latest=urllib.request.Request(compare_url,headers={'User-Agent':HTTP_USER_AGENT,'Accept':'application/vnd.github+json'})
    try:
        with urllib.request.urlopen(latest,timeout=12) as response: current_raw=response.read(16385)
        if len(current_raw)>16384: raise ValueError('oversized commit response')
        current=json.loads(current_raw)
    except Exception: raise SetupError('无法在线核验 GitHub main 是否包含网关构建源码，拒绝运行可能过期的二进制。') from None
    if not isinstance(current,dict) or current.get('status') not in ('ahead','identical'):
        raise SetupError('Go 网关源码不属于 GitHub main 当前历史，拒绝使用该构建。')
    data['_validated_run']=run_meta
    return data,parsed


def download_gateway(stage):
    """Fetch only the pinned, Actions-built static executable; never compile on a VPS."""
    arch=ARCHES.get(platform.machine().lower())
    if arch is None: raise SetupError('Go 网关仅支持 x86_64/aarch64。')
    manifest,assets=fetch_gateway_manifest()
    asset=assets.get(arch,{})
    digest=asset.get('sha256',''); size=asset.get('size',0); name=asset.get('name','')
    if (not re.fullmatch(r'[0-9a-f]{64}',digest) or not 100_000<=size<=20_000_000
            or name not in ('easytier-gateway-linux-amd64','easytier-gateway-linux-arm64')):
        raise SetupError('此安装器尚未固定经 GitHub Actions 验证的 Go 网关资产；拒绝回退到 Python 数据面。')
    folder=Path(stage)/'gateway-download'
    if folder.exists() or folder.is_symlink(): raise SetupError('Go 网关暂存路径冲突。')
    folder.mkdir(mode=0o700)
    target=folder/'easytier-gateway'
    url=GATEWAY_BASE_URL+name
    request=urllib.request.Request(url,headers={'User-Agent':HTTP_USER_AGENT,'Accept':'application/octet-stream'})
    h=hashlib.sha256(); total=0
    try:
        with urllib.request.urlopen(request,timeout=45) as response,target.open('xb') as output:
            while True:
                block=response.read(262144)
                if not block: break
                total+=len(block)
                if total>size: raise SetupError('Go 网关下载超过固定资产大小。')
                h.update(block); output.write(block)
            output.flush(); os.fsync(output.fileno())
    except SetupError: raise
    except Exception as exc: raise SetupError('下载 GitHub Actions 构建的 Go 网关失败：'+type(exc).__name__+'；旧服务未切换。') from None
    if total!=size or not secrets.compare_digest(h.hexdigest(),digest):
        raise SetupError('Go 网关大小或 SHA-256 不匹配，拒绝执行。')
    check_gateway_elf(target,arch)
    os.chmod(target,0o755)
    if run([str(target),'--version'],timeout=8).stdout.strip()!='easytier-gateway '+GATEWAY_VERSION:
        raise SetupError('Go 网关版本与固定资产不一致。')
    return target,manifest


def check_gateway_elf(path,arch):
    raw=Path(path).read_bytes()
    machine={'x86_64':62,'aarch64':183}.get(arch)
    if (len(raw)<64 or raw[:6]!=b'\x7fELF\x02\x01' or machine is None
            or struct.unpack_from('<H',raw,18)[0]!=machine):
        raise SetupError('Go 网关不是匹配本机架构的 ELF64 可执行文件。')
    offset=struct.unpack_from('<Q',raw,32)[0]
    stride,count=struct.unpack_from('<HH',raw,54)
    if count>256 or stride<56 or offset+stride*count>len(raw):
        raise SetupError('Go 网关 ELF 程序头不完整。')
    if any(struct.unpack_from('<I',raw,offset+i*stride)[0] in (2,3) for i in range(count)):
        raise SetupError('Go 网关必须是 CGO_ENABLED=0 构建的无动态链接依赖程序。')


def serve_gateway():
    """Exec the Go supervisor; no long-lived Python process or Python data plane."""
    if os.geteuid()!=0: raise SetupError('请用 root 启动组网入口。')
    state=load_state()
    if not state or state.get('role')!='server': raise SetupError('同域入口仅用于已安装的服务端。')
    if GATEWAY.is_symlink() or not GATEWAY.is_file(): raise SetupError('缺少受管 Go 网关；请用新版 --repair 迁移。')
    os.umask(0o077); TMP.mkdir(mode=0o700,parents=True,exist_ok=True); os.chmod(TMP,0o700)
    payload=join_payload(validate(dict(state,secret=read_secret_from_config())))
    boot={'listen_port':parse_port(state['listen_port']),'control_path':str(control_path()),
          'domain':state['domain'],'payload':payload,'core_path':str(CORE),'config_path':str(CFG),'rpc_port':RPC}
    raw=json.dumps(boot,separators=(',',':')).encode()
    if len(raw)>65536 or not hasattr(os,'memfd_create'): raise SetupError('系统不支持安全的内存启动描述符。')
    fd=os.memfd_create('easytier-gateway-boot',flags=os.MFD_CLOEXEC)
    try:
        with os.fdopen(fd,'w+b',closefd=False) as config:
            config.write(raw); config.flush(); config.seek(0)
        os.set_inheritable(fd,True)
        os.execve(str(GATEWAY),[str(GATEWAY),'--config-fd',str(fd)],os.environ.copy())
    finally:
        os.close(fd)


def purge_legacy_join():
    if JOIN.is_symlink() or (JOIN.exists() and not JOIN.is_file()): raise SetupError('旧加入文件路径不安全，拒绝操作。')
    JOIN.unlink(missing_ok=True)


def get_config(args,old,version):
    if args.join or args.join_link:
        if args.dry_run and args.join_link: raise SetupError('dry-run 不会领取/消耗一次性链接。')
        if args.join and args.join_link: raise SetupError('--join 与 --join-link 不能同时使用。')
        if args.role=='server': raise SetupError('加入数据只用于客户端。')
        if args.join:
            j=read_join(args.join)
            if str(Path(args.join).resolve()) == str(JOIN.resolve()): raise SetupError('该旧文件含 VPS 服务端密钥；不可用作客户端加入文件。')
        else: j=fetch_join_link(args.join_link)
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
        if s['role']=='server':
            previous=re.search(r'ws://127\.0\.0\.1:(\d+)',CFG.read_text())
            s['listen_port']=args.listen_port if args.listen_port is not None else s.get('listen_port') or (int(previous.group(1)) if previous else 11011)
        return validate(s)
    print('1) VPS 服务端    2) 加入客户端') if not args.role else None
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
        if args.no_prompt and args.listen_port is None: raise SetupError('服务端 --no-prompt 必须指定 --listen-port。')
        port=parse_port(args.listen_port if args.listen_port is not None else (input('CF Tunnel 回源端口 [11011]（按你的配置填写）: ').strip() or '11011'))
        subnet=str(ipaddress.ip_interface(ip).network)
        secret=secrets.token_urlsafe(40)
        print('已生成 320-bit 随机组网密钥；保存在 root-only 运行配置，加入时使用一次性 HTTPS 链接。')
        return validate({'role':'server','name':name,'ip':ip,'domain':domain,'network':network,'secret':secret,'subnet':subnet,'server_name':name,'listen_port':port,'version':version})
    if not args.no_prompt:
        link=getpass.getpass('粘贴服务端一次性 HTTPS 加入链接（隐藏输入；回车使用手动密钥）: ').strip()
        if link:
            if args.dry_run: raise SetupError('dry-run 不会领取/消耗一次性链接；请正式安装时使用。')
            ip=args.ip or input('本机虚拟 IPv4，例如 10.66.66.2/24（必须唯一）: ').strip()
            if not ip: raise SetupError('每台客户端必须指定唯一虚拟 IP。')
            if '/' not in ip: ip+='/24'
            j=fetch_join_link(link)
            return validate(dict(j,role='client',name=name,ip=ip,version=version))
    domain=args.domain or input('VPS 的 CF Tunnel 公网主机名: ').strip()
    network=args.network or input('服务端设置的私有网络名: ').strip()
    ip=args.ip or input('本机虚拟 IPv4，同一 /24 [10.66.66.2/24]: ').strip() or '10.66.66.2/24'
    subnet=str(ipaddress.ip_interface(ip).network)
    secret=getpass.getpass('输入安全收到的 320-bit 组网密钥（不会回显）: ')
    return validate({'role':'client','name':name,'ip':ip,'domain':domain,'network':network,'secret':secret,'subnet':subnet,'server_name':'vps','version':version})


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

def install_shortcut():
    if COMMAND.is_symlink():
        if os.path.realpath(COMMAND)!=str(SCRIPT): raise SetupError('easytier-easy 命令链接冲突，拒绝覆盖。')
        return
    if COMMAND.exists(): raise SetupError('easytier-easy 命令已存在，拒绝覆盖。')
    COMMAND.parent.mkdir(parents=True,exist_ok=True)
    COMMAND.symlink_to(SCRIPT)


def ownership():
    if (COMMAND.is_symlink() and os.path.realpath(COMMAND)!=str(SCRIPT)) or (COMMAND.exists() and not COMMAND.is_symlink()):
        raise SetupError('easytier-easy 命令冲突，拒绝覆盖。')
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
    meta=json.loads(meta_path.read_text()); names=meta.get('present'); allowed={x.name for x in MANAGED}|{JOIN.name}; files=d/'files'
    if meta.get('format')!='easytier-cf-backup-v1' or not isinstance(names,list) or len(names)!=len(set(names)) or not set(names)<=allowed or {x.name for x in files.iterdir()}!=set(names): raise SetupError('回滚清单与备份文件不匹配。')
    current=snapshot();run(['systemctl','stop',UNIT],check=False)
    for p in MANAGED:
        if p.name not in names and p.exists():
            if p.is_symlink() or not p.is_file():raise SetupError('回滚遇到非普通文件。')
            p.unlink()
    for name in names:
        if name==JOIN.name: continue  # 兼容旧备份，但不恢复已淘汰的长期加入凭据
        src=files/name
        if src.is_symlink() or not src.is_file():raise SetupError('拒绝恢复符号链接。')
        dst=next(x for x in MANAGED if x.name==name)
        mode=0o755 if dst in (CORE,CLI,GATEWAY,SCRIPT) else 0o600
        atom(dst,src.read_bytes(),mode)
    if UNIT_LINK.is_symlink() and os.path.realpath(UNIT_LINK)==str(UNIT_FILE):UNIT_LINK.unlink()
    elif UNIT_LINK.exists():raise SetupError('systemd unit 由其他进程替换。')
    if meta.get('link')==str(UNIT_FILE):UNIT_LINK.symlink_to(UNIT_FILE)
    run(['systemctl','daemon-reload'])
    st=meta.get('systemd',{})
    run(['systemctl','enable' if st.get('enabled') else 'disable',UNIT],check=False)
    run(['systemctl','start' if st.get('active') else 'stop',UNIT],check=False)
    if meta.get('shortcut'): install_shortcut()
    elif COMMAND.is_symlink() and os.path.realpath(COMMAND)==str(SCRIPT): COMMAND.unlink()
    purge_legacy_join()
    print('回滚完成；当前状态已另存：'+str(current))


def install(args,rel):
    if args.dry_run:
        if args.no_prompt and args.role is None: raise SetupError('--no-prompt 时必须提供 --role。')
        env_check(for_write=False)
        old=load_state() if ROOT.exists() else None
        s=get_config(args,old,rel['tag'])
        for path in MANAGED:
            if path.is_symlink():raise SetupError('受管路径是符号链接，dry-run 拒绝：'+str(path))
        if ROOT.exists() and any(path.exists() for path in MANAGED if path!=SCRIPT) and not old:
            raise SetupError('/etc/easytier 存在非本脚本文件；dry-run 拒绝覆盖。')
        print(f"dry-run PASS：{s['role']} {s['ip']} / {rel['tag']}；不下载、不写入、不动 systemd。")
        return
    env_check(for_write=True);os.umask(0o077);ROOT.mkdir(parents=True,exist_ok=True,mode=0o700);os.chmod(ROOT,0o700)
    lock=ROOT/'.installer.lock'
    with lock.open('a') as lf:
        os.chmod(lock,0o600);fcntl.flock(lf,fcntl.LOCK_EX);ownership()
        old=load_state();occupied=[p for p in MANAGED if p.exists() and p!=SCRIPT]
        if occupied and not old:raise SetupError('/etc/easytier 存在非本脚本文件；拒绝覆盖。')
        if old and not args.update:raise SetupError('已安装；升级请明确加 --update。')
        s=get_config(args,old,rel['tag'])
        bak=snapshot();print('已备份：'+str(bak))
        TMP.mkdir(mode=0o700,exist_ok=True);os.chmod(TMP,0o700)
        stage=Path(tempfile.mkdtemp(prefix='stage-',dir=TMP));was=svc_state();committing=False
        try:
            core_new,cli_new=download(rel,stage)
            if s['role']=='server':
                gateway_new,gateway_manifest=download_gateway(stage)
            else:
                gateway_new=None; gateway_manifest=None
            check=stage/'check.toml';check.write_text(render(s,rel['tag']))
            if run([str(core_new),'-c',str(check),'--check-config'],check=False).returncode:raise SetupError('最新官方二进制 TOML 校验失败；旧服务未停止。')
            # Until every downloaded asset and the generated config pass checks,
            # the existing install remains live and no rollback is necessary.
            committing=True
            atom(CFG,render(s,rel['tag']),0o600);atom(CORE,core_new.read_bytes(),0o755);atom(CLI,cli_new.read_bytes(),0o755);atom(SCRIPT,Path(__file__).read_bytes(),0o700);atom(UNIT_FILE,unit_text(s),0o600)
            if gateway_new: atom(GATEWAY,gateway_new.read_bytes(),0o755)
            state={k:s[k] for k in ('role','name','ip','domain','network','subnet','server_name')};state.update({'format':'easytier-cf-state-v1','version':rel['tag'],'backup':str(bak)})
            if s['role']=='server': state.update(listen_port=s['listen_port'],gateway_version=3,gateway_build='go'+gateway_manifest['go']+':'+gateway_manifest['commit'])
            atom(STATE,json.dumps(state,indent=2),0o600)
            if not UNIT_LINK.exists():UNIT_LINK.symlink_to(UNIT_FILE)
            run(['systemctl','daemon-reload'])
            if was['active']:run(['systemctl','stop',UNIT])
            run(['systemctl','enable',UNIT]);run(['systemctl','start',UNIT]);readiness=health()
            purge_legacy_join();install_shortcut()
            print('快捷管理：sudo easytier-easy（root 用户直接 easytier-easy）')
            if readiness=='management-blocked':
                try: capture_failure_diagnostics(bak,'管理 RPC 来源被拒绝；保留进程与配置，未回滚。未确认公网连通。')
                except Exception: print('诊断保存失败；保留已验证的运行核心，不因诊断失败回滚。',file=sys.stderr)
            print(f"{'安装已保留（管理检查未通过）' if readiness=='management-blocked' else '安装成功'}：EasyTier {rel['tag']}，{s['role']} {s['name']} / {s['ip']}")
            if s['role']=='server':
                print(f"CF Tunnel 你自己配置：回源 http://127.0.0.1:{s['listen_port']}，cloudflared 固定 --protocol http2。")
                print('加入客户端：sudo python3 /etc/easytier/easytier-cf-debian.py --invite（生成一次性 HTTPS 链接，无需客户端 SSH 登录 VPS）。')
            elif readiness!='management-blocked':
                try: print(peer_check())
                except (SetupError,OSError): print('本地安装成功，公网 peer 状态暂不可用；保留已安装服务，不因此回滚。')
            print('状态：sudo python3 /etc/easytier/easytier-cf-debian.py --status')
            print('回滚：sudo python3 /etc/easytier/easytier-cf-debian.py --rollback '+str(bak))
        except BaseException as exc:
            # Ctrl-C/SystemExit during commit must restore files and service too.
            if not committing:
                print('安装前下载/配置校验失败；未更改旧安装、未停止现有服务。',file=sys.stderr)
                raise
            try: capture_failure_diagnostics(bak,exc)
            except Exception: print('保存失败诊断未完成；继续安全回滚。',file=sys.stderr)
            print('安装失败，正在回滚：'+str(bak),file=sys.stderr)
            try:rollback(bak)
            except Exception as e:print('自动回滚失败：'+type(e).__name__+'；保留备份。',file=sys.stderr)
            raise
        finally:shutil.rmtree(stage,ignore_errors=True)


def cli_query(command,timeout=4):
    # Always target our one instance; the default CLI fans out to every instance.
    result=run([str(CLI),'-p',f'127.0.0.1:{RPC}','-n','cf-mesh','-o','json']+list(command),timeout=timeout,check=False)
    if result.returncode: return None
    try: return json.loads(result.stdout)
    except (ValueError,UnicodeError): return None


def client_management_blocked():
    """Allow a running client to survive *only* a freshly evidenced management ACL fault.

    This is degraded installation, never a successful RPC or mesh test. Do not change ACLs.
    """
    try:
        state=load_state()
        if not state or state.get('role')!='client': return False
        output=run(['systemctl','show',UNIT,'--no-pager','--property=MainPID,ActiveState,SubState'],timeout=3,check=False)
        props=dict(line.split('=',1) for line in output.stdout.splitlines() if '=' in line)
        pid=int(props.get('MainPID','0'))
        if output.returncode or pid<1 or props.get('ActiveState')!='active' or props.get('SubState')!='running': return False
        process=Path('/proc')/str(pid)
        if not os.path.samefile(process/'exe',CORE): return False
        command=(process/'cmdline').read_bytes().split(b'\0')
        index=command.index(b'--rpc-portal')
        if command[index+1]!=('127.0.0.1:'+str(RPC)).encode() or str(CFG).encode() not in command: return False
        sockets=set()
        for row in (process/'net/tcp').read_text().splitlines()[1:]:
            fields=row.split()
            if len(fields)>9 and fields[1]==f'0100007F:{RPC:04X}' and fields[3]=='0A': sockets.add(fields[9])
        if not sockets or not any(link.is_symlink() and os.readlink(link) in {'socket:['+x+']' for x in sockets} for link in (process/'fd').iterdir()): return False
        address=run(['ip','-j','addr','show','dev','etcf0'],timeout=3,check=False)
        rows=json.loads(address.stdout); target=ipaddress.ip_interface(state['ip'])
        if not isinstance(rows,list) or not any(isinstance(row,dict) and 'UP' in row.get('flags',[]) and
                any(a.get('family')=='inet' and a.get('local')==str(target.ip) and a.get('prefixlen')==target.network.prefixlen
                    for a in row.get('addr_info',[]) if isinstance(a,dict)) for row in rows): return False
        logs=run(['journalctl','-u',UNIT,'_PID='+str(pid),'--since','-40 seconds','-n','40','--no-pager','-o','cat'],timeout=4,check=False)
        if logs.returncode or not re.search(r'Rpc portal client IP \S+ not in whitelist:',logs.stdout): return False
        return True
    except (SetupError,OSError,ValueError,UnicodeError,IndexError,KeyError,TypeError): return False


def health():
    deadline=time.monotonic()+30
    print('等待本机服务与管理 RPC 就绪（最多约 30 秒，不要求公网 peer 已连接）…',flush=True)
    while time.monotonic()<deadline:
        try:
            active=run(['systemctl','is-active',UNIT],timeout=3,check=False).stdout.strip()=='active'
            if active:
                connectors=cli_query(['connector','list'],timeout=min(4,max(0.1,deadline-time.monotonic())))
                if isinstance(connectors,list):
                    state=load_state()
                    if not state or state['role']!='server' or state.get('gateway_version',0)<2: return
                    if control_call('health').get('gateway_version') in (2,3): return
        except (CommandTimeout,SetupError,OSError):
            # A startup probe is not a transaction failure. Retry within the outer deadline.
            pass
        if time.monotonic()<deadline: time.sleep(min(1,max(0,deadline-time.monotonic())))
    if client_management_blocked():
        print('警告：核心进程、专属回环 RPC 监听和虚拟网卡均存在，但当前进程日志证实管理来源被白名单拒绝。保留运行服务，不放宽白名单；RPC 与完整组网尚未验收。',flush=True)
        return 'management-blocked'
    raise SetupError('本机服务/RPC 在约 30 秒内未就绪；不是已证实的公网 peer 失败。已触发安全回滚，请查看回滚前诊断。')


def peer_check():
    deadline=time.monotonic()+12
    state=load_state() or {}
    last='尚未检测到服务端 WSS peer'
    while time.monotonic()<deadline:
        try:
            rows=cli_query(['peer'],timeout=min(3,max(0.1,deadline-time.monotonic())))
            if isinstance(rows,list):
                for row in rows:
                    if not isinstance(row,dict) or row.get('cost')=='Local': continue
                    protos={part.strip().lower() for part in str(row.get('tunnel_proto','')).split(',')}
                    # Manual enrollment does not know the server hostname; WS/TLS proves a tunnel,
                    # and the inner network authentication proves membership, not its chosen name.
                    if 'wss' in protos and row.get('ipv4')!=str(state.get('ip','')).split('/')[0]:
                        return 'WSS peer 已连接（不等于已完成跨节点 TUN 数据收发测试）。'
        except (CommandTimeout,SetupError,OSError): last='本机 peer 查询超时或暂不可用'
        if time.monotonic()<deadline: time.sleep(min(1,max(0,deadline-time.monotonic())))
    return '本地安装保留；'+last+'。未确认组网连通，请检查正式 Tunnel 回源和组网认证。'


def capture_failure_diagnostics(backup,reason):
    """Persist bounded, redacted evidence BEFORE rollback stops/removes the new program."""
    secrets_to_remove=[]
    try: secrets_to_remove.append(read_secret_from_config())
    except (SetupError,OSError,UnicodeError): pass
    def scrub(text):
        text=str(text)
        for value in secrets_to_remove:
            if value: text=text.replace(value,'[REDACTED]')
        text=re.sub(r'(?i)(/join/)[0-9a-f]{64}',r'\1[REDACTED]',text)
        text=re.sub(r'(?im)((?:network_secret|password|access_token|"secret")\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|\x27[^\x27]*\x27|[^\s,}]+)',r'\1"[REDACTED]"',text)
        return text[:65536]
    report={'format':'easytier-failure-v1','reason':scrub(reason),'note':'Captured before rollback; redacted, root-private. Do not publish full logs.'}
    commands=(('systemd',['systemctl','show',UNIT,'--no-pager','--property=ActiveState,SubState,MainPID,ExecMainStatus,Result,NRestarts']),
              ('journal',['journalctl','-u',UNIT,'-b','-n','80','--no-pager','-o','cat']),
              ('rpc_listener',['ss','-ltnp','sport = :'+str(RPC)]),
              ('interface',['ip','-j','addr','show','dev','etcf0']))
    for key,argv in commands:
        try:
            result=run(argv,timeout=4,check=False)
            report[key]={'exit':result.returncode,'stdout':scrub(result.stdout),'stderr':scrub(result.stderr)}
        except (SetupError,OSError) as exc: report[key]={'error':type(exc).__name__}
    target=Path(backup)/'failure-diagnostics.json'
    atom(target,json.dumps(report,ensure_ascii=False,indent=2),0o600)
    print('回滚前诊断已保存（root 私有、已脱敏）：'+str(target),file=sys.stderr,flush=True)
    return target


def status():
    s=load_state()
    if not s:raise SetupError('没有本脚本安装状态。')
    print(f"{s['version']} | {s['role']} {s['name']} | {s['ip']} | {run(['systemctl','is-active',UNIT],check=False).stdout.strip()}")
    if s['role']=='client':print(peer_check())
    print('只声明组网数据隧道使用 TCP；不承诺系统绝无 UDP socket。')


def repair_gateway():
    env_check(for_write=False); os.umask(0o077); ownership()
    with (ROOT/'.installer.lock').open('a') as lock:
        os.chmod(ROOT/'.installer.lock',0o600); fcntl.flock(lock,fcntl.LOCK_EX)
        state=load_state()
        if not state: raise SetupError('请先安装，再使用 --repair。')
        backup=snapshot(); print('已备份：'+str(backup),flush=True)
        TMP.mkdir(mode=0o700,parents=True,exist_ok=True); os.chmod(TMP,0o700)
        stage=Path(tempfile.mkdtemp(prefix='gateway-stage-',dir=TMP))
        try:
            gateway_new,gateway_manifest=download_gateway(stage) if state['role']=='server' else (None,None)
            gateway_build=(f"go{gateway_manifest['go']}:{gateway_manifest['commit']}" if gateway_manifest else None)
        except BaseException:
            shutil.rmtree(stage,ignore_errors=True)
            print('Go 网关下载/校验失败；未替换文件、未重启旧服务。',file=sys.stderr)
            raise
        was=svc_state()
        try:
            if gateway_new: atom(GATEWAY,gateway_new.read_bytes(),0o755)
            if state['role']=='server':
                previous=re.search(r'ws://127\.0\.0\.1:(\d+)',CFG.read_text())
                state['listen_port']=parse_port(state.get('listen_port') or (int(previous.group(1)) if previous else 11011))
                state['gateway_version']=3
                state['gateway_build']=gateway_build
            source=Path(__file__).read_bytes()
            atom(SCRIPT,source,0o700); atom(STATE,json.dumps(state,indent=2),0o600)
            atom(UNIT_FILE,unit_text(state),0o600)
            if not UNIT_LINK.exists(): UNIT_LINK.symlink_to(UNIT_FILE)
            purge_legacy_join(); install_shortcut()
            run(['systemctl','daemon-reload'])
            if was['active']:
                run(['systemctl','restart',UNIT]); health()
            print('本机脚本/服务已更新；保留核心版本、网络密钥、虚拟 IP、回源端口。'+('服务已重启，连接会短暂重连。' if was['active'] else '原服务未运行，未自动启动。'),flush=True)
        except BaseException as exc:
            try: capture_failure_diagnostics(backup,exc)
            except Exception: print('保存失败诊断未完成；继续安全回滚。',file=sys.stderr)
            print('修复失败，正在恢复原服务。',file=sys.stderr)
            rollback(backup); raise
        finally:
            shutil.rmtree(stage,ignore_errors=True)


def uninstall():
    if os.geteuid()!=0: raise SetupError('请运行 sudo easytier-easy --uninstall。')
    if ROOT.is_symlink(): raise SetupError('安装目录是符号链接，拒绝卸载。')
    if not ROOT.exists(): raise SetupError('未找到本脚本安装目录。')
    print('将停止并移除本脚本的 EasyTier 服务、程序、运行配置和 easytier-easy 命令。',flush=True)
    print('会先保留 root 私有备份；不删除 cloudflared，不修改你的 Tunnel、DNS、默认路由或防火墙。',flush=True)
    if input('确认卸载请输入 UNINSTALL（其他输入取消）: ').strip()!='UNINSTALL':
        print('已取消，未修改。'); return
    lockpath=ROOT/'.installer.lock'
    with lockpath.open('a') as lock:
        os.chmod(lockpath,0o600); fcntl.flock(lock,fcntl.LOCK_EX); ownership()
        if not UNIT_FILE.is_file() or MARK.encode() not in UNIT_FILE.read_bytes():
            raise SetupError('缺少本脚本的受管 service 标记，拒绝卸载未知程序。')
        if not STATE.is_file():
            raise SetupError('缺少本脚本状态文件，拒绝删除未知程序。')
        # Uninstall backs up metadata byte-for-byte; corrupt JSON/locale must not brick removal.
        if JOIN.is_symlink() or (JOIN.exists() and not JOIN.is_file()): raise SetupError('旧加入文件路径冲突，拒绝卸载。')
        backup=snapshot(); print('卸载前备份：'+str(backup),flush=True)
        # Stop must succeed: never unlink a live supervised program.
        run(['systemctl','stop',UNIT])
        if svc_state()['active']: raise SetupError('服务仍在运行，停止卸载；备份已保留。')
        run(['systemctl','disable',UNIT],check=False)
        if UNIT_LINK.is_symlink() and os.path.realpath(UNIT_LINK)==str(UNIT_FILE): UNIT_LINK.unlink()
        if COMMAND.is_symlink() and os.path.realpath(COMMAND)==str(SCRIPT): COMMAND.unlink()
        for path in MANAGED:
            if path.is_symlink() or (path.exists() and not path.is_file()): raise SetupError('受管文件被替换，停止卸载。')
            path.unlink(missing_ok=True)
        purge_legacy_join()
        control=control_path()
        if control.exists() and not control.is_symlink() and stat.S_ISSOCK(control.stat().st_mode): control.unlink()
        run(['systemctl','daemon-reload'])
        run(['systemctl','reset-failed',UNIT],check=False)
    lockpath.unlink(missing_ok=True)
    print('卸载完成。保留备份：'+str(backup),flush=True)
    print('备份可能含组网密钥，不要公开；未递归删除 /etc/easytier 中的其他文件。',flush=True)


def main():
    p=argparse.ArgumentParser(description='Debian EasyTier 虚拟局域网；WSS/WS over TCP；不配置 Cloudflare Tunnel。')
    p.add_argument('--check-tunnel',action='store_true',help='只读核对正式域名与本机回源，不领取凭据');p.add_argument('--serve-gateway',action='store_true',help=argparse.SUPPRESS);p.add_argument('--uninstall',action='store_true',help='确认后备份卸载，仅移除本脚本组件');p.add_argument('--repair',action='store_true',help='保留二进制和组网设置，修复/升级本机同域入口');p.add_argument('--role',choices=('server','client'));p.add_argument('--domain');p.add_argument('--listen-port',type=int,help='服务端回源 WS 端口，交互时询问，升级保留原值');p.add_argument('--ip');p.add_argument('--name');p.add_argument('--network');p.add_argument('--join');p.add_argument('--join-output',help=argparse.SUPPRESS);p.add_argument('--join-link');p.add_argument('--invite',action='store_true');p.add_argument('--no-prompt',action='store_true');p.add_argument('--update',action='store_true');p.add_argument('--dry-run',action='store_true');p.add_argument('--status',action='store_true');p.add_argument('--latest-version',action='store_true');p.add_argument('--rollback')
    args=p.parse_args()
    if args.check_tunnel:
        check_tunnel();return 0
    if args.uninstall:
        uninstall();return 0
    if args.serve_gateway:
        serve_gateway();return 0
    if args.repair:
        repair_gateway();return 0
    if not args.latest_version:
        print('EasyTier 安装/管理脚本已启动。',flush=True)
    if not sys.argv[1:] and STATE.exists():
        if os.geteuid()!=0: raise SetupError('请运行 sudo easytier-easy。')
        print('\nEasyTier 管理\n1) 查看状态\n2) 生成一次性加入链接\n3) 升级最新版\n4) 修改服务端回源端口\n5) 卸载（保留备份）\n0) 退出')
        choice=input('选择: ').strip()
        if choice=='0': return 0
        if choice=='1': status();return 0
        if choice=='2': issue_join_link();return 0
        if choice=='5': uninstall();return 0
        if choice=='3': args.update=True
        elif choice=='4':
            state=load_state()
            if state['role']!='server': raise SetupError('客户端不提供回源监听端口。')
            args.listen_port=parse_port(input('新的 CF Tunnel 回源端口: ').strip());args.update=True
        else: raise SetupError('无效菜单选项。')
    if args.join_output: raise SetupError('已禁用长期加入文件导出，请使用 --invite 一次性 HTTPS 链接。')
    if args.invite:
        issue_join_link();return 0
    if args.latest_version:
        r=latest_release();print(r['tag'],r['asset'],'sha256:'+r['digest']);return 0
    if args.status:
        if os.geteuid()!=0:raise SetupError('请用 sudo。')
        status();return 0
    if args.rollback:env_check();rollback(args.rollback);return 0
    if not args.role and not args.update and not args.join and not args.join_link:
        if args.no_prompt: raise SetupError('--no-prompt 时必须提供 --role。')
        print('\n1) VPS 服务端\n2) 加入客户端\n0) 退出',flush=True)
        choice=input('选择 1/2/0: ').strip()
        if choice=='0': return 0
        args.role={'1':'server','2':'client'}.get(choice)
        if not args.role: raise SetupError('必须选择 VPS 服务端或加入客户端。')
    print('正在查询最新稳定版（GitHub 网络超时为 25 秒）…',flush=True)
    r=latest_release()
    print('已找到 '+r['tag']+'；进入环境检查与配置向导。',flush=True)
    install(args,r)
    if not args.dry_run and not args.no_prompt and not args.update:
        s=load_state()
        if s and s['role']=='server': issue_join_link()
    return 0

if __name__ == '__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:print('中止；保留 /etc/easytier/backups。',file=sys.stderr);sys.exit(130)
    except SetupError as e:print('错误：'+str(e),file=sys.stderr);sys.exit(1)
    except Exception as e:print('内部错误：'+type(e).__name__+'；保留备份，不重复盲装。',file=sys.stderr);sys.exit(1)
