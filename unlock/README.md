# Proxym-Easy DNS Unlock

单镜像流媒体 DNS 解锁，**流媒体出站必须经过 Cloudflare Zero Trust WARP**：

- SmartDNS：明文 DNS（可选公网发布）+ 公网可自定义端口的 DoT / DoH
- sniproxy：透明接收客户端对流媒体域名的 HTTP/80、TLS SNI/443
- 可选 SOCKS5：RFC1929 用户名/密码（任意字符）、独立 CIDR 白名单、可靠的 TCP CONNECT
- 官方 Cloudflare One Client：Service Token 加入 Zero Trust，`tunnelonly` Traffic-only 模式
- Fail closed：Zero Trust 注册/连接/`warp=on` 任一步失败，SmartDNS/sniproxy/SOCKS5 不启动或容器退出
- Let’s Encrypt：仅在启用 DoT/DoH 时签发共用 TLS 证书；纯明文 DNS **不需要**域名/证书
- IP/CIDR 白名单：DNS、DoT、DoH、80、443、SOCKS5，并保证 WARP 全隧道下的回程
- 可选 unlock-center 控制通道：复用中心既有 DoH TLS 端口，中心 ACL 自动热同步到本机，且未命中 DNS 代查复用同一认证连接
- 域名规则：镜像内嵌 `all.txt` 打底；默认从本仓库 raw 日更（**URL/时刻可改**，可关）；不含 Google / YouTube
- GitHub Actions：仅手动发布，多架构 amd64/arm64，版本号必填

> `cloudflared Tunnel` 只解决入站连接，不能把 sniproxy 的源站出站流量送入 WARP，因此本方案不使用它实现解锁。这里使用官方 `warp-svc` 的 Zero Trust Traffic-only 隧道。

> 镜像构建边界严格为 `unlock/`：Actions 使用 `context: ./unlock`，Dockerfile 只有 `COPY . /opt/unlock/`，不会把仓库其它目录放进镜像。

---

## 1. 数据路径

```text
白名单客户端
  │
  ├─ 明文 DNS:DNS_UDP_PORT / DoT:DOT_PORT / DoH:DOH_PORT
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

1. 若启用 DoT/DoH：Cloudflare DNS-01 签发/验证共用证书；纯明文 DNS 跳过。
2. 写入官方 WARP `mdm.xml`。
3. `warp-svc` 通过 Service Token 加入 `WARP_ORGANIZATION`。
4. 校验注册不是 Consumer/Free，并且 organization 正确。
5. 连接 Traffic-only WARP，校验 `cdn-cgi/trace` 中 `warp=on`。
6. 给进入已启用公开服务端口（明文 DNS/DoT/DoH/80/443/SOCKS5）的连接写入 conntrack mark，只让这些连接的回包走 `main`；新建出站仍走 WARP。支持任意 CIDR 包括 `0.0.0.0/0`。
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
<key>organization</key><string>example</string>
<key>auth_client_id</key><string>...</string>
<key>auth_client_secret</key><string>...</string>
<key>service_mode</key><string>tunnelonly</string>
<key>warp_tunnel_protocol</key><string>masque</string>
```

---

## 3. DNS 模式：明文 / DoT / DoH

`ENABLE_DNS` / `ENABLE_DOT` / `ENABLE_DOH` **三者独立**，任意组合，至少启用一个。

| 模式 | 开关 | 是否需要 `DOT_DOMAIN` / 证书 | 说明 |
|---|---|---|---|
| 明文 DNS | `ENABLE_DNS=1` | **否** | UDP/TCP `DNS_UDP_PORT`（默认 53）公网发布；靠 `ALLOWED_IPS` 白名单 |
| DoT | `ENABLE_DOT=1` | **是** | TCP `DOT_PORT`，TLS SNI = `DOT_DOMAIN` |
| DoH | `ENABLE_DOH=1` | **是** | TCP `DOH_PORT`，端点 `https://DOT_DOMAIN:DOH_PORT/dns-query` |

### 3.1 仅最普通的明文 DNS（推荐内网/受控公网）

不需要域名、不需要 Let’s Encrypt、不需要 Cloudflare DNS token：

```env
ENABLE_DNS=1
DNS_UDP_PORT=53
ENABLE_DOT=0
ENABLE_DOH=0
# DOT_DOMAIN / LE_EMAIL / CF_DNS_API_TOKEN 全部可留空
```

客户端：

```bash
dig @UNLOCK_IP netflix.com A +short
# 或
nslookup netflix.com UNLOCK_IP
```

### 3.2 DoT / DoH（需要 TLS）

DoT 与 DoH **共用同一张证书** 与 `DOT_DOMAIN` SNI。任一开启时必须配置 TLS。

```env
DOT_TLS_MODE=letsencrypt
DOT_DOMAIN=dot.example.com
LE_EMAIL=admin@example.com
CF_DNS_API_TOKEN=...

# 只 DoT
ENABLE_DNS=0
ENABLE_DOT=1
DOT_PORT=9853
ENABLE_DOH=0

# 或只 DoH（端口可直接用 9853）
# ENABLE_DNS=0
# ENABLE_DOT=0
# ENABLE_DOH=1
# DOH_PORT=9853

# 或两者都开（端口必须不同）
# ENABLE_DOT=1
# DOT_PORT=9853
# ENABLE_DOH=1
# DOH_PORT=4430
```

#### 3.2.1 Let’s Encrypt + Cloudflare DNS-01（完整步骤）

本镜像 **只实现 Cloudflare DNS-01**（`lego --dns cloudflare`），没有 HTTP-01 / 其它 DNS 厂商。

| 变量 | 是否必填 | 说明 |
|---|---|---|
| `DOT_TLS_MODE=letsencrypt` | 是 | 启用 LE 流程 |
| `DOT_DOMAIN` | 是 | 证书主域名 = DoT SNI = DoH 主机名 |
| `LE_EMAIL` | 是 | LE 账号与到期邮件 |
| `CF_DNS_API_TOKEN` | 是 | 见下方 Token 权限 |
| `DOT_EXTRA_DOMAINS` | 否 | 额外 SAN，逗号分隔 |
| `LEGO_CA_SERVER` | 否 | 默认生产 CA；可改 staging 测签发 |
| `RENEW_CHECK_HOURS` | 否 | 默认 12：后台多久检查一次 |
| `RENEW_BEFORE_DAYS` | 否 | 默认 30：剩余 ≤ 该天数则续期 |

**Cloudflare 准备：**

1. 域名 NS 已切到 Cloudflare。  
2. 为 `DOT_DOMAIN` 建 **A/AAAA → `UNLOCK_IP`**。证书申请阶段建议 **仅 DNS（灰云）**。  
3. 创建 API Token：  
   - 路径：My Profile → API Tokens → Create Token  
   - 权限：`Zone` → `Zone` → **Read**；`Zone` → `DNS` → **Edit**  
   - Zone Resources：**Include → Specific zone → 选中该域名所在 zone**  
4. Token 写入 `.env` 的 `CF_DNS_API_TOKEN`（权限过大或 Global Key 不推荐）。

**容器内流程（`scripts/cert-manager.sh`）：**

1. 启动 `ensure`：若本地还没有 `$DOT_DOMAIN.crt/key`，执行 `lego run --dns cloudflare`。  
2. 证书落盘：`/etc/unlock/letsencrypt/certificates/<DOT_DOMAIN>.crt` 与 `.key`（在 compose 数据卷内）。  
3. 后台 `renew-loop`：每 `RENEW_CHECK_HOURS` 小时执行续期检查；剩余天数 ≤ `RENEW_BEFORE_DAYS` 时 `lego renew`。  
4. 续期成功 → **SIGHUP** SmartDNS，重载 TLS。  

**DoH 不占用 443**：443 专供 sniproxy。DoH 默认端口 `4430`，路径固定：

```text
https://DOT_DOMAIN:DOH_PORT/dns-query
```

**自检：**

```bash
# 证书是否生成
docker compose exec unlock ls -l /etc/unlock/letsencrypt/certificates/

# DoT（需系统信任 LE）
# openssl s_client -connect DOT_DOMAIN:DOT_PORT -servername DOT_DOMAIN

# DoH
curl -fsS --doh-url https://DOT_DOMAIN:4430/dns-query https://example.com -o /dev/null && echo ok
```

**常见失败：**

| 现象 | 处理 |
|---|---|
| `CF_DNS_API_TOKEN` invalid | Token 权限/Zone 范围不对或复制多余空格 |
| lego timeout / DNS 未传播 | 等 CF 记录生效；确认灰云；勿挡出站 443 到 LE/CF API |
| 权限不足 | 缺 Zone Read 或 DNS Edit |
| 想试跑怕限频 | `LEGO_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory` 测通后再改回生产 |

`DOT_TLS_MODE=selfsigned` 仅测试；`custom` 需自备证书文件。  
未启用 DoT/DoH 时 cert-manager **跳过**，不要求 `DOT_DOMAIN`。

---

## 4. 部署

```bash
cd Proxym-Easy/unlock
cp .env.example .env
chmod 600 .env
```

### 最小生产配置 A：纯明文 DNS（无域名）

```env
UNLOCK_IP=203.0.113.10
ALLOWED_IPS=198.51.100.8/32
ENABLE_ACL=1

ENABLE_DNS=1
DNS_UDP_PORT=53
ENABLE_DOT=0
ENABLE_DOH=0

WARP_ORGANIZATION=example
WARP_CLIENT_ID=xxxxxxxxxxxxxxxx.access
WARP_CLIENT_SECRET=xxxxxxxxxxxxxxxx
ZT_RESTART_HOURS=12
```

### 最小生产配置 B：只要 DoH

```env
UNLOCK_IP=203.0.113.10
ALLOWED_IPS=198.51.100.8/32
ENABLE_ACL=1

ENABLE_DNS=0
ENABLE_DOT=0
ENABLE_DOH=1
DOH_PORT=9853
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
- 公网发布：已启用的明文 DNS / DoT / DoH 端口，以及 sniproxy 的 80/443。
- `ENABLE_DNS=0` 时 SmartDNS 明文只绑 `127.0.0.1`（健康检查仍可用）；Compose 仍映射 `DNS_UDP_PORT`，但容器内无公网监听，外部连不上有效服务。
- 80/443 必须空闲；它们不是 ACME/DNS 验证端口，而是流媒体客户端解析到解锁机后实际连接 sniproxy 的端口，不能删除或改成非标准端口。
- `ENABLE_DNS` / `ENABLE_DOT` / `ENABLE_DOH` 至少一个为 `1`。
- 启用 DoT 或 DoH 时才需要 `DOT_DOMAIN`（及 `letsencrypt` 下的 `LE_EMAIL` / `CF_DNS_API_TOKEN`）。
- DoT/DoH 两者都开时端口必须不同；`DOT_PORT` / `DOH_PORT` 不能是 `53`/`80`/`443`（且不能等于 `DNS_UDP_PORT`）。
- `ALLOWED_IPS` 不可为空。它既是 DNS/DoT/DoH/SNI 访问白名单，也是 WARP 全隧道下的回程排除列表。
- SOCKS5 不继承 `ALLOWED_IPS`：启用时必须单独配置 `SOCKS5_ALLOWED_IPS`，并同时使用用户名/密码认证。

### 已发布镜像

```yaml
image: ghcr.io/lanlan13-14/proxym-easy-unlock:latest
```

使用镜像时删除 `build:`，其余环境、端口、capabilities、volumes 保持不变。发布含明文 DNS 支持的新版本后改用新 tag。

---

## 4.3 可选：接入 unlock-center 的单端口控制通道

单独部署时，`ALLOWED_IPS` 仍是本机 DNS/SNI 的唯一 ACL，行为没有变化。
但接入 `unlock-center` 时，手动把同一客户端 CIDR 复制到每台数据面既慢又容易漏。

控制通道用**节点主动发起的一个 WSS 连接**复用中心已有 `DOH_PORT`；不会在
`unlock` 或中心增加新监听端口。它做两件事：

1. 中心 `CENTER_ALLOWED_IPS` 作为唯一白名单来源，下发完整快照；本机原子写入后
   热重载 nftables 的 DNS/DoT/DoH/80/443 ACL 和 WARP 回程标记，**不重启**
   SmartDNS/sniproxy。
2. 中心对 `other` 域名选中本节点时，通过同一连接发送 DNS wire query；本机问
   `127.0.0.1:53` 后回传真实结果，避免中心必须公开访问节点的 UDP 53。

数据面 `.env`（`CONTROL_NODE_ID` 与中心 `nodes.toml` 的 `id` 必须严格相等）：

```env
# 仍保留作断联/启动兜底；中心下发快照到达后会与其合并。
ALLOWED_IPS=203.0.113.1/32
ENABLE_ACL=1

CONTROL_CENTER_URL=wss://dns.example.com:443/unlock-control/v1/connect
CONTROL_TOKEN=replace-with-the-same-long-random-secret
CONTROL_NODE_ID=jp-1
CONTROL_RECONNECT_SECS=5
CONTROL_QUERY_TIMEOUT_SECS=0.8
```

中心侧还必须同时设：

```env
CENTER_ALLOWED_IPS=198.51.100.0/24
CENTER_CONTROL_TOKEN=replace-with-the-same-long-random-secret
```

`CONTROL_CENTER_URL` 留空，或中心没有 `CENTER_CONTROL_TOKEN` 时，控制代理不启动，
中心仍按 `nodes.toml` 的 `dns_upstream` UDP 地址代查，数据面仍只使用自身
`ALLOWED_IPS`：这就是旧版本的完整兼容路径。控制连接断开也不会清空已验证的旧快照。

---

## 5. 可选 SOCKS5 代理

默认 `ENABLE_SOCKS5=0`，SOCKS 守护进程不启动。启用时，编辑 `.env`：

```env
ENABLE_SOCKS5=1
SOCKS5_PORT=9857
# RFC1929 任意字符：1-255 字节。中文、空格、@ : / 符号、邮箱形态都可。
# 不是 Linux 账户，不走 /etc/shadow。
SOCKS5_USERNAME=用户@Foo:Bar 1!
SOCKS5_PASSWORD=替换为高强度密码:也行
# 与 ALLOWED_IPS 完全独立；不要留空。
SOCKS5_ALLOWED_IPS=0.0.0.0/0
```

SOCKS5 使用自研 `unlock-socks5d` 的 RFC1929 用户名/密码认证，支持可靠的 TCP CONNECT，出站绑定 CloudflareWARP。Docker bridge 下 UDP ASSOCIATE 会向公网客户端通告容器/WARP 内网中继地址，因此本镜像不伪装成可用：不发布 UDP 中继端口。

字符集边界（协议本身）：

- 用户名、密码各自 **1–255 字节**（UTF-8 多字节按字节计）
- **允许**：中文、空格、`@ : / \ ~ ! # $ % ^ & * ( )`、邮箱形态、数字开头
- **不允许**：空字符串、嵌入式换行 / NUL（Docker env 与多数客户端也带不了）
- 客户端 URI 里若含特殊字符，请做 URL 编码（例如空格 → `%20`，`@` → `%40`，`:` → `%3A`）

这是**同一份 Compose 文件**，不需要 profile 或第二份覆盖文件。`SOCKS5_PORT` 始终映射到宿主机；当 `ENABLE_SOCKS5=0` 时守护进程不启动，连接该端口会被拒绝而不是提供未认证代理。启用 SOCKS 时只需：

```bash
docker compose up -d
```

客户端代理 URI（简单 ASCII 示例）：

```text
socks5h://myuser:mypass@UNLOCK_IP:9857
```

含特殊字符时用 curl 的 `--proxy-user` 更省事：

```bash
curl --proxy "socks5h://UNLOCK_IP:9857" \
  --proxy-user '用户@Foo:Bar 1!:替换为高强度密码:也行' \
  https://cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|gateway)='
```

应包含 `warp=on`。SOCKS5 仅在 WARP health 检查通过后才启动，WARP 失联时容器 fail-closed。

安全边界：

- `SOCKS5_ALLOWED_IPS` 和 `ALLOWED_IPS` 完全独立；前者不授权 DNS/DoT/DoH/SNI，后者不授权 SOCKS。
- 用户名/密码只在 `.env` 与进程环境变量，不写入配置文件、不出现在 argv。
- SOCKS5 不能使用 `80`、`443`、已启用的明文 DNS / DoT / DoH 端口，避免和现有服务冲突。
- `SOCKS5_ALLOWED_IPS` 支持任意 CIDR，包括 `0.0.0.0/0`；公网开放时仍依赖用户名/密码认证，建议用 `/32` 或 `/24` 收紧。

---

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

DNS：

```bash
# 容器内健康检查（始终可用，loopback）
docker compose exec unlock dig @127.0.0.1 netflix.com A +short

# 公网明文 DNS（ENABLE_DNS=1）
dig @203.0.113.10 netflix.com A +short

# 公网客户端使用 DoT（ENABLE_DOT=1）
openssl s_client -connect 203.0.113.10:9853 \
  -servername dot.example.com -verify_hostname dot.example.com </dev/null
kdig @203.0.113.10 -p 9853 +tls-ca +tls-host=dot.example.com netflix.com A

# 公网客户端使用 DoH（路径固定 /dns-query；端口默认 4430）
curl -fsS --doh-url https://dot.example.com:4430/dns-query \
  https://netflix.com >/dev/null && echo doh_ok
# 或：
# kdig @203.0.113.10 -p 4430 +https +tls-ca +tls-host=dot.example.com netflix.com A
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

## 7. 域名规则（可配置日更，不是写死）

解锁机劫持列表 **不是** 编译进二进制写死的一份。运行时是：

1. 镜像内自带一份 `domains/all.txt`（构建时快照，**打底**）
2. 容器里 `scripts/domain-updater.sh` 按你配置的 **URL + 时刻** 拉取远程清单并热重载
3. 远程校验失败则 **保留当前列表**，不会清空

### 7.1 环境变量（都可以改）

| 变量 | 默认 | 含义 |
|---|---|---|
| `ENABLE_DOMAIN_AUTO_UPDATE` | `1` | `0/false` 关闭远程拉取，只用镜像内 / 已 seed 的列表 |
| `DOMAIN_LIST_URL` | 见下 | **远程清单 URL，可改成你自己的** |
| `DOMAIN_UPDATE_HOUR` | `4` | 每天几点拉（0–23，容器 `TZ`） |
| `DOMAIN_UPDATE_MINUTE` | `0` | 分钟 |
| `MIN_DOMAIN_COUNT` | `800` | 远程行数少于此则拒绝更新 |

**默认 URL**（仅默认值，可覆盖）：

```text
https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock/domains/all.txt
```

示例：关日更 / 改时刻 / 用自建列表：

```bash
# 只用镜像内列表，永不拉远程
ENABLE_DOMAIN_AUTO_UPDATE=0

# 每天 06:30（TZ=Asia/Shanghai）拉官方 raw
ENABLE_DOMAIN_AUTO_UPDATE=1
DOMAIN_UPDATE_HOUR=6
DOMAIN_UPDATE_MINUTE=30

# 拉你自己托管的清单（一行一个 FQDN）
DOMAIN_LIST_URL=https://example.com/my-unlock-domains.txt
MIN_DOMAIN_COUNT=100
```

### 7.2 容器里实际怎么更新

`scripts/domain-updater.sh`（entrypoint 会 seed → boot 拉一次 → 后台 loop）：

| 时机 | 行为 |
|---|---|
| 启动 | 若 runtime 列表空，从镜像 `domains/all.txt` **seed** |
| 启动 | `ENABLE_DOMAIN_AUTO_UPDATE=1` 时 **best-effort** 拉 `DOMAIN_LIST_URL`；失败继续用本地 |
| 每天 H:M | 再拉；有变更则写 runtime 列表并 **热重载** |
| 热重载 | 重建 sniproxy/SmartDNS 配置：SmartDNS `SIGHUP`，sniproxy 重启 |

远程列表校验（任一失败则 **不替换** 旧表）：

- 行数 ≥ `MIN_DOMAIN_COUNT`
- 不得含 Google/YouTube 族
- 须含核心域名（如 `netflix.com`、`disneyplus.com`、`bamgrid.com` 等，见脚本）

匹配语义：列表为裸 FQDN；SmartDNS `address /domain/ip` 与 sniproxy `(^|\.)domain$` 覆盖本域及子域。

### 7.3 上游「官方」清单怎么生成（仓库侧，不是容器写死）

GitHub Action `update-unlock-domains.yml`（约上海 **03:00**）在 **仓库** 里重建并 push `unlock/domains/all.txt`，供默认 `DOMAIN_LIST_URL` 使用：

1. MetaCubeX `geo/geosite`（`geosite-sources.txt`）
2. Rules Domain YAML（`rules-domain-sources.txt`）
3. `StreamConfig.yaml` + `1stream.txt` 补充
4. 去重、剔 Google/YouTube

你完全可以：**不改容器代码**，只把 `DOMAIN_LIST_URL` 指到自己的 raw/文件服务器；或 fork 后改 Action 产物 URL。

与 **unlock-center** 的关系：

| 组件 | 列表 | 日更变量 |
|---|---|---|
| 解锁机 unlock | 劫持用 `all.txt`（扁平域名） | `DOMAIN_LIST_URL` 等（本节） |
| 中心 unlock-center | 分类 `domain-region.map` | `DOMAIN_MAP_URL` 等（见 unlock-center README） |

两边默认都指向本仓库 raw，但是 **两套文件、两套 env，都可改**。

默认 `FORCE_AAAA_SOA=yes`，防止 IPv4 解锁机上客户端用 AAAA 绕过 sniproxy。来源细节见 `domains/SOURCES.md`。

---

## 8. 环境变量

| 变量 | 默认 | 作用 |
|---|---:|---|
| `UNLOCK_IP` | 自动探测 | 流媒体域名返回的解锁机 IP，生产建议显式设置 |
| `ALLOWED_IPS` | 空，拒绝启动 | DNS/DoT/DoH/SNI 访问白名单；支持任意 CIDR，包括 `0.0.0.0/0` |
| `ENABLE_ACL` | `1` | 关闭后不应用防火墙白名单，**不建议生产使用** |
| `ENABLE_DNS` | `0` | `1` 公网发布明文 DNS（`0.0.0.0:DNS_UDP_PORT`）；`0` 时仅 loopback 供健康检查 |
| `DNS_UDP_PORT` | `53` | 明文 DNS UDP/TCP 端口；Compose 始终映射，但仅 `ENABLE_DNS=1` 时对外有效 |
| `ENABLE_DOT` | `1` | `1` 启用 DoT（`bind-tls`） |
| `DOT_PORT` | `853` | DoT TCP 端口；不可为 53/80/443/DNS_UDP_PORT |
| `ENABLE_DOH` | `1` | `1` 启用 DoH（`bind-https`） |
| `DOH_PORT` | `4430` | DoH TCP 端口；不可为 53/80/443；与 DoT 同时开时不可等于 `DOT_PORT` |
| `DOT_TLS_MODE` | `letsencrypt` | `letsencrypt` / `selfsigned` / `custom`；仅 DoT/DoH 启用时生效 |
| `DOT_DOMAIN` | 无 | DoT/DoH 共用 TLS 名称/SNI；**仅 DoT 或 DoH 启用时必填** |
| `LE_EMAIL` | 无 | Let’s Encrypt 注册邮箱，`letsencrypt` + DoT/DoH 时必填 |
| `CF_DNS_API_TOKEN` | 无 | Cloudflare DNS-01 token，`letsencrypt` + DoT/DoH 时必填 |
| `WARP_ORGANIZATION` | 无 | Zero Trust team name |
| `WARP_CLIENT_ID` | 无 | Service Token Client ID |
| `WARP_CLIENT_SECRET` | 无 | Service Token Client Secret |
| `WARP_REGISTER_TIMEOUT` | `240` | MDM Service Token 注册超时秒数 |
| `WARP_CONNECT_TIMEOUT` | `120` | WARP Connected 等待秒数 |
| `ZT_RESTART_HOURS` | `12` | 整个容器/WARP 会话的定期干净重启周期 |
| `ENABLE_SOCKS5` | `0` | `1` 启用同一 Compose 中的可选 SOCKS5 服务 |
| `SOCKS5_PORT` | `1080` | SOCKS5 TCP 控制端口 |
| `SOCKS5_USERNAME` / `SOCKS5_PASSWORD` | 无 | SOCKS5 用户名/密码（RFC1929 任意 1–255 字节），启用时必填 |
| `SOCKS5_ALLOWED_IPS` | 无 | SOCKS5 独立 CIDR 白名单，启用时必填，不继承 `ALLOWED_IPS`；支持任意 CIDR |
| `FORCE_AAAA_SOA` | `yes` | IPv4 部署防止 AAAA 绕过 |
| `PLATFORMS` | `all` | StreamConfig 平台过滤（仅 streamconfig 回退路径） |
| `REGIONS` | 空 | StreamConfig 地区过滤（仅 streamconfig 回退路径） |
| `ENABLE_DOMAIN_AUTO_UPDATE` | `1` | 是否远程日更；`0` 则只用镜像内/已 seed 列表 |
| `DOMAIN_LIST_URL` | 本仓库 `.../unlock/domains/all.txt`（**默认值，可改**） | 远程域名清单 URL |
| `DOMAIN_UPDATE_HOUR` / `DOMAIN_UPDATE_MINUTE` | `4` / `0` | 每天拉取时刻（容器 `TZ`，可改） |
| `MIN_DOMAIN_COUNT` | `800` | 远程行数下限，过小拒绝更新 |

至少启用 `ENABLE_DNS` / `ENABLE_DOT` / `ENABLE_DOH` 之一。

---

## 8.1 Docker Compose 示例（解锁机）

仓库文件：[docker-compose.yml](./docker-compose.yml)（构建上下文仅 `unlock/`）。

```bash
cd unlock
cp .env.example .env
# 必填 WARP_*、UNLOCK_IP、ALLOWED_IPS；配合中心时建议 ENABLE_DNS=1 且 ACL 含中心 IP
docker compose pull
docker compose up -d
docker compose logs -f unlock
```

使用已发布镜像（compose 默认 `ghcr.io/lanlan13-14/proxym-easy-unlock:latest`）：

```bash
# 固定版本
UNLOCK_IMAGE_TAG=v1.0.8 docker compose pull
UNLOCK_IMAGE_TAG=v1.0.8 docker compose up -d
```

与 **unlock-center** 联调时的完整对照（中心 compose、nodes.toml、双端 ACL）见：  
[../unlock-center/README.md §4](../unlock-center/README.md)（端到端教程 + §4.8 Compose 可复制示例）。

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

- MetaCubeX geosite 日更域名清单 + 容器 04:00 热更新（排除 Google / YouTube）
- SmartDNS 明文 DNS / DoT / DoH 独立开关、自定义端口、纯明文无域名、证书路径、AAAA 防绕过、三关拒绝
- Let’s Encrypt DNS-01 签发/续期/SmartDNS 重载；纯 DNS 时 cert-manager 跳过
- 官方 WARP MDM Service Token、`tunnelonly`、MASQUE、Consumer 拒绝
- WARP fail-closed 启动顺序与连接标记回程（支持任意 CIDR）
- Compose 接线及 `unlock/` 构建上下文隔离
- unlock-socks5d 任意字符用户名/密码真实握手测试
