# unlock-center

**DNS 解锁控制面**（Rust）：客户端只连这一台中心的 **明文 DNS / DoT / DoH**，中心按「域名分类 + 路径指定区域 + 客户端 GeoIP」决定返回哪台区域解锁机的 IP；视频流量与 sniproxy / WARP **不经过中心**，仍由各区域 [unlock](../unlock/) 镜像处理。

| 组件 | 职责 |
|---|---|
| **unlock-center（本目录）** | 聪明 DNS：匹配域名、选区、选节点、非解锁就近代查 |
| **unlock（兄弟目录）** | 傻数据面：SmartDNS + sniproxy + 区出口 WARP，**保持原样** |

设计规格全文：[DEVELOPMENT.md](./DEVELOPMENT.md)

---

## 1. 它解决什么问题

单台解锁机只能固定一个出口区。多台解锁机（美/日/港/英…）时需要：

1. **一个入口**给客户端（不要每个 App 配一堆 DoH）
2. **区锁内容**（DMM、BBC、myTV 等）自动进对应区的机
3. **全局流媒体**（Netflix 等）由用户/路径钉死出口区，**不要**用客户端 IP 库瞎猜导致区漂
4. **AI** 默认跟全局区，也可路径单独指定
5. **普通网站**不要解析成解锁机 IP，而是真实 CDN；DNS 代查尽量走离用户近的解锁机

`unlock-center` 就是做上面这些的控制面。

---

## 2. 架构（一眼看懂）

```text
手机 / 路由 / Clash
        │  唯一 DoH/DoT/53
        ▼
┌───────────────────┐
│  unlock-center    │  无 sniproxy / 无 WARP
│  三端口 DNS 入口   │
│  域名表 + 选节点   │
└─────────┬─────────┘
          │
   ┌──────┼──────────────┐
   ▼      ▼              ▼
unlock-us  unlock-jp  unlock-hk / uk …
(WARP US)  (WARP JP)  (区出口)
   │
   └─ 客户端 80/443 直连被返回的那台机（sniproxy）
```

**决策顺序（核心）：**

| 域名类型 | 如何定区 | 返回什么 |
|---|---|---|
| **regional**（区锁） | `domain-region.map` 强制区；path/Geo **不能改** | 该区 `unlock_ip` |
| **global**（全球向流媒体） | DoH path 或 `DEFAULT_GLOBAL_REGION` | 该区 `unlock_ip` |
| **ai** | path 的 AI 区，否则跟随 global | 该区 `unlock_ip` |
| **other**（不在表内） | 客户端 IP → GeoIP 经纬度 → **最近**解锁机 DNS 代查 | **真实** A/AAAA（不是 unlock IP） |

`UNLOCK_SCOPE` 可限制只解锁全局、只解锁区域、或两者都开。

---

## 3. 功能清单

- 明文 DNS / DoT / DoH **独立开关**，各最多一个端口
- DoH **可自定义路径**（伪装，不限于 `/dns-query`）
- 路径指定全局区 / AI 区：`/us`、`/us/ai/jp`、`/ai/jp`
- 域名分类：`global` / `regional` / `ai`（日更 map）
- **可自定义区域**（如 `uk`）：节点 + map + `allow_regions`
- GeoIP City MMDB：**内置默认下载 URL**，可自定义日更时刻
- TLS：自签 或 **Let’s Encrypt + Cloudflare DNS-01 only**（与 unlock 同思路）
- 域名表定时拉取热更新；GeoIP `SIGUSR1` 热加载
- 无 sniproxy、无 TUN、无 WARP

---

## 4. 生产部署（Docker，推荐）

### 4.1 镜像

```text
ghcr.io/lanlan13-14/proxym-easy-unlock-center:latest
ghcr.io/lanlan13-14/proxym-easy-unlock-center:<version>
```

手动发布（Actions → **publish-unlock-center-image**）：

- 仅 `workflow_dispatch`
- 输入 `version`（**默认 `v1.0.0`**）
- **每次同时推送** `<version>` 与 `latest`

### 4.2 前置条件

1. 至少一台区域 [unlock](../unlock/) 已跑通（WARP、ACL、公网 IP 可用）
2. 若启用 DoT/DoH + Let’s Encrypt：域名 DNS 在 Cloudflare，Token 具备 **Zone:Read + DNS:Edit**（建议限制到该 Zone）
3. 域名 A/AAAA 指向中心机（DoH/DoT 用）

### 4.3 一键 Compose

在 `unlock-center/` 目录：

```bash
cp .env.example .env
cp nodes.example.toml nodes.toml

# 必改：nodes.toml 里每台 unlock 的公网 IP
# 必改：.env 里 CENTER_DOT_DOMAIN / LE_EMAIL / CF_DNS_API_TOKEN（若用 LE）
# 可选：DEFAULT_GLOBAL_REGION、DOH_BASE_PATH、GEOIP_* 时间

docker compose up -d
docker compose logs -f
```

`docker-compose.yml` 默认映射：

| 宿主机 | 容器 | 用途 |
|---|---|---|
| 53/udp+tcp | 53 | 明文 DNS（默认关，见 `.env`） |
| 853/tcp | 853 | DoT |
| 443/tcp | 443 | DoH |

数据卷 `center-data`：证书、`/data/geoip` MMDB。

### 4.4 节点文件 `nodes.toml`（必填真实 IP）

```toml
[[nodes]]
id = "us-1"
region = "us"                 # 与 map / path 使用的区名一致
unlock_ip = "你的美区解锁机公网IP"   # 返回给客户端的 A 记录
dns_upstream = "你的美区解锁机IP:53" # 非解锁代查用（可与 unlock_ip 同机）
weight = 10
lat = 37.77                   # 建议填；GeoIP nearest 用
lon = -122.42

[[nodes]]
id = "jp-1"
region = "jp"
unlock_ip = "x.x.x.x"
dns_upstream = "x.x.x.x:53"
weight = 10
lat = 35.68
lon = 139.69
```

说明：

- `region` 可自定义：`uk`、`sg`、`foo` 均可，只要 map / `allow_regions` / 节点三处一致
- 中心访问各机 `dns_upstream` 时，解锁机 ACL 需放行 **中心出口 IP**
- 客户端访问 `unlock_ip:80/443` 时，解锁机 ACL 需放行 **客户端网段**（或按你现有 unlock 策略）

### 4.5 环境变量（`.env`）要点

```bash
# 监听
CENTER_ENABLE_DNS=0
CENTER_ENABLE_DOT=1
CENTER_ENABLE_DOH=1
DOH_PORT=443
DOH_BASE_PATH=/api/v2/weather    # 可改成任意伪装路径

# 策略
UNLOCK_SCOPE=all                 # global | regional | all
DEFAULT_GLOBAL_REGION=us         # path 未指定时全局/AI 默认区
DEFAULT_AI_REGION=               # 空 = AI 跟随全局
DOMAIN_MAP_URL=https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock-center/domains/domain-region.map

# 证书（DoT/DoH）
CENTER_TLS_MODE=letsencrypt      # 或 selfsigned / files
CENTER_DOT_DOMAIN=dns.example.com
LE_EMAIL=admin@example.com
CF_DNS_API_TOKEN=...

# GeoIP（内置默认 URL，可不改）
GEOIP_ENABLE_AUTO_UPDATE=1
GEOIP_UPDATE_HOUR=4
GEOIP_UPDATE_MINUTE=0
GEOIP_DB_URL=https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb
```

完整列表见 [.env.example](./.env.example)。

### 4.6 客户端怎么配

**DoH（推荐）**

```text
# 默认全局区 = DEFAULT_GLOBAL_REGION（如 us）
https://dns.example.com/api/v2/weather

# 全局强制美区
https://dns.example.com/api/v2/weather/us

# 全局美区 + AI 走日本
https://dns.example.com/api/v2/weather/us/ai/jp

# 仅钉 AI 区，全局仍用默认
https://dns.example.com/api/v2/weather/ai/jp
```

把上面的 `dns.example.com` 换成你的 `CENTER_DOT_DOMAIN`，路径换成你的 `DOH_BASE_PATH`。

**DoT**

```text
主机: dns.example.com
端口: 853
# MVP：DoT 使用默认 profile（DEFAULT_GLOBAL_REGION），区锁域名仍按 map
```

**明文 DNS**

```bash
# 需 CENTER_ENABLE_DNS=1
dig @中心IP netflix.com +short
# → 美区 unlock 公网 IP（若 default_global=us）

dig @中心IP dmm.co.jp +short
# → 日区 unlock 公网 IP
```

### 4.7 自检

```bash
# 区锁 → 应对应区 IP
dig @中心 dmm.co.jp +short          # jp 节点
dig @中心 bbc.co.uk +short          # uk 节点（map 有则）

# 全局 → 默认全局区 IP
dig @中心 netflix.com +short

# 普通域名 → 不应是 unlock 文档里的假 IP，而是真实解析
dig @中心 example.com +short

# DoH（LE 证书用系统信任；自签加 -k）
curl -H 'content-type: application/dns-message' \
  --data-binary @query.bin \
  "https://dns.example.com/api/v2/weather/us"
```

---

## 5. 本地开发（Cargo）

依赖：Rust **stable ≥ 1.85**（推荐 rustup，勿用过旧系统 rustc）。

```bash
cd unlock-center

# 分类域名表（可从 1-stream + Rules 生成）
sh scripts/build-domain-map.sh

cp nodes.example.toml nodes.toml
cp config.example.toml config.toml
# 开发建议：config 里只开 enable_dns、端口 5353，tls 用 selfsigned

cargo test --workspace
cargo run -p unlock-center --release -- -c config.toml

dig @127.0.0.1 -p 5353 netflix.com +short
dig @127.0.0.1 -p 5353 dmm.co.jp +short
```

配置项说明见 [config.example.toml](./config.example.toml)。

---

## 6. DoH 路径规则（伪装 + 定区）

设 `doh_base_path = "/api/v2/weather"`（可任意改）：

| 请求路径 | 含义 |
|---|---|
| `{base}` | global = 默认区，AI 跟随 global |
| `{base}/{g}` | global = `g`（须在 `allow_regions`），AI 跟随 |
| `{base}/ai/{a}` | global = 默认，AI = `a` |
| `{base}/{g}/ai/{a}` | global = `g`，AI = `a` |
| 其它路径 | **HTTP 404**（不像 DNS，利于伪装） |

**注意：**

- 路径只影响 **global / ai**
- **regional 域名永远跟 map**，即使用 `/us` 查 `dmm.co.jp` 仍回日本机
- 自定义 path **不能代替** IP 白名单 / Token；生产仍建议 ACL

---

## 7. 域名分类与日更

### 7.1 发布文件（GitHub 固定路径）

| 文件 | 用途 |
|---|---|
| [domains/domain-region.map](domains/domain-region.map) | **中心主表**：`域名\\tclass\\tregion` |
| [domains/global.txt](domains/global.txt) | 仅 global |
| [domains/regional.txt](domains/regional.txt) | 仅 regional |
| [domains/ai.txt](domains/ai.txt) | 仅 ai |

固定 raw：

```text
https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock-center/domains/domain-region.map
```

map 行格式：

```text
netflix.com	global	-
dmm.co.jp	regional	jp
bbc.co.uk	regional	uk
openai.com	ai	-
```

### 7.2 如何生成

```bash
sh scripts/build-domain-map.sh
```

来源：

1. [1-stream stream.smartdns.list](https://github.com/1-stream/1stream-public-utils/blob/main/stream.smartdns.list) 段标题 → global / 各国 regional / ai  
2. [Lanlan13-14/Rules](https://github.com/Lanlan13-14/Rules) Domain：`streaming_hk/sg/tw/uk`、`tvb`  
3. 剔除 Google / YouTube 族  

仓库 Action **`update-unlock-domains`**（每天约上海 03:00）会重建 unlock 的 `all.txt` **以及** 本目录分类 map。

中心运行时按 `DOMAIN_MAP_URL` / 本地文件定时刷新（默认 3600s）。

### 7.3 UNLOCK_SCOPE

| 值 | 行为 |
|---|---|
| `all` | global + regional + ai 都劫持（默认） |
| `global` | 只劫持 global（+ 可选 ai）；区锁域名当普通站 |
| `regional` | 只劫持 regional；Netflix 等不解锁 |

---

## 8. 添加新区（以 UK 为例）

1. 部署一台英区 **unlock**（WARP/出口按英国）  
2. `nodes.toml` 增加：

   ```toml
   [[nodes]]
   id = "uk-1"
   region = "uk"
   unlock_ip = "英区公网IP"
   dns_upstream = "英区公网IP:53"
   lat = 51.51
   lon = -0.13
   ```

3. 配置 `allow_regions` 含 `"uk"`（示例配置已含）  
4. map 中英区域名：`regional` + `uk`（日更脚本已从 `streaming_uk` 等生成；可手改 map）  
5. 客户端若希望 **全局流媒体** 也走英区：DoH 使用 `.../uk`  
6. 重载/重启 center

任意新区同理：`region` 字符串自定，三处对齐即可。

---

## 9. GeoIP（内置下载，可改时间）

用途：**仅**非解锁 passthrough 选「最近解锁机」；**不**用 GeoIP 决定 Netflix/AI 解锁区。

| 项 | 默认 |
|---|---|
| 下载 URL | `https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb`（**内置，无需 key**） |
| 本地路径 | `/data/geoip/GeoLite2-City.mmdb` |
| 日更 | 开启；`GEOIP_UPDATE_HOUR=4` `GEOIP_UPDATE_MINUTE=0`（容器 `TZ`） |
| 热加载 | 更新后 `SIGUSR1` |

可选：设置 `MAXMIND_LICENSE_KEY` 改走官方 GeoLite2；或改 `GEOIP_DB_URL` 用自有镜像。

脚本：`scripts/geoip-updater.sh`（entrypoint 会 boot 拉一次 + 后台 loop）。

---

## 10. TLS 证书

| `CENTER_TLS_MODE` / `tls.mode` | 说明 |
|---|---|
| `letsencrypt` | lego + **仅 Cloudflare DNS-01**（`CF_DNS_API_TOKEN`） |
| `selfsigned` | 测试用 |
| `files` | 自备 cert/key 路径 |

- 仅明文 DNS：可 `CENTER_ENABLE_DOT=0` `CENTER_ENABLE_DOH=0`，**不需要**域名和证书  
- 脚本：`scripts/cert-manager.sh`（ensure + renew-loop）  
- 续期成功：`SIGHUP` 通知中心（当前实现优先重载 GeoIP；完整 TLS 热替换以容器重启/后续增强为准，证书文件路径不变时多数场景续期后新连接可读新文件）

---

## 11. 与 unlock 数据面如何配合

| 项目 | unlock-center | unlock |
|---|---|---|
| 镜像 | `proxym-easy-unlock-center` | `proxym-easy-unlock` |
| 域名表 | `domain-region.map`（分类） | `domains/all.txt`（劫持列表） |
| 出站 | 无 | WARP 强制 |
| 客户端 80/443 | 不终结 | sniproxy |
| 中心查 53 | 作 passthrough 上游 | 需对中心 IP 放行 |

建议：每个 `region` 至少一台 unlock；中心 `nodes.toml` 的 `unlock_ip` 必须是客户端能直连的公网地址。

---

## 12. 目录结构

```text
unlock-center/
├── README.md                 # 本文
├── DEVELOPMENT.md            # 开发规格
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── config.example.toml
├── nodes.example.toml
├── scripts/
│   ├── entrypoint.sh         # 容器入口
│   ├── cert-manager.sh       # LE + CF DNS-01
│   ├── geoip-updater.sh      # MMDB 日更（内置 URL）
│   └── build-domain-map.sh   # 分类域名构建
├── domains/                  # 已发布的分类列表
└── crates/
    ├── domain-index/         # 最长后缀匹配
    ├── schedule/             # 节点 / nearest
    └── unlock-center/        # 主程序
```

---

## 13. 常见问题

**Q: 中心和 unlock 装同一台可以吗？**  
可以，但区出口仍是该机 WARP 区；多区仍要多机或多出口。中心进程本身不跑 WARP。

**Q: 为什么 DMM 走了日本，Netflix 却是美国？**  
DMM 是 regional→jp；Netflix 是 global→path/默认全局区。这是预期行为。

**Q: 想全家默认日区 Netflix？**  
`DEFAULT_GLOBAL_REGION=jp`，或客户端 DoH 固定 `.../jp`。

**Q: 非解锁网站很慢？**  
DNS 会先到中心再代查；中心与用户的 RTT 占大头。可接受则保持单中心；要更低延迟需多中心 GeoDNS（非本 MVP）。

**Q: 解锁机 53 不给公网开？**  
给中心单独 ACL，或把 `dns_upstream` 改成内网 IP；`unlock_ip` 仍须是客户端可达的公网地址。

**Q: 如何只开区锁、不动 Netflix？**  
`UNLOCK_SCOPE=regional`。

**Q: path 能改成任意字符串吗？**  
能。`DOH_BASE_PATH` / `doh_base_path` 任意以 `/` 开头的路径即可。

---

## 14. 相关链接

- 解锁机文档：[../unlock/README.md](../unlock/README.md)  
- 开发规格：[DEVELOPMENT.md](./DEVELOPMENT.md)  
- 域名来源说明：[domains/SOURCES.md](domains/SOURCES.md)  
- 日更域名 Action：`.github/workflows/update-unlock-domains.yml`  
- 发布镜像 Action：`.github/workflows/build-unlock-center-image.yml`  
