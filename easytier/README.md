# Debian EasyTier：CF TCP 虚拟局域网

[KNOWN] **从零部署请看：[服务端与客户端完整教程](DEPLOY.md)**，包含同一修复版的下载校验、旧安装卸载、你的域名与回源端口、单次邀请和实际连通验收。

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

1. [KNOWN] VPS 选 `1` 并填写自己的 Tunnel 主机名和回源端口。安装完成后生成 `https://你设置的域名/join/<一次性令牌>`，不再新开随机域名 Tunnel。
2. [KNOWN] 保持领取窗口运行，把完整链接复制给自己的客户端。客户端也须更新同一脚本，选 `2`，隐藏输入链接，指定唯一虚拟 IP。域名、网络名、密钥从链接自动领取，无需 SCP / SSH 登录 VPS。
3. [KNOWN] 链接最多有效 15 分钟，首次有效领取即失效；**只关闭领取权限，不关闭正式 Tunnel 或组网 WebSocket**。GET/HEAD 预览不领取，客户端使用 POST 领取。`Ctrl+C` 可撤销；生成新邀请会立即替换旧邀请。
4. [KNOWN] 再加一台客户端，在 VPS 重新运行：

```sh
sudo python3 /etc/easytier/easytier-cf-debian.py --invite
```

[KNOWN] 正式域名全部回源到 `http://127.0.0.1:<你指定的端口>`。Go 同端口网关把 `/` 的 WebSocket 接到只监听本机的 EasyTier 核心，把 `/join/<令牌>` 的有效 POST 交给内存中的单次邀请处理。Go 网关在服务端 systemd 服务中直接监管核心；安装器 Python 只做交互、事务和管理控制，不再承载持续的 WebSocket 数据转发。没有新增公网端口、不创建其他 Tunnel，也不改动 cloudflared 服务或配置。领取/过期后该邀请即不能再次兑换；正式组网入口保持运行。本机控制 socket 是 `/etc/easytier/tmp/invite-control.sock`（0600，Linux root 身份校验），邀请凭据不落盘。

[KNOWN] Go 网关硬限制最多 64 个并发 HTTP/连接处理槽位、HTTP 请求头最多 32 KiB；不是无限并发服务，也不保证转发零开销。转发使用 Go `net.TCPConn` 直连复制路径，避免旧 Python 手写缓冲循环；实际 Linux 内核是否使用 `splice` 需在支持 ptrace 的目标 VPS / CI runner 单独检查，无法使用 ptrace 时测试会如实跳过，不以连接 inode 连续冒充证据。

[KNOWN] GitHub Actions 对每个受支持架构运行 `go test` 单测、Python 全部安装回归、固定官方 EasyTier v2.6.4 no-TUN 真实组网与领取前后 2 MiB 随机载荷连续性检查、哈希/卸载/信号收尾检查；这只证明 Actions runner 上的 loopback 测试，**不等于真实 CF、用户 VPS、跨洲性能验收**。本地 PRoot 的 ptrace 限制也不证明 splice 是否命中。

[KNOWN] 不再生成长期 `join.json`，升级成功或生成新链接时会移除根目录下的旧 `join.json`。旧备份没有自动删除：其中可能保留旧凭据，且备份运行配置本来就含网络密钥。旧脚本的 `--join-output` 已禁用，`--join` 私有文件导入仅保留兼容。

## 运行与升级

[KNOWN] 用户自行配置正式 CF Tunnel：回源 `http://127.0.0.1:<你指定的端口>`，cloudflared 固定 `--protocol http2`。服务端安装向导会询问回源端口（回车可用默认值，但不固定）；非交互安装用 `--listen-port 你的端口`。升级保留已选端口。领取和正式组网共用这个入口，**必须让 `/join/*` 同样走该回源**，不能仅给 WebSocket 设置单独路径转发。

[KNOWN] 安装完成后，root 直接输入 `easytier-easy`，普通用户输入 `sudo easytier-easy`，呼出管理菜单：查看状态、生成单次链接、升级、修改回源端口。入口 `/usr/local/bin/easytier-easy` 只是指向 `/etc/easytier/easytier-cf-debian.py` 的符号链接，不另存程序副本。

```sh
sudo easytier-easy
sudo easytier-easy --invite
sudo easytier-easy --status
sudo easytier-easy --update
# 可选：升级并修改回源端口（同步修改你自己的正式 Tunnel 配置）
sudo easytier-easy --update --listen-port 18080
```

[KNOWN] 一次性链接是持有即授权的敏感信息；不要发给别人。它只能阻止再次领取，不能撤销已领取的共享网络密钥或踢掉已加入设备；撤销需轮换网络密钥。运行配置必须保存密钥，VPS root 仍可读取。HTTPS 在 Cloudflare 边缘终止，不是绕过 Cloudflare 的端到端密文分发。

[KNOWN] 组网数据承载限定 WS/WSS over TCP、内层加密认证保持启用；这不保证整机不会创建 UDP socket。安装器不修改防火墙、DNS、默认路由或其他服务。`--dry-run` 不领取一次性链接，以免预演消耗真实链接。

## 已安装旧版：迁移到同域领取

[KNOWN] 服务端与客户端都需要更新。旧版客户端只接受随机域名，不能拿它领取新同域链接。下面命令将最新版下载到临时文件，先校验后用 `--repair` 迁移：备份原脚本/服务，不重新下载核心，不轮换网络密钥、不改虚拟 IP 和回源端口；运行中的 EasyTier 服务会重启一次，已有连接会短暂重连。仅下载脚本但不迁移 service，旧核心仍独占回源端口，`--invite` 会明确拒绝。

```sh
sudo sh -c '
set -eu
d=/etc/easytier
install -d -m 700 "$d/tmp"
f=$(mktemp "$d/tmp/migrate.XXXXXX.py")
trap '\''rm -f "$f"'\'' EXIT HUP INT TERM
curl -fL --connect-timeout 15 --max-time 90 --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/easytier/easytier-cf-debian.py -o "$f"
python3 -c "import ast,pathlib,sys; b=pathlib.Path(sys.argv[1]).read_bytes(); assert len(b)>10000; ast.parse(b)" "$f"
python3 -u "$f" --repair
'
```

[KNOWN] 服务端迁移成功后执行 `sudo easytier-easy --invite`。客户端尚未安装时，直接用本文最上面的安装命令，选择 `2`；已安装客户端用以上迁移命令更新脚本。已领取的旧网络密钥依旧有效，不需重新加入。

[KNOWN] HTTP 403 不是足以断定 WAF 的证据。新版客户端发送明确的 `easytier-easy/<版本>` 应用 User-Agent，而不是 Python 标准库的默认签名；识别 403 响应正文的 `error code: 1010`（Browser Integrity Check）和 `cf-mitigated: challenge`，不打印正文或完整链接。1010 先更新客户端，不要为了本脚本关闭整站防护。官方说明：[Error 1010](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/)。

[KNOWN] 如果收到 HTTP 200 但正文为空，不能视作成功；本脚本的领取入口不这样应答，需检查现有域名 `/join/*` 是否被 Worker、其他回源或固定响应覆盖。**不要让无效 token 的空 200 掩盖配置问题，也不要把主页 200 当作组网已通。** 502/504 检查 Tunnel 回源；404 可能是邀请已领取/过期、路径未到新入口或旧 service 未迁移。不要把完整邀请链接、密钥或配置正文发到聊天。

[KNOWN] 本地服务检查与公网组网分开：systemd active 后，指定 `cf-mesh` 实例执行轻量 `connector list` RPC，允许 connector 未连接但必须返回合法 JSON 数组；单次探针超时会在约 30 秒窗口内重试，不再一次 5 秒超时就回滚。此检查仅证明本地实例管理可用，不证明 TUN 收发或公网可达。安装后 peer 查询失败只输出未确认连通，不因此删除已安装服务。最终本地检查失败仍回滚，回滚前保存 root 0600、脱敏的 `backups/<时间>/failure-diagnostics.json`，含 systemd 状态、80 行 journal 和虚拟网卡状态；备份不可公开。

[KNOWN] 生成邀请前，服务端会用 `/join/check/<随机非秘密值>` 分别核对本机回源和正式 HTTPS 域名的响应、随机值和运行实例；不一致就停止签发，不再把明显不可用的链接发给客户端。`easytier-easy --check-tunnel` 可单独只读运行此检查，不领取真实邀请，也不读出密钥。网关服务更新后才能提供该检查，旧服务需先 `--repair`；检查只证明这条 HTTP 路径当时到达同一实例，不证明全部边缘、未来路由或跨节点 TUN 通信。

[KNOWN] **管理检查不再误删已运行的客户端**：如果明确证实当前进程就是所安装核心、持有专属 `127.0.0.1` RPC 监听、TUN 地址正确且 UP，且当前 PID 的新日志明确记录 `Rpc portal client IP ... not in whitelist`，则保留服务与二进制、保存诊断并显示“管理检查未通过”。不把这种情况宣称 RPC 或组网成功，不扩大白名单，不改默认路由、DNS、代理或防火墙。其他健康检查失败仍按原事务回滚。非回环来源为何出现在本机 RPC，需要另查宿主连接改写/网络命名空间等实际因素，不能仅凭这条日志断言哪种工具造成。

## 卸载

```sh
sudo easytier-easy --uninstall
# 或在管理菜单选 5
```

[KNOWN] 输入 `UNINSTALL` 确认才操作；取消不会修改。先备份，再停止/禁用本脚本的组网服务，移除程序、运行配置、systemd 链接和快捷命令。保留 `/etc/easytier/backups`，不递归删除用户其他文件；**不卸载 cloudflared，不改你的 Tunnel、防火墙、DNS、默认路由**。备份含密钥，仍需 root 私有保存；卸载不是网络密钥撤销，其他已加入节点不因此被撤权。

[KNOWN] 卸载前的备份按原始字节复制，不依赖把二进制或损坏的 `settings.json` 解码为文本；本地化命令输出采用 UTF-8 容错解码。只有确认受管 service 标记、路径和状态文件存在后才备份/停止服务；程序文件和未知文件仍受原来的边界检查。安装/修复不会以容错方式忽略损坏状态，避免覆盖错误配置。

## 测试

```sh
python3 -m unittest discover -s easytier/tests -v
```

## Go 网关构建与安全供应链

**状态（2026-11-08）**：Go 网关迁移已完成核心 CI 验收。提交 `e6dc398` 的 push run `42512312008` 已通过 Go vet/unit/race、Python 安装器回归、官方 EasyTier v2.6.4 no-TUN 真实核心组网与前后各 1 MiB 随机载荷，amd64/arm64 静态交叉编译也通过。此前两次失败来自测试诊断和 staging 检查问题，已修复。仓库 Actions 默认 workflow 权限已改为 write；手动 run `42512583000` 的完整测试和编译通过，但按设计跳过仅 push main 执行的 staging。**因此在下一次正常 push 触发并完成自动 staging 前，同目录二进制和 manifest 尚未出现，正式服务器不得迁移。**

- [KNOWN] 安装器在线验证清单所指 Actions run 为成功的本仓库 workflow `push main`，验证提交仍位于当前 main 历史，然后逐一校验架构、大小、SHA-256、ELF 静态链接及 `--version`。绝不在 VPS 编译；客户端下载不获取网关。
- [KNOWN] `--repair` 与首装在 Go binary 下载和验证完成之前保持旧程序和服务；校验或网络失败不静默回退 Python 转发层。成功迁移会重启一次服务，已有会话短暂重连。
- [KNOWN] GitHub Actions 完整通过、生成的双架构二进制/清单经哈希检查并提交之前，仓库 Go 源码可以审查/测试，但正式脚本不能把它当作可部署构建。Actions 没在运行或失败时应保留现有服务，不能声称已完成安装迁移。
- [KNOWN] Go+官方核心集成测试作用于 Actions 上的 Linux loopback / no-TUN，不代表用户的 Debian、真实 Cloudflare Tunnel、公网 TUN 或跨洲吞吐已验收。
