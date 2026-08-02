# Proxym-Easy DNS Unlock

一个镜像完成流媒体 DNS 解锁：

- **SmartDNS**：普通 DNS（UDP/TCP）+ **DoT**
- **sniproxy**：按 HTTP Host / TLS SNI 透明转发 80/443
- **Let's Encrypt**：通过 **Cloudflare DNS-01 API Token** 获取可信 DoT TLS 证书
- **自动续期**：`lego` 每 12 小时检查；证书更新后向 SmartDNS 发 `SIGHUP` 重新加载
- **IP/CIDR 白名单**：nftables，回退 iptables；保护 53、DoT、80、443
- **可选 Cloudflare Zero Trust Tunnel**：`cloudflared` token 模式，按周期重启

此实现参考 [lthero-big/Smartdns_sniproxy_installer](https://github.com/lthero-big/Smartdns_sniproxy_installer) 的架构：被解锁端只向解锁机查询流媒体域名；解锁机将这些域名解析为自己，再由 sniproxy 根据 SNI 转接真实流媒体源站。

> **镜像边界：** Dockerfile 只能接收 `unlock/` 作为 build context，并且仅有 `COPY . /opt/unlock/`。它不会包含 Proxym-Easy 根目录的 xray、script、Others、substore 等任何内容。根 GitHub Actions 同样固定 `context: ./unlock`。

---

## 架构

```text
被解锁机 / 路由器 / 客户端（必须在 IP 白名单中）
    │
    ├─ DoT:DOT_PORT, TLS SNI=dot.example.com ───┐
    └─ DNS:53（可选）                           │
                                                  ▼
                                            SmartDNS
                    流媒体域名 A/AAAA = UNLOCK_IP │ 非流媒体 = UPSTREAM_DNS
                                                  ▼
客户端仍按默认端口访问 netflix.com:443 ───────► sniproxy:443 ─► 真正源站
客户端仍按默认端口访问 HTTP:80 ────────────────► sniproxy:80  ─► 真正源站
```

### 重要：为什么只有 DoT 端口能自定义

**`DOT_PORT` 可以任意改**，例如 `9853`。客户端的 DoT 配置同时必须填：

- Server IP：解锁机 IP
- Port：`9853`
- Server name / SNI：证书域名，例如 `dot.example.com`

但透明 DNS 解锁中的 **HTTP 必须是 80、HTTPS 必须是 443**。DNS 只能替换目标 IP，不能让 Netflix、Disney+ 等客户端把 `:443` 改成自定义端口；所以 sniproxy 与宿主机映射固定为 `80:80`、`443:443`。这是协议限制，不是实现偷懒。

---

## 1. 前置条件

1. 一台具备目标区域出口的解锁 VPS，拥有公网 IPv4/IPv6。
2. 一个托管在 Cloudflare 的 DNS zone，例如 `example.com`。
3. 一个专用于 DoT 的公网名称，例如 `dot.example.com`。
4. `dot.example.com` 建 A/AAAA 记录指向 `UNLOCK_IP`，并设为 **DNS only（灰云）**。Cloudflare 橙云不代理通用 DoT TCP 端口。
5. Docker Compose v2。
6. 解锁机的 80/443 不被 Nginx、Caddy、Xray 等其它服务占用。

DNS-01 签证本身不依赖 80/443；即使 DoT 使用自定义端口也能签发。

---

## 2. 创建最小权限 Cloudflare DNS API Token

Cloudflare Dashboard → **My Profile → API Tokens → Create Token → Create Custom Token**：

| 项目 | 值 |
|---|---|
| Permission 1 | `Zone` → `Zone` → `Read` |
| Permission 2 | `Zone` → `DNS` → `Edit` |
| Zone Resources | `Include` → `Specific zone` → `dot.example.com` 所在 zone |

复制 token。它只在签发/续期时用于创建、删除 `_acme-challenge.dot.example.com` TXT 记录。

- token 只放在运行环境 `.env`。
- **不能**写入 Dockerfile、Git、镜像、Actions 日志或截图。
- 详细最小权限说明在 [`config/cloudflare-dns-token-permissions.md`](config/cloudflare-dns-token-permissions.md)。

---

## 3. 部署

### 3.1 创建配置

```bash
cd Proxym-Easy/unlock
cp .env.example .env
chmod 600 .env
```

编辑 `.env` 的最小生产配置：

```env
# 解锁 VPS 的真实公网 IP；不要依赖 NAT 环境的自动探测
UNLOCK_IP=203.0.113.10

# 只有这些被解锁机/客户端可访问 DNS、DoT、80、443
ALLOWED_IPS=198.51.100.8/32,198.51.100.0/24
ENABLE_ACL=1

# DNS/DoT
DNS_UDP_PORT=53
DOT_PORT=9853
DOT_DOMAIN=dot.example.com

# Let's Encrypt DNS-01
DOT_TLS_MODE=letsencrypt
LE_EMAIL=admin@example.com
CF_DNS_API_TOKEN=替换为刚创建的token
RENEW_CHECK_HOURS=12
RENEW_BEFORE_DAYS=30

# 可选：只启用特定平台，减少映射域名范围
# PLATFORMS=Netflix,DisneyPlus,YouTube
PLATFORMS=all
```

`ALLOWED_IPS` 不可为空（`ENABLE_ACL=1` 是默认值）。空白名单会使容器拒绝启动，而不是悄悄把 DNS/443 变成公网开放代理。

默认 `FORCE_AAAA_SOA=yes`：解锁机一般只有 IPv4，返回 AAAA 会让 IPv6 客户端直接连真实流媒体 IP、绕过 sniproxy，从而导致解锁失效。只有你明确为解锁机和 sniproxy 配好了公网 IPv6 时，才改成 `no`。

### 3.2 运行

```bash
docker compose up -d --build
docker compose logs -f unlock
```

首次启动顺序：

1. `lego` 用 Cloudflare DNS-01 创建 `_acme-challenge` TXT、获得 Let's Encrypt 证书。
2. SmartDNS 以该证书启动 DoT。
3. sniproxy 启动 80/443。
4. ACL 生效。
5. 证书守护进程启动；之后每 `RENEW_CHECK_HOURS` 检查一次，剩余不足 `RENEW_BEFORE_DAYS` 才续期。

正常日志应包含：

```text
[cert-manager] requesting certificate using Cloudflare DNS-01
[entrypoint] starting smartdns
[entrypoint] ready
```

### 3.3 使用已发布镜像

GitHub Actions 生成 GHCR 镜像后，在 `docker-compose.yml` 中把 `build:` 改为：

```yaml
image: ghcr.io/lanlan13-14/proxym-easy-unlock:latest
```

仍保留同一份 `.env` 和 `/etc/unlock` volume。不要把 `.env` 随镜像发布。

---

## 4. 验证

以下命令在白名单 IP 的主机上执行。

```bash
# 普通 DNS：流媒体域名应返回 UNLOCK_IP
dig @203.0.113.10 netflix.com A +short

# 检查正式 Let's Encrypt 证书与 SNI；把 9853/域名替换为实际值
openssl s_client \
  -connect 203.0.113.10:9853 \
  -servername dot.example.com \
  -verify_hostname dot.example.com </dev/null

# 推荐 kdig 做真实 DoT 查询
kdig @203.0.113.10 -p 9853 +tls-ca +tls-host=dot.example.com netflix.com A

# 容器状态 / 证书到期日
docker compose ps
docker compose exec unlock openssl x509 -in \
  /etc/unlock/letsencrypt/certificates/dot.example.com.crt -noout -issuer -subject -dates
```

验证失败时按顺序检查：

```bash
docker compose logs --tail=200 unlock
docker compose exec unlock sh -c 'cat /etc/unlock/smartdns.conf; tail -n 100 /run/unlock/smartdns.log'
docker compose exec unlock sh -c 'tail -n 100 /run/unlock/cert-manager.log'
```

---

## 5. 被解锁机 SmartDNS 分流示例

见 [`config/client-smartdns.example.conf`](config/client-smartdns.example.conf)。关键是：

```conf
server-tls 203.0.113.10:9853 \
  -group unlock -exclude-default-group \
  -host-name dot.example.com \
  -tls-host-verify dot.example.com

nameserver /netflix.com/unlock
nameserver /nflxvideo.net/unlock
```

这会使 **Netflix 域名** 通过可信 DoT 问解锁机；其它域名继续使用被解锁机自己的默认 DNS。

---

## 6. Cloudflare Zero Trust Tunnel（可选）

这部分使用的是 **cloudflared Tunnel**，不是容易在 Docker 中翻车的 WARP Client/Connector 注册：

1. Zero Trust → **网络 → 隧道** → 创建 Cloudflared tunnel。
2. 复制 tunnel token。
3. `.env` 填：

   ```env
   CF_TUNNEL_TOKEN=eyJ...
   ENABLE_ZT=auto
   ZT_RESTART_HOURS=12
   ```

4. `restart-zt.sh` 启动 `cloudflared tunnel run --token ...`，每 `ZT_RESTART_HOURS` 主动重启一次。

不要把 DNS/DoT 公开 hostname 无限制暴露；本方案对外服务的主防护仍是 `ALLOWED_IPS`。Tunnel 的私网路由/Access 策略在 Cloudflare 控制台配置。

---

## 环境变量

| 变量 | 默认 | 作用 |
|---|---:|---|
| `UNLOCK_IP` | 自动探测 | 流媒体域名返回的解锁机 IP；生产应显式设置 |
| `ALLOWED_IPS` | 空（拒绝启动） | 客户端 IPv4/IPv6 或 CIDR，逗号分隔 |
| `ENABLE_ACL` | `1` | `1` 强制 nftables/iptables 白名单；`0` 明确关闭 |
| `DNS_UDP_PORT` | `53` | 普通 DNS UDP/TCP 端口 |
| `DOT_PORT` | `853` | **可自定义** DoT TLS 端口 |
| `DOT_DOMAIN` | 无 | Let's Encrypt 证书 SAN、客户端 DoT SNI/验证名 |
| `DOT_TLS_MODE` | `letsencrypt` | `letsencrypt`（生产）/ `custom` / `selfsigned`（仅测试） |
| `LE_EMAIL` | 无 | ACME 注册/恢复邮箱 |
| `CF_DNS_API_TOKEN` | 无 | Cloudflare DNS-01 API token |
| `RENEW_CHECK_HOURS` | `12` | 检查续期的间隔 |
| `RENEW_BEFORE_DAYS` | `30` | 剩余天数不高于该值时续期 |
| `UPSTREAM_DNS` | `1.1.1.1,1.0.0.1,8.8.8.8` | 非流媒体域名上游 DNS |
| `FORCE_AAAA_SOA` | `yes` | IPv4 解锁机默认阻止 AAAA 直连绕过；双栈完整部署时才设 `no` |
| `PLATFORMS` | `all` | `StreamConfig.yaml` 平台 key，逗号分隔 |
| `REGIONS` | 空 | `StreamConfig.yaml` 地区 key，逗号分隔 |
| `CF_TUNNEL_TOKEN` | 空 | 可选 cloudflared Tunnel token |
| `ENABLE_ZT` | `auto` | `auto` / `true` / `false` |
| `ZT_RESTART_HOURS` | `12` | cloudflared 周期重启时间 |

### 自带证书（不走 Let's Encrypt）

只有在你已有可信证书时使用：

```env
DOT_TLS_MODE=custom
DOT_DOMAIN=dot.example.com
TLS_CERT=/etc/unlock/tls/fullchain.pem
TLS_KEY=/etc/unlock/tls/privkey.pem
```

需把证书通过额外 compose volume 挂载到上述路径。`selfsigned` 只用于本地测试，公网客户端会报不受信任，不能作为正式 DoT 交付。

---

## GitHub Actions / 镜像边界

根工作流：`.github/workflows/build-unlock-image.yml`。

[KNOWN] 它**只允许手动触发**，不会在 push / PR 时自动构建或推送镜像。Actions → `publish-unlock-image` → **Run workflow**，输入必填版本号，例如 `v1.0.0`、`1.2.3` 或 `v1.2.0-rc.1`。

一次手动发布会推送两个 GHCR tag：

```text
ghcr.io/lanlan13-14/proxym-easy-unlock:<你输入的版本>
ghcr.io/lanlan13-14/proxym-easy-unlock:latest
```

工作流先在 GitHub runner 中做路径自适应测试，再构建多架构镜像：

```yaml
context: ./unlock
file: ./unlock/Dockerfile
platforms: linux/amd64,linux/arm64
```

Dockerfile 内：

```dockerfile
WORKDIR /opt/unlock
COPY . /opt/unlock/
```

因此 build context 与容器文件集合都严格限制为 `unlock/`。

---

## 测试

```bash
cd unlock
sh tests/run.sh
```

覆盖：shell 语法、522 域名生成、SmartDNS DoT 证书路径、DoT 自定义端口、透明 80/443、Docker context 隔离、ACME 环境接线。

---

## 目录

```text
unlock/
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .dockerignore
├── StreamConfig.yaml
├── domains/all.txt
├── config/
│   ├── cloudflare-dns-token-permissions.md
│   ├── client-smartdns.example.conf
│   ├── smartdns.conf.template
│   └── sniproxy.conf.template
├── scripts/
│   ├── cert-manager.sh       # DNS-01 issue + renew + SmartDNS reload
│   ├── gen-configs.sh
│   ├── apply-acl.sh
│   ├── restart-zt.sh
│   └── entrypoint.sh
└── tests/run.sh
```
