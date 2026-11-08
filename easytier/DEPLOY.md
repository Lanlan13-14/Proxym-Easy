# Debian 从零部署教程

[KNOWN] 本教程服务端和客户端使用同一份 `main` 修复脚本（下方固定 SHA-256 校验），安装时仍动态获取 EasyTier 最新稳定正式版。以下命令均在各机器的 root 终端运行。

[KNOWN] **已有服务端不要为了升级而卸载重装**：下载后用 `--repair` 保留网络密钥、IP 和端口，再运行 `--invite`。客户端被旧版回滚撤销时，重新运行 `--role client`；保留中的客户端用 `--repair`。本版修复已证实的“RPC 管理拒绝导致误回滚”，不宣称 RPC 来源改写的底层诱因已修复。生成邀请前新增同实例回源验证；公网空 200 时拒绝签发，避免继续发出不可用链接。

## 1. 前提与范围

- [KNOWN] 两端要求 Debian、systemd、可用 `/dev/net/tun`；根分区至少留 512 MiB 可用空间。
- [KNOWN] 你自行管理正式 Tunnel。本教程只给对应关系，不安装、卸载或重配 cloudflared。
- [KNOWN] 按你现有设置：`akamai-sg.neverquit.fun` 的 `/` 和 `/join/*` 均回源 `http://127.0.0.1:22333`，cloudflared 使用 HTTP/2。`22333` 是你的选择，不是脚本固定值；更换端口时两边一起改。
- [KNOWN] 组网承载使用 WS/WSS over TCP，保持内层加密。脚本不接管默认路由或系统 DNS；这不是整机绝无 UDP socket 的承诺。

[KNOWN] 如果依赖未安装，先执行；已具备则跳过：

```sh
apt-get update && apt-get install -y python3 curl ca-certificates iproute2 tar unzip
```

## 2. 服务端、客户端都先下载同一份修复版

[KNOWN] 下面只下载并校验安装器，不安装、不启动或停止服务。下载先写临时文件，SHA-256 校验成功后才放到已知位置；已有的同名临时安装器会先备份。

```sh
(
set -eu
umask 077
d=/etc/easytier
install -d -m 700 "$d" "$d/tmp" "$d/backups"
f=$(mktemp "$d/tmp/download.XXXXXX.py")
trap 'rm -f "$f"' EXIT
curl -fL --connect-timeout 15 --max-time 90 --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/easytier/easytier-cf-debian.py \
  -o "$f"
printf '%s  %s\n' '1300db260a1bd0355a4eefed10bedba4908118e6f1cb9de8bf88c834f23d6e9e' "$f" | sha256sum -c -
python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_bytes())' "$f"
if [ -f "$d/tmp/easytier-setup.py" ]; then
  cp -p "$d/tmp/easytier-setup.py" "$d/backups/setup-before-download-$(date +%Y%m%d-%H%M%S).py"
fi
chmod 700 "$f"
mv -f "$f" "$d/tmp/easytier-setup.py"
)
```

[KNOWN] 看到 `...: OK` 表示安装器校验通过；命令失败就停在这里，不跳过校验继续运行。

## 3. 有旧安装才卸载；全新机器跳过

[KNOWN] **仅明确要清空本机组网配置时才卸载**，已有运行服务升级请跳过卸载，用 `python3 -u /etc/easytier/tmp/easytier-setup.py --repair`。主动卸载会断开本机组网会话；输入 `UNINSTALL` 才执行，先备份、不碰 cloudflared 和你的 Tunnel。若上次安装失败已回滚、状态文件不存在，直接去安装步骤。

```sh
python3 -u /etc/easytier/tmp/easytier-setup.py --uninstall
```

[KNOWN] 输入 `UNINSTALL` 后等待明确的“卸载完成”；取消或出错则不要继续覆盖安装。保留 `/etc/easytier/backups`，不要 `rm -rf /etc/easytier`。从零重装服务端会生成新的网络密钥，旧客户端需要重新加入；备份仍可能含旧密钥，不能公开。

## 4. 先安装服务端

[KNOWN] 在你的服务端运行；以下显式使用你已选的域名和端口：

```sh
python3 -u /etc/easytier/tmp/easytier-setup.py --role server --domain akamai-sg.neverquit.fun --listen-port 22333
```

按提示填写：

| 项目 | 填法 |
|---|---|
| 设备名 | [KNOWN] 回车用主机名，或填写自己的 ASCII 名称 |
| 本机虚拟 IPv4 | [KNOWN] 用 `10.20.0.1/24`，前提是没有与已有网络冲突 |
| 私有网络名 | [KNOWN] 可用 `my-cf-mesh`，客户端会从邀请中自动领取 |
| 网络密钥 | [KNOWN] 服务端自动随机生成，不需要填 SSH 密码或私钥 |

[KNOWN] 成功后先验证正式域名与本机回源实例一致，才输出完整链接 `https://akamai-sg.neverquit.fun/join/<64位令牌>`。同屏显示服务端真实 IP/子网；客户端必须从该子网选未使用地址，不要只照抄示例。保持该终端运行，再去客户端操作；令牌不要发到聊天或公开日志。

## 5. 验证正式域名没有被其他响应覆盖

[KNOWN] 如果你仍遇到领取失败，可在服务端另一个终端执行这两个**无密钥、无真实 token** 的检查；它们不会领取邀请：

```sh
# 本机网关：无效路径应返回 404
curl --noproxy '*' -i --connect-timeout 5 --max-time 10 \
  -A 'easytier-easy/3' -H 'X-EasyTier-Join: 1' --data '' \
  http://127.0.0.1:22333/join/diagnostic-not-a-token

# 正式域名：同一路径也应返回 404
curl --noproxy '*' -i --connect-timeout 10 --max-time 20 \
  -A 'easytier-easy/3' -H 'X-EasyTier-Join: 1' --data '' \
  https://akamai-sg.neverquit.fun/join/diagnostic-not-a-token
```

- [KNOWN] 本机 404、公网空 200：公网响应与本机网关不一致；检查现有域名的 Worker、Tunnel 路径规则或其他固定响应，不能靠反复重装解决。
- [KNOWN] 403：查看响应是否含 `error code: 1010` 或挑战标记。新版发送真实应用标识；不要为了本脚本关闭整站防护。
- [KNOWN] 502/504：检查正式 Tunnel 的回源地址与实际监听端口。
- [KNOWN] 两处均 404 只说明这条无效请求的路径一致，不证明真正的邀请和组网数据已成功。

## 6. 再安装客户端

[KNOWN] 客户端也先完成第 2 步，然后运行；`10.20.0.2` 必须没有被其他设备使用：

```sh
python3 -u /etc/easytier/tmp/easytier-setup.py --role client --ip 10.20.0.2/24
```

1. [KNOWN] 填设备名，回车可用主机名。
2. [KNOWN] 粘贴服务端输出的完整 HTTPS 链接。隐藏输入时屏幕不显示字符，这是正常行为；不要只粘贴域名。
3. [KNOWN] 等待安装结果。链接会在领取凭据时立即作废，不是等客户端全部安装完成才作废；后续安装失败需要重新生成链接。

[KNOWN] 下一台客户端用不同虚拟 IP，例如 `.3/24`；每台必须用新的邀请。不要继续使用旧提交 `e7db933` 或 `4dd1a89` 的下载命令。

## 7. 重新发邀请、状态与管理

```sh
# 服务端：重新生成一次性邀请
# 最多有效 15 分钟，Ctrl+C 撤销；新邀请替换旧邀请
easytier-easy --invite

# 两端均可：呼出菜单或查看状态
easytier-easy
easytier-easy --status
systemctl status easytier-cf --no-pager
```

[KNOWN] 服务安装成功后才建立 `easytier-easy` 命令。领取关闭只让 token 失效，不关闭组网，不撤销已领取密钥。最终本地健康检查失败会先保存 root 私有的脱敏诊断再回滚；回滚可能移除新装二进制，不能把之后“文件不存在”当作另一种下载失败。

## 8. 真正验收组网

[KNOWN] 确认双方状态后，在客户端访问服务端虚拟 IP 上**已开启的服务**，例如服务端 SSH 已监听该地址且防火墙允许时：

```sh
ssh root@10.20.0.1
```

[KNOWN] 上述 SSH 只用于自愿验收组网，不是领取凭据的前提。`systemctl active`、RPC 就绪、主页 HTTP 200 都不能单独证明真实 TUN 数据通信成功。

[KNOWN] 此安装器已通过本地标准库回归和官方核心 no-TUN 测试；用户真实 Debian/TUN/Cloudflare 公网链路仍需按实际结果判断，不能宣称已经端到端通过。
