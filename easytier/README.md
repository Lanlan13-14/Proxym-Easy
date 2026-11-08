# Debian EasyTier：CF TCP 虚拟局域网

[KNOWN] 运行同一个交互脚本，选择 VPS 服务端或加入客户端。安装时查询 EasyTier 最新稳定正式版并校验官方资产 SHA-256；程序、运行配置、备份位于 `/etc/easytier`。

```sh
sudo sh -c '
set -eu
d=/etc/easytier
install -d -m 700 "$d" "$d/tmp" "$d/backups"
f=$(mktemp "$d/tmp/installer.XXXXXX.py")
trap '\''rm -f "$f"'\'' EXIT HUP INT TERM
curl -fL --retry 2 --connect-timeout 15 --max-time 90 --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/easytier/easytier-cf-debian.py \
  -o "$f"
python3 -c "import ast,pathlib,sys; b=pathlib.Path(sys.argv[1]).read_bytes(); assert len(b)>10000; ast.parse(b)" "$f"
if [ -f "$d/easytier-cf-debian.py" ]; then
  cp -p "$d/easytier-cf-debian.py" "$d/backups/installer-before-download-$(date +%Y%m%d-%H%M%S).py"
fi
chmod 700 "$f"
mv -f "$f" "$d/easytier-cf-debian.py"
exec python3 -u "$d/easytier-cf-debian.py"
'
```

[KNOWN] 下载先写临时文件，检查非空、大小和 Python 语法后才替换脚本，并在替换前保留原脚本；下载失败即停止，不运行空文件。启动立即输出提示，首次先选择角色，再查询最新稳定版；版本请求超时为 25 秒。上述启动提示不等于安装成功，后续仍会进行环境检查和安装。

## 一次性加入（不需要客户端登录 VPS）

1. [KNOWN] VPS 选 `1` 并填写自己的 Tunnel 主机名等字段。安装完成自动生成临时 HTTPS 加入链接；服务端需已安装你管理 Tunnel 用的 `cloudflared`。
2. [KNOWN] 保持该终端运行，把链接复制给自己的客户端。客户端运行同一个脚本，选 `2`，隐藏输入链接，指定唯一虚拟 IP。域名、网络名、密钥从链接自动领取，无需 SCP / SSH 登录 VPS。
3. [KNOWN] 链接最多有效 15 分钟，首次有效领取即失效；临时 Tunnel 随即关闭。GET/HEAD 预览不领取，客户端使用 POST 领取。`Ctrl+C` 可以提前撤销。
4. [KNOWN] 再加一台客户端，在 VPS 重新运行：

```sh
sudo python3 /etc/easytier/easytier-cf-debian.py --invite
```

[KNOWN] 临时链接使用 Cloudflare Quick Tunnel，强制 HTTP/2，不开放额外公网端口，不修改已有 cloudflared 服务或 Tunnel 配置。新建的临时 HTTP 服务仅监听 `127.0.0.1` 随机端口；凭据和 token 仅在内存，临时空 HOME 目录在退出时清理。临时子进程会在网络断开、领取、超时和正常中断时清理；SIGKILL / 掉电不保证运行退出钩子。

[KNOWN] 不再生成长期 `join.json`，升级成功或生成新链接时会移除根目录下的旧 `join.json`。旧备份没有自动删除：其中可能保留旧凭据，且备份运行配置本来就含网络密钥。旧脚本的 `--join-output` 已禁用，`--join` 私有文件导入仅保留兼容。

## 运行与升级

[KNOWN] 用户自行配置正式 CF Tunnel：回源 `http://127.0.0.1:<你指定的端口>`，cloudflared 固定 `--protocol http2`。服务端安装向导会询问回源端口（回车可用默认值，但不固定）；非交互安装用 `--listen-port 你的端口`。升级保留已选端口。临时加入链接和这个正式组网 Tunnel 是两个独立进程。

[KNOWN] 安装完成后，root 直接输入 `easytier-easy`，普通用户输入 `sudo easytier-easy`，呼出管理菜单：查看状态、生成单次链接、升级、修改回源端口。入口 `/usr/local/bin/easytier-easy` 只是指向 `/etc/easytier/easytier-cf-debian.py` 的符号链接，不另存程序副本。

```sh
sudo easytier-easy
sudo easytier-easy --invite
sudo easytier-easy --status
sudo easytier-easy --update
# 可选：升级并修改回源端口（同步修改你自己的正式 Tunnel 配置）
sudo easytier-easy --update --listen-port 18080
```

[KNOWN] 一次性链接是持有即授权的敏感信息；不要发给别人。它只能阻止再次领取，不能撤销已领取的共享网络密钥或踢掉已加入设备；撤销需轮换网络密钥。运行配置必须保存密钥，VPS root 仍可读取。Quick Tunnel 的 HTTPS 在 Cloudflare 边缘终止，不是绕过 Cloudflare 的端到端密文分发。

[KNOWN] 组网数据承载限定 WS/WSS over TCP、内层加密认证保持启用；这不保证整机不会创建 UDP socket。安装器不修改防火墙、DNS、默认路由或其他服务。`--dry-run` 不领取一次性链接，以免预演消耗真实链接。

## 测试

```sh
python3 -m unittest discover -s easytier/tests -v
```
