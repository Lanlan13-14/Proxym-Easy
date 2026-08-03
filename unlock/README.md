# Proxym-Easy DNS Unlock

单镜像流媒体 DNS 解锁，**流媒体出站必须经过 Cloudflare Zero Trust WARP**：

- SmartDNS：容器内明文 DNS + 公网可自定义端口的 DoT（默认不发布 53）
- sniproxy：透明接收客户端对流媒体域名的 HTTP/80、TLS SNI/443
- 可选 SOCKS5：Dante 用户名/密码认证、独立 CIDR 白名单、可靠的 TCP CONNECT
- 官方 Cloudflare One Client：Service Token 加入 Zero Trust，`tunnelonly` Traffic-only 模式
- Fail closed：Zero Trust 注册/连接/`warp=on` 任一步失败，SmartDNS/sniproxy 不启动或容器退出
- Let’s Encrypt：Cloudflare DNS-01 签发 DoT TLS 证书，自动续期后 SIGHUP 重载 SmartDNS
- IP/CIDR 白名单：保护 DNS、DoT、80、443，并保持 WARP 全隧道下的客户端回程路由
- 域名规则：合并 StreamConfig + 1-stream，有效 FQDN 共 600 条
- GitHub Actions：仅手动发布，多架构 amd64/arm64，版本号必填

> `cloudflared Tunnel` 只解决入站连接，不能把 sniproxy 的源站出站流量送入 WARP，因此本方案不使用它实现解锁。这里使用官方 `warp-svc` 的 Zero Trust Traffic-only 隧道。

> 镜像构建边界严格为 `unlock/`：Actions 使用 `context: ./unlock`，Dockerfile 只有 `COPY . /opt/unlock/`，不会把仓库其它目录放进镜像。

---

## 1. 数据路径

```text
白名单客户端
  │
  ├─ DoT:DOT_PORT / DNS:53
  │       ▼
  │   SmartDNS
  │   流媒体 A = UNLOCK_IP
  │
  └─ netflix.com:443 等
          ▼
      解锁机 sniproxy:443
          ▼
      Cloudflare Zero Trust WARP (tunnelonly / MASQUE)
          ▼
      真实流媒体源站
```

启动顺序固定为：

1. Cloudflare DNS-01 签发/验证 DoT 证书。
2. 写入官方 WARP `mdm.xml`。
3. `warp-svc` 通过 Service Token 加入 `WARP_ORGANIZATION`。
4. 校验注册不是 Consumer/Free，并且 organization 正确。
5. 连接 Traffic-only WARP，校验 `cdn-cgi/trace` 中 `warp=on`。
6. 为 `ALLOWED_IPS` 和启用时的 `SOCKS5_ALLOWED_IPS` 添加 main-table 回程策略，避免 WARP 抢走客户端回包。
7. 之后才启动 SmartDNS、sniproxy 和可选 SOCKS5。

WARP 失联时 sniproxy/SOCKS5 会立即停止、容器退出并由 Docker 重启，**不会回退为 VPS 直连出口**。

### 为什么不用 Local Proxy mode

Cloudflare 官方文档说明 Local Proxy mode 的请求有 10 秒限制，不适合持续流媒体连接。因此使用 `service_mode=tunnelonly`：SmartDNS 仍由本容器提供，所有普通出站 IP 流量（包括 sniproxy 源站连接）由 WARP 隧道承载。

---

## 2. Cloudflare Zero Trust 配置

### 2.1 创建 Service Token

Zero Trust → **Access controls / 访问控制 → Service credentials / 服务凭据**：

1. 创建 Service Token。
2. 保存 `Client ID` 和 `Client Secret`；Secret 只显示一次。

### 2.2 允许设备无交互注册

Zero Trust → **Team & Resources / 团队和资源 → Devices / 设备 → Device enrollment permissions**：

- Action：`Service Auth`
- Include：刚创建的 Service Token

`Allow` 对 Service Token 不生效；必须是 `Service Auth`。

### 2.3 Team name

若团队域为：

```text
example.cloudflareaccess.com
```

则：

```env
WARP_ORGANIZATION=example
```

不要填完整 `.cloudflareaccess.com` 域名，也不需要 WARP Connector token。

运行时自动生成的 MDM 结构见 `config/warp-mdm.example.xml`，关键参数：

```xml
<key>organization</key><string>brightandy</string>
<key>auth_client_id</key><string>...</string>
<key>auth_client_secret</key><string>...</string>
<key>service_mode</key><string>tunnelonly</string>
<key>warp_tunnel_protocol</key><string>masque</string>
```

---

## 3. DoT Let’s Encrypt DNS-01

DoT 是 TLS，生产默认：

```env
DOT_TLS_MODE=letsencrypt
DOT_DOMAIN=dot.example.com
LE_EMAIL=admin@example.com
CF_DNS_API_TOKEN=...
```

Cloudflare API Token 最小权限：

- Zone / Zone / Read
- Zone / DNS / Edit
- 资源限制到 `DOT_DOMAIN` 所属单一 Zone

`dot.example.com` 建 A 记录指向 `UNLOCK_IP`，设为 DNS only（灰云）。DNS-01 不需要开放 HTTP-01，因此 `DOT_PORT` 可以改成 9853 等自定义端口。

证书每 `RENEW_CHECK_HOURS` 检查一次，剩余不高于 `RENEW_BEFORE_DAYS` 时续期，成功后向 SmartDNS monitor 发 SIGHUP。

---

## 4. 部署

```bash
cd Proxym-Easy/unlock
cp .env.example .env
chmod 600 .env
```

最小生产配置：

```env
UNLOCK_IP=203.0.113.10
ALLOWED_IPS=198.51.100.8/32
ENABLE_ACL=1

DNS_UDP_PORT=53
DOT_PORT=9853
DOT_DOMAIN=dot.example.com
DOT_TLS_MODE=letsencrypt
LE_EMAIL=admin@example.com
CF_DNS_API_TOKEN=Cloudflare_DNS_API_Token

WARP_ORGANIZATION=example
WARP_CLIENT_ID=xxxxxxxxxxxxxxxx.access
WARP_CLIENT_SECRET=xxxxxxxxxxxxxxxx
ZT_RESTART_HOURS=12
```

启动：

```bash
docker compose up -d --build
docker compose logs -f unlock
```

运行要求：

- Linux 主机具备 `/dev/net/tun` 和 nftables。
- Compose 已提供 NET_ADMIN、NET_RAW、MKNOD、AUDIT_WRITE、SYS_PTRACE。
- 公网只发布 DoT 端口和 sniproxy 的 80/443；明文 DNS/53 默认不发布。
- 80/443 必须空闲；它们不是 ACME/DNS 验证端口，而是流媒体客户端解析到解锁机后实际连接 sniproxy 的端口，不能删除或改成非标准端口。
- `ALLOWED_IPS` 不可为空。它既是 DNS/DoT/SNI 访问白名单，也是 WARP 全隧道下的回程排除列表。
- SOCKS5 不继承 `ALLOWED_IPS`：启用时必须单独配置 `SOCKS5_ALLOWED_IPS`，并同时使用用户名/密码认证。

### 已发布镜像

```yaml
image: ghcr.io/lanlan13-14/proxym-easy-unlock:v1.0.0
```

使用镜像时删除 `build:`，其余环境、端口、capabilities、volumes 保持不变。

---

## 5. 可选 SOCKS5 代理

默认 `ENABLE_SOCKS5=0`，基础 Compose **不会发布** SOCKS5 端口。启用时，编辑 `.env`：

```env
ENABLE_SOCKS5=1
SOCKS5_PORT=1080
SOCKS5_USERNAME=proxyuser
SOCKS5_PASSWORD=替换为高强度密码
# 与 ALLOWED_IPS 完全独立；不要留空，也不要因此放宽 DNS 白名单。
SOCKS5_ALLOWED_IPS=203.0.113.25/32
```

[KNOWN] SOCKS5 使用 Dante 的用户名/密码认证，支持可靠的 TCP CONNECT。Docker bridge 下 UDP ASSOCIATE 会向公网客户端通告容器/WARP 内网中继地址，因此本镜像不伪装成可用：不发布 UDP 中继端口。

使用覆盖文件启动，才会发布 SOCKS TCP 和 UDP 中继端口：

```bash
docker compose -f docker-compose.yml -f docker-compose.socks.yml up -d
```

客户端代理 URI：

```text
socks5h://proxyuser:你的密码@UNLOCK_IP:1080
```

验证 TCP：

```bash
curl --proxy 'socks5h://proxyuser:你的密码@UNLOCK_IP:1080' \
  https://cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|gateway)='
```

应包含 `warp=on`。SOCKS5 仅在 WARP health 检查通过后才启动，WARP 失联时容器 fail-closed。

安全边界：

- `SOCKS5_ALLOWED_IPS` 和 `ALLOWED_IPS` 完全独立；前者不授权 DNS/DoT/SNI，后者不授权 SOCKS。
- 用户名/密码只在 `.env` 和容器 `/etc/shadow`，不写入 Dante 配置或进程命令行。
- SOCKS5 不能使用 `53`、`80`、`443` 或 DoT 端口，避免和现有服务冲突。

## 6. 验证

容器内验证官方 Zero Trust 注册：

```bash
docker compose exec unlock warp-cli --accept-tos registration show
docker compose exec unlock warp-cli --accept-tos settings list
docker compose exec unlock warp-cli --accept-tos status
docker compose exec unlock cat /run/unlock/warp-trace.log
```

期望：

- registration/settings 含你的 organization
- 不是 `Auth Method: Consumer` / `Account type: Free`
- mode 为 Traffic-only / TunnelOnly
- status 为 Connected
- trace 含 `warp=on`

DoT/DNS：

```bash
# 明文 DNS 只在容器内部做健康检查，不发布宿主机 53。
docker compose exec unlock dig @127.0.0.1 netflix.com A +short

# 公网客户端使用 DoT。
openssl s_client -connect 203.0.113.10:9853 \
  -servername dot.example.com -verify_hostname dot.example.com </dev/null
kdig @203.0.113.10 -p 9853 +tls-ca +tls-host=dot.example.com netflix.com A
```

出站故障时：

```bash
docker compose logs --tail=300 unlock
docker compose exec unlock cat /run/unlock/warp-registration.log
docker compose exec unlock cat /run/unlock/warp-settings.log
docker compose exec unlock cat /run/unlock/warp-status.log
docker compose exec unlock cat /run/unlock/warp-trace.log
```

---

## 7. 域名规则

`scripts/gen-domains.sh` 合并：

1. `StreamConfig.yaml`：522 条。
2. `domains/1stream.txt`：从 `1-stream/1stream-public-utils/stream.smartdns.list` 规范化出的 585 条 FQDN。
3. 合并去重后 `domains/all.txt`：600 条有效 FQDN。

不直接覆盖旧表，因为两份来源各自有独有域名；例如 1-stream 补充了 Bilibili、Radiko、meWATCH、StarHub、Shahid、Claude/Sora 等，原 StreamConfig 则保留 Spotify 域名。来源与快照哈希见 `domains/SOURCES.md`。

默认 `FORCE_AAAA_SOA=yes`，防止 IPv4 解锁机上的客户端通过 AAAA 直连真实流媒体源站绕过 sniproxy。

---

## 8. 环境变量

| 变量 | 默认 | 作用 |
|---|---:|---|
| `UNLOCK_IP` | 自动探测 | 流媒体域名返回的解锁机 IP，生产建议显式设置 |
| `ALLOWED_IPS` | 空，拒绝启动 | 访问白名单及 WARP 回程排除 CIDR |
| `DNS_UDP_PORT` | `53` | 容器内部 SmartDNS 明文端口，默认不映射到宿主机 |
| `DOT_PORT` | `853` | 可自定义 DoT 端口 |
| `DOT_DOMAIN` | 无 | DoT TLS 名称/SNI |
| `CF_DNS_API_TOKEN` | 无 | Let’s Encrypt Cloudflare DNS-01 token |
| `WARP_ORGANIZATION` | 无 | Zero Trust team name |
| `WARP_CLIENT_ID` | 无 | Service Token Client ID |
| `WARP_CLIENT_SECRET` | 无 | Service Token Client Secret |
| `WARP_REGISTER_TIMEOUT` | `240` | MDM Service Token 注册超时秒数 |
| `WARP_CONNECT_TIMEOUT` | `120` | WARP Connected 等待秒数 |
| `ZT_RESTART_HOURS` | `12` | 整个容器/WARP 会话的定期干净重启周期 |
| `ENABLE_SOCKS5` | `0` | `1` 启用可选 SOCKS5；还需使用 `docker-compose.socks.yml` |
| `SOCKS5_PORT` | `1080` | SOCKS5 TCP 控制端口 |
| `SOCKS5_USERNAME` / `SOCKS5_PASSWORD` | 无 | SOCKS5 用户名/密码，启用时必填 |
| `SOCKS5_ALLOWED_IPS` | 无 | SOCKS5 独立 CIDR 白名单，启用时必填，不继承 `ALLOWED_IPS` |
| `FORCE_AAAA_SOA` | `yes` | IPv4 部署防止 AAAA 绕过 |
| `PLATFORMS` | `all` | StreamConfig 平台过滤 |
| `REGIONS` | 空 | StreamConfig 地区过滤 |

---

## 9. GitHub Actions / 镜像边界

根工作流 `.github/workflows/build-unlock-image.yml`：

- 仅 `workflow_dispatch` 手动触发
- `version` 必填，例如 `v1.0.0`
- 推送 `<version>` 与 `latest`
- `linux/amd64,linux/arm64`
- `context: ./unlock`
- `file: ./unlock/Dockerfile`

Dockerfile：

```dockerfile
WORKDIR /opt/unlock
COPY . /opt/unlock/
```

因此镜像不会包含仓库其它目录。

---

## 10. 测试

```bash
cd unlock
sh tests/run.sh
```

覆盖：

- 600 条合并域名规则
- SmartDNS DoT、自定义端口、证书路径、AAAA 防绕过
- Let’s Encrypt DNS-01 签发/续期/SmartDNS 重载
- 官方 WARP MDM Service Token、`tunnelonly`、MASQUE、Consumer 拒绝
- WARP fail-closed 启动顺序与回程策略
- Compose 接线及 `unlock/` 构建上下文隔离
