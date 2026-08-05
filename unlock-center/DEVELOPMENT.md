# unlock-center 开发文档（Rust）

> 状态：**MVP 已实现**（三端口 + 匹配调度 + 分类域名日更；GeoIP/镜像后续增强）  
> 角色：DNS 解锁 **控制面（中心调度）**  
> 语言：Rust  
> 配对组件：`unlock/` 区域解锁机（SmartDNS + sniproxy + WARP，**保持现状不改双 DNS**）  
> 文档版本：2026-08-04

本文是 **实现规格 + 架构说明**，不是营销文。实现时以本文为准；若与口头讨论冲突，以仓库最新版本文档为准。

---

## 0. 一句话

**一台中心只做三端口 DNS 入口（明文 / DoT / DoH）+ 内存域名匹配 + 选解锁机 / 代查；视频与 sniproxy 全部在区域解锁机上。**

```text
客户端 ── DNS|DoT|DoH ──► unlock-center（Rust，瘦控制面）
                              │
              解锁命中 ─────────┼──► 返回某台 unlock 的公网 A/AAAA
              非解锁 ───────────┼──► 问「最近」unlock 的 DNS，返回真实解析
                              ▼
                    unlock-us / unlock-jp / unlock-hk …
                    （现状镜像：SmartDNS + sniproxy + 区 WARP）
```

---

## 1. 目标与非目标

### 1.1 目标

| ID | 目标 |
|---|---|
| G1 | 单一入口：明文 DNS、DoT、DoH **各自最多一个端口**，独立开关 |
| G2 | DoT/DoH 证书：`selfsigned` 或 **Let’s Encrypt + Cloudflare DNS-01 only**（与 unlock 同思路） |
| G3 | DoH **可自定义路径**（伪装，不限于 `/dns-query`） |
| G4 | 域名分类：`global` / `regional` / `ai` / `other`（主源 1-stream 段头 + 日更表） |
| G5 | `UNLOCK_SCOPE`：`global` \| `regional` \| `all` |
| G6 | 区域限定：域名强制区，**path/Geo 不可覆盖** |
| G7 | 全局内容：由 DoH path（及等价 profile）指定区，**默认不用 IP 库定区** |
| G8 | AI：默认跟随全局区；path 可单独指定 AI 区 |
| G9 | 非解锁：按客户端 IP 选 **最近解锁机** 代查，返回 **真实 A/AAAA**（不是 unlock IP） |
| G10 | 热路径高并发：域名匹配 **纯内存**、规则表 **atomic 热更新**、非解锁 **缓存** |
| G11 | 解锁机保持现状：不要求双 DNS、不改 SmartDNS 源码 |

### 1.2 非目标（明确不做）

| ID | 非目标 |
|---|---|
| N1 | 中心跑 sniproxy / 转发 80/443 视频 |
| N2 | 中心跑 WARP / 伪装流媒体出站 |
| N3 | Fork / 魔改 SmartDNS 当中心 |
| N4 | 自建 Anycast BGP（可选远期，非 MVP） |
| N5 | 以 ECS 为架构前提（可选增强，1.1.1.1 不做 ECS） |
| N6 | 中心提供 SOCKS5 |
| N7 | 用 GeoIP 决定 Netflix/AI 解锁区（易漂移；仅用于 nearest 代查） |

---

## 2. 术语

| 术语 | 含义 |
|---|---|
| **Center / unlock-center** | 本项目：调度 DNS 服务 |
| **Unlock node** | 区域解锁机实例（现有 `proxym-easy-unlock` 镜像） |
| **Pool / region** | 逻辑区：`us` `jp` `hk` `sg` `tw` `uk` `kr` … |
| **Profile** | 一次查询的策略上下文：`global_region` + `ai_region`（来自 path/SNI/默认） |
| **class** | 域名类：`global` \| `regional` \| `ai` \| `other` |
| **Passthrough** | 非解锁：向某 unlock 的 DNS 发查询，拿真实 RRset |
| **Domain map** | 预构建的 `domain → (class, region?)` 表，加载为后缀索引 |

---

## 3. 系统架构

### 3.1 逻辑架构

```text
                    ┌─────────────────────────────────────┐
                    │           unlock-center             │
                    │  ┌─────────┐ ┌─────────┐ ┌───────┐  │
  Client ───────────┼─►│ DNS :53 │ │ DoT:853 │ │DoH:443│  │
                    │  └────┬────┘ └────┬────┘ └───┬───┘  │
                    │       └───────────┼──────────┘      │
                    │                   ▼                 │
                    │         resolve(qname, client, profile)
                    │                   │                 │
                    │     ┌─────────────┼─────────────┐   │
                    │     ▼             ▼             ▼   │
                    │  DomainIndex   Scheduler    Cache   │
                    │  (suffix)      (nodes)      (RR)    │
                    │     │             │             │   │
                    └─────┼─────────────┼─────────────┼───┘
                          │             │             │
              domain-region.map    nodes.yaml    passthrough
                          │             │             │
                          │             ▼             ▼
                          │      unlock-us/jp/hk   UDP/DoH DNS
                          │      (公网 IP)         on unlock
                          └─────────────────────────────
```

### 3.2 部署拓扑（推荐）

```text
[用户设备]
   │ DoH/DoT/53 → center.example.com
   ▼
[unlock-center ×1]     ← 先单实例；无状态后可多副本+LB
   │
   ├─ 应答 A = unlock 公网 IP  ──► 用户直连该 IP:80/443 (sniproxy)
   └─ 代查 ──────────────────► unlock:53 (或约定端口) → 1.1.1.1 等（走解锁机现网）

[unlock-us] [unlock-jp] [unlock-hk] …
   各区 WARP 出口固定；镜像与现网一致
```

### 3.3 信任边界

| 边界 | 说明 |
|---|---|
| 用户 → Center | TLS（DoT/DoH）；可选 IP 白名单 / Bearer |
| Center → Unlock DNS | 内网或公网；应用层超时；可选共享密钥 |
| 用户 → Unlock 80/443 | 与现 unlock ACL 策略一致（全球用户时需放宽或改认证） |
| Center → 域名表 URL | HTTPS 拉取日更；校验最小条数 |

---

## 4. 协议面

### 4.1 总开关

与 unlock 风格对齐：

```text
ENABLE_DNS=0|1     # 明文
ENABLE_DOT=0|1
ENABLE_DOH=0|1
# 至少开启一个；全关启动失败
```

### 4.2 明文 DNS

- 默认端口：`DNS_UDP_PORT=53`（可改）
- 协议：UDP + TCP（截断/大响应）
- Profile：无 path → 使用 `DEFAULT_GLOBAL_REGION` / `DEFAULT_AI_REGION`
- 可选：按 **源端口映射 profile**（MVP 可不做）
- 可选：按 **查询附带的 ECS** 作 client_ip 提示（MVP 可忽略 ECS）

### 4.3 DoT

- 默认端口：`DOT_PORT=853`
- TLS 1.2+；SNI 期望为 `DOT_DOMAIN`（或允许列表）
- Profile 解析优先级：
  1. 若启用 **SNI 分区**（可选）：`us.dns.example.com` → global=us  
  2. 否则默认 profile
- 证书：与 DoH 共用同一套 cert/key 文件（同 unlock）

### 4.4 DoH

- 默认端口：`DOH_PORT=443`（也可用 4430 等）
- RFC 8484：
  - `POST` `application/dns-message`
  - `GET` `?dns=` base64url(dns wire)
- **路径可配置**，见 §5
- HTTP/2 优先；HTTP/1.1 可作兼容
- 响应：`application/dns-message`，合适的 `Cache-Control`（短 TTL）

### 4.5 查询类型

| qtype | MVP 行为 |
|---|---|
| A | 完整逻辑 |
| AAAA | 可配置：`AAAA_MODE=passthrough\|empty\|soa`（解锁场景常 empty/soa 防 v6 绕过；与 unlock `FORCE_AAAA_SOA` 哲学一致） |
| 其它 | `NOERROR` 空应答 或 转发 passthrough（配置项 `OTHER_QTYPE_MODE`） |

**MVP 建议：**

```text
A        → 调度逻辑
AAAA     → 解锁命中时 NOERROR 空 或 SOA；非解锁 passthrough
其它     → REFUSED 或 passthrough（默认 REFUSED 减负载）
```

---

## 5. DoH 路径与 Profile（伪装 + 定区）

### 5.1 配置

```toml
doh_base_path = "/api/v2/weather"   # 可任意，不要用显而易见的 /dns-query 亦可
doh_extra_paths = []                # 可选兼容，如 ["/dns-query"]
```

### 5.2 路由规则（启动时编译成静态匹配，热路径勿用复杂正则）

设 `base = doh_base_path`（规范化：无尾 `/`，必须以 `/` 开头）。

| 请求 path | Profile |
|---|---|
| `{base}` | `global=DEFAULT_GLOBAL_REGION`, `ai=follow_global` |
| `{base}/{g}` 且 `g ∈ allow_regions` | `global=g`, `ai=follow_global` |
| `{base}/{g}/ai/{a}` 且均合法 | `global=g`, `ai=a` |
| `{base}/ai/{a}` | `global=DEFAULT`, `ai=a` |
| 其它 | **HTTP 404**（不要返回 DNS 错误，利于伪装） |

示例：

```text
https://dns.example.com/api/v2/weather
https://dns.example.com/api/v2/weather/us
https://dns.example.com/api/v2/weather/us/ai/jp
https://dns.example.com/api/v2/weather/ai/jp
```

### 5.3 Profile 结构（内存）

```rust
struct Profile {
    global_region: RegionId,      // 枚举或 Interned string
    ai_region: Option<RegionId>,  // None = 跟随 global
}
```

解析后 **profile_id** 可哈希进缓存 key。

### 5.4 DoT/明文如何表达 profile（MVP 可选）

| 方式 | MVP |
|---|---|
| DoH path | **必须做** |
| 默认配置区 | **必须做** |
| 多 SNI / 多证书 | Phase 2 |
| 多端口 = 多 profile | Phase 2 |

---

## 6. 域名分类与匹配（核心）

### 6.1 分类语义

| class | 含义 | 选区规则 |
|---|---|---|
| `regional` | 区锁内容 | **强制** `region` 字段；忽略 path/Geo |
| `global` | 全球向流媒体 | `profile.global_region` |
| `ai` | AI 平台 | `profile.ai_region.unwrap_or(profile.global_region)` |
| `other` | 不在解锁表 | passthrough 最近 unlock DNS |

### 6.2 主数据源：1-stream 分段

上游：  
https://github.com/1-stream/1stream-public-utils/blob/main/stream.smartdns.list

```text
# ---------- > Global Plaform     → class=global
# ---------- > Japan Media        → class=regional, region=jp
# ---------- > Hong Kong Media    → class=regional, region=hk
# ---------- > Taiwan Media       → class=regional, region=tw
# ---------- > Europe Media       → class=regional, region=eu  # 或拆 uk
# ---------- > North America Media→ class=regional, region=us
# ---------- > Korean Media       → class=regional, region=kr
# ---------- > SouthEastAsia media→ class=regional, region=sea  # 东南亚
# ---------- > AI Platform        → class=ai
# ---------- > Others / ? media   → class=global 或 other（配置）
# ---------- > China Media        → class=global（无 cn 节点）；bilibili* 强制 hk
```

行格式：

```text
nameserver /example.com/<replace with groupname>
→ domain = example.com
```

### 6.3 段 → region 映射表（构建脚本配置）

```toml
# section-map.toml（日更脚本用）
[[section]]
match = "Global Plaform"      # 子串匹配段标题
class = "global"

[[section]]
match = "Japan Media"
class = "regional"
region = "jp"

[[section]]
match = "AI Platform"
class = "ai"

# … 完整列表实现时写死 + 可配置覆盖
```

### 6.4 与其它源合并规则

日更还可并入（与现 unlock 管线一致）：

- MetaCubeX geosite curated lists  
- `Lanlan13-14/Rules` Domain YAML（streaming_hk/sg/tw/uk、tvb）  
- StreamConfig / 1stream 补充  

**合并优先级（同一域名冲突时）：**

```text
1. regional 覆盖 global/ai（更严）
2. 更长后缀覆盖更短后缀（查询时自然最长匹配）
3. 显式 blocklist：Google/YouTube 族永不入库
```

### 6.5 发布产物格式 `domain-region.map`

纯文本，UTF-8，日更生成，中心拉取：

```text
# domain<TAB>class<TAB>region
# region: - 表示无（global/ai）
netflix.com	global	-
dmm.co.jp	regional	jp
mytvsuper.com	regional	hk
openai.com	ai	-
claude.ai	ai	-
```

约束：

- domain 小写、无尾点、无 `*.` / `+.`  
- class ∈ `global|regional|ai`  
- regional 的 region 必须非 `-`  
- 构建时 `sort -u`；中心 load 时再校验

### 6.6 运行时索引：后缀 Trie

**构建：** 每个 domain 按 label **从右到左** 插入 Trie，节点可挂 `Option<DomainPolicy>`。

```text
DomainPolicy { class, region: Option<RegionId> }
```

**查询 `a.b.example.com`：**

```text
labels = [com, example, b, a]  # 倒序 walk
walk root → com → example → b → a
记录路径上「最深」带 Policy 的节点 → 最长后缀命中
无命中 → class=other
```

复杂度：O(标签数)，与表大小无关。

**备选（实现更简单）：**  
插入时把所有后缀都放进 `HashMap<Box<str>, Policy>`（仅策略后缀，不是整表爆炸）；查询从全名到逐级剥左边 label。内存略大，逻辑简单，QPS 通常仍够。MVP 可用 HashMap，表极大再换 Trie。

### 6.7 UNLOCK_SCOPE

```text
global    → 仅 class∈{global, ai}（若 ENABLE_AI）可劫持
regional  → 仅 class==regional
all       → global + regional + ai
```

不在 scope 内的命中域名 → 视为 **other**（passthrough / 真实解析），**不要**返回 unlock IP。

```text
ENABLE_AI_UNLOCK=true|false   # false 时 ai 当 other 或并入 global 关闭
```

---

## 7. 调度决策（权威伪代码）

```text
fn resolve(qname, qtype, client_ip, profile) -> DnsResponse:

  qname = normalize(qname)
  if qtype not in handled: return policy_other_qtype()

  policy = domain_index.longest_match(qname)  # None → other

  class = policy.class if policy and in_scope(policy) else Other

  match class:
    Regional:
      pool = policy.region  # 强制
      node = pick_unlock(pool)
      return answer_a(qname, node.ip, unlock_ttl)

    Global:
      pool = profile.global_region
      node = pick_unlock(pool)
      return answer_a(qname, node.ip, unlock_ttl)

    Ai:
      pool = profile.ai_region.unwrap_or(profile.global_region)
      node = pick_unlock(pool)
      return answer_a(qname, node.ip, unlock_ttl)

    Other:
      if cache hit (qname, qtype, nearest_key): return cached
      node = nearest_unlock(client_ip)  # 仅 passthrough
      rr = passthrough_query(node, qname, qtype)
      cache store
      return rr
```

### 7.1 pick_unlock(pool)

```text
candidates = nodes.filter(region==pool && healthy)
if empty: candidates = nodes.filter(healthy)  # 降级可关
if empty: SERVFAIL
# 同池多机：weight 随机 或 最低 load 或 距 client 最近
return choose(candidates)
```

### 7.2 nearest_unlock(client_ip)

```text
# 仅用于 non-unlock passthrough
# GeoIP city/country → 距离 或 预置 region 偏好表
# 失败：DEFAULT_PASSTHROUGH_REGION 或任意 healthy
```

**禁止：** 用 nearest 决定 regional/global/ai 的解锁区。

### 7.3 TTL

```text
UNLOCK_ANSWER_TTL = 30..60s     # 节点切换
PASSTHROUGH_MAX_TTL = 300s      # 上限截断上游 TTL
```

---

## 8. 非解锁 Passthrough

### 8.1 语义

- 返回 **真实** RRset，客户端直连网站 CDN  
- **禁止** 把 other 解析成 unlock 公网 IP（除非错误配置）

### 8.2 为何问解锁机而不是中心自己 dig

- 单中心省事（你方选型）  
- 用 **离用户最近的解锁机** 作 DNS 出口，解析视角更接近用户大区  
- 解锁机 **保持现状**（可走 WARP）：接受区出口带来的几 ms 与解析视角，不要求双 DNS

### 8.3 中心 → 解锁机 DNS 接口

节点配置声明一种：

```toml
[[nodes]]
id = "jp-1"
region = "jp"
unlock_ip = "203.0.113.20"     # 返回给客户端的 A（解锁用）
dns_upstream = "203.0.113.20:53" # 代查用；MVP = 同机 53
dns_proto = "udp"                # udp | tcp | doh
# doh_url = "https://203.0.113.20:4430/dns-query"  # 若用 DoH
```

MVP：**UDP 53** 最简单（注意解锁机 ACL 放行中心 IP）。

超时：`PASSTHROUGH_TIMEOUT_MS=800`  
失败：尝试下一 nearest，再 `fallback_upstreams`（1.1.1.1 / 8.8.8.8 DoH）。

### 8.4 缓存

```text
key = (qname, qtype, passthrough_scope)
# passthrough_scope = nearest_region 或 node_id（答案可能随出口变）
```

分片 RwLock/DashMap；`max_entries` 上限 + TTL 过期。

---

## 9. 节点模型与健康检查

### 9.1 节点字段

```rust
struct Node {
    id: String,
    region: RegionId,
    unlock_ip: IpAddr,           // A/AAAA 应答
    dns_upstream: SocketAddr,    // 代查
    weight: u32,
    // runtime:
    healthy: AtomicBool,
    // optional: lat/lon for nearest
}
```

### 9.2 健康检查（Center 主动）

周期（如 10s）：

1. TCP 或 UDP 探测 `dns_upstream`（可选简单 query `.` 或 `example.com`）  
2. 可选：HTTP 探 unlock 自建 `/health`（若有）  
3. 连续失败 N 次 → unhealthy；成功 M 次 → healthy  

**不做** 中心替代 unlock 内部 WARP 检查（那是解锁机自己的 fail-closed）。

---

## 10. 证书（DoT/DoH）

与 `unlock` 对齐，**旁路进程/脚本**，不必 Rust 实现 ACME。

```text
DOT_TLS_MODE=selfsigned|letsencrypt
DOT_DOMAIN=dns.example.com
LE_EMAIL=...
CF_DNS_API_TOKEN=...    # 仅 Cloudflare DNS-01
```

行为：

| 模式 | 行为 |
|---|---|
| 仅 `ENABLE_DNS=1` | 不要求域名/证书 |
| DoT 或 DoH 开 | 需要 cert+key 路径 |
| letsencrypt | lego + CF DNS-01；续期后 **通知 center reload TLS**（SIGHUP 或 证书文件 mtime 轮询） |
| selfsigned | 启动生成或挂载固定测试证 |

复用/改编：`unlock/scripts/cert-manager.sh` → `unlock-center/scripts/cert-manager.sh`。

---

## 11. 配置规格

### 11.1 主配置 `config.toml` 示例

```toml
[listen]
# 至少开一个
enable_dns = false
dns_host = "0.0.0.0"
dns_port = 53

enable_dot = true
dot_host = "0.0.0.0"
dot_port = 853

enable_doh = true
doh_host = "0.0.0.0"
doh_port = 443
doh_base_path = "/api/v2/weather"
doh_extra_paths = []

[tls]
mode = "letsencrypt"          # selfsigned | letsencrypt | files
domain = "dns.example.com"
cert_file = "/data/tls/cert.pem"
key_file = "/data/tls/key.pem"
# letsencrypt 由 sidecar/脚本写上述文件

[policy]
unlock_scope = "all"          # global | regional | all
enable_ai_unlock = true
default_global_region = "us"
# default_ai_region 省略 = 跟随 global
allow_regions = ["us", "jp", "hk", "sg", "tw", "uk", "kr", "eu", "sea"]
unlock_answer_ttl_secs = 45
aaaa_mode = "empty"           # empty | passthrough | soa
other_qtype_mode = "refused"  # refused | passthrough

[tables]
domain_map_url = "https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock/domains/domain-region.map"
domain_map_file = ""          # 若非空优先本地
refresh_interval_secs = 3600
min_entries = 500

[nodes]
file = "/etc/unlock-center/nodes.toml"
# 或内联 [[nodes]]

[schedule]
nearest_for_passthrough = true
geoip_db = "/etc/unlock-center/GeoLite2-City.mmdb"
default_passthrough_region = "us"
# geo_for_global = false  永远 false

[passthrough]
timeout_ms = 800
fallback_upstreams = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

[cache]
unlock_max_entries = 100000
passthrough_max_entries = 500000
passthrough_max_ttl_secs = 300
shards = 64

[access]
# 空 = 不限制（生产建议配）
allowed_cidrs = []
# bearer_token = ""

[log]
level = "info"
```

### 11.2 `nodes.toml` 示例

```toml
[[nodes]]
id = "us-1"
region = "us"
unlock_ip = "203.0.113.10"
dns_upstream = "203.0.113.10:53"
weight = 10
lat = 37.77
lon = -122.42

[[nodes]]
id = "jp-1"
region = "jp"
unlock_ip = "203.0.113.20"
dns_upstream = "203.0.113.20:53"
weight = 10
lat = 35.68
lon = 139.69

[[nodes]]
id = "hk-1"
region = "hk"
unlock_ip = "203.0.113.30"
dns_upstream = "203.0.113.30:53"
weight = 10
lat = 22.3
lon = 114.2
```

### 11.3 环境变量覆盖（部署）

```text
CENTER_ENABLE_DOH=1
CENTER_DOH_PORT=443
CENTER_DOH_BASE_PATH=/api/v2/weather
CENTER_UNLOCK_SCOPE=all
CENTER_DEFAULT_GLOBAL_REGION=us
CENTER_DOMAIN_MAP_URL=https://...
CENTER_TLS_MODE=letsencrypt
CENTER_DOT_DOMAIN=dns.example.com
```

优先级：`env > config.toml > 默认值`。

---

## 12. 性能与并发设计

### 12.1 目标（可测）

| 指标 | MVP 目标 |
|---|---|
| 解锁命中 P99（本机 loopback） | < 1ms |
| 单实例解锁命中吞吐 | ≥ 2万 QPS（4 核级，供压测，非硬 KPI） |
| 域名表 5万～20万后缀 | 常驻内存可接受（HashMap/Trie） |
| 规则热更新 | 不中断查询；swap 后下一次查询用新表 |
| 非解锁 | 依赖缓存命中率；冷查询受 RTT 限制 |

### 12.2 热路径原则（Rust）

1. **零锁读表**：`arc_swap::ArcSwap<DomainIndex>`  
2. **少分配**：qname 小写用 `ArrayVec` 或 thread-local buffer  
3. **DNS 编解码**：`hickory-proto`；响应 buffer 复用  
4. **解锁命中无 await 上游**  
5. **对象池** 仅在需要时；优先栈上固定大小  
6. DoH：HTTP/2；限制 `max_concurrent_streams` / 全局限流可配  

### 12.3 不要做的

- 每查询读文件 / 解析 TOML  
- 每查询全表 `ends_with`  
- 每查询 `String::from` 狂飞无池化  
- 在热路径 `println!`  

### 12.4 压测清单

```text
1. 纯解锁命中（预热表，固定 qname 列表）
2. 随机命中表内域名
3. 全 other + 缓存命中
4. 全 other + 缓存冷（看上游）
5. DoH POST vs GET
6. 热更新期间 QPS 是否中断
```

工具：自写 tokio 压测客户端；或 dnsperf（明文）+ 自写 DoH。

---

## 13. Rust 工程结构

```text
unlock-center/
├── DEVELOPMENT.md          # 本文
├── README.md               # 用户向（后补）
├── Cargo.toml              # workspace
├── crates/
│   ├── unlock-center/      # bin：主进程
│   │   └── src/
│   │       ├── main.rs
│   │       ├── config.rs
│   │       ├── serve/
│   │       │   ├── mod.rs
│   │       │   ├── dns_udp.rs
│   │       │   ├── dns_tcp.rs
│   │       │   ├── dot.rs
│   │       │   └── doh.rs
│   │       ├── resolve.rs      # 决策核心
│   │       ├── profile.rs      # path/SNI → Profile
│   │       ├── tls.rs          # load/reload
│   │       ├── health.rs
│   │       ├── refresh.rs      # 拉 map
│   │       └── metrics.rs
│   ├── domain-index/       # lib：map 加载 + 最长后缀
│   ├── schedule/           # lib：节点、pick、nearest
│   └── dns-util/           # lib：normalize、answer 构造
├── scripts/
│   ├── cert-manager.sh     # 改编自 unlock
│   ├── build-domain-map.sh # 1-stream + 合并 → domain-region.map
│   └── entrypoint.sh
├── config.example.toml
├── nodes.example.toml
├── Dockerfile
└── tests/
    ├── domain_index_tests.rs
    ├── resolve_logic_tests.rs
    └── e2e/                # 可选
```

### 13.1 依赖建议（可调整）

```toml
tokio = { version = "1", features = ["full"] }
hickory-proto = "0.24"      # 或当前稳定版
hickory-client = "0.24"     # passthrough 客户端
rustls = "..."
tokio-rustls = "..."
hyper = { version = "1", features = ["server", "http1", "http2"] }
# 或 axum 0.7+
arc-swap = "1"
dashmap = "5"               # 缓存分片可选
serde / toml / serde_json
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls"] }
maxminddb = "0.24"          # nearest
tracing / tracing-subscriber
anyhow / thiserror
```

### 13.2 关键类型（示意）

```rust
enum Class { Global, Regional, Ai, Other }

struct DomainPolicy {
    class: Class,
    region: Option<RegionId>,
}

struct Profile {
    global: RegionId,
    ai: Option<RegionId>,
}

enum ResolveOutcome {
    Unlock { ip: IpAddr, ttl: u32, node_id: NodeId },
    Passthrough(Message),
    Fail(ResponseCode),
}
```

---

## 14. 日更与数据管线

### 14.1 `build-domain-map.sh`（可放 unlock 或 center）

```text
输入：
  - stream.smartdns.list（1-stream）
  - 可选 geosite / Rules / StreamConfig
输出：
  - domain-region.map
  - 统计：global/regional/ai 计数
校验：
  - 无 google/youtube 族
  - regional 必有 region
  - min_entries
```

### 14.2 与现有 unlock `all.txt` 关系

| 文件 | 消费者 |
|---|---|
| `domains/all.txt` | **解锁机** sniproxy/SmartDNS 劫持列表（可仍全量或按区子集） |
| `domains/domain-region.map` | **中心** 分类与选区 |

可同一次 Action 生成两者并 push。中心 **只依赖 map**，不解析 SmartDNS conf。

### 14.3 中心刷新

```text
定时 / 启动：
  GET domain_map_url → 校验 → DomainIndex::build → ArcSwap::store
失败：保留旧表；打 error 指标
```

---

## 15. 安全

| 层 | 措施 |
|---|---|
| 传输 | DoT/DoH TLS |
| 伪装 | 自定义 `doh_base_path` |
| 访问控制 | `allowed_cidrs`；可选 Bearer（DoH Header） |
| 节点面 | 解锁机 DNS 仅放行中心 IP |
| 证书 | CF token 最小权限 Zone:Read + DNS:Edit 单 Zone |
| 配置 | 不把 token 打进日志 |
| 放大 | 限速 / 单 IP QPS（Phase 2）；拒绝任意 qtype 扫表 |

Path 伪装 **不能** 替代 ACL。

---

## 16. 可观测性

### 16.1 日志

- `tracing`：启动配置摘要（无 secret）、刷新成功/失败、节点 up/down  
- 热路径默认 **不** per-query info（可采样 debug）

### 16.2 Metrics（Prometheus 文本或 /metrics 另端口）

```text
center_queries_total{proto,class,result}
center_query_duration_seconds{proto,class}
center_cache_hit_total{cache}
center_passthrough_errors_total
center_nodes_healthy{region}
center_domain_map_entries
center_domain_map_build_timestamp
```

`/metrics` 建议绑 `127.0.0.1` 或独立 `METRICS_PORT` + ACL。

---

## 17. 容器与入口

### 17.1 Dockerfile 要点

- 多阶段：`cargo build --release`  
- 运行镜像：distroless 或 debian-slim + ca-certificates  
- 旁挂：`cert-manager` 脚本 + lego（与 unlock 类似）或 **sidecar**  
- `entrypoint`：确保证书（若需要）→ 启动 `unlock-center`  

### 17.2 能力

- 若绑 53：`NET_BIND_SERVICE` 或 sysctls  
- **不需要** `/dev/net/tun`、WARP、特权网卡（相对 unlock 更干净）

### 17.3 Compose 示意

```yaml
services:
  unlock-center:
    image: ghcr.io/lanlan13-14/proxym-easy-unlock-center:latest
    ports:
      - "53:53/udp"
      - "53:53/tcp"
      - "853:853/tcp"
      - "443:443/tcp"
    env_file: .env.center
    volumes:
      - ./nodes.toml:/etc/unlock-center/nodes.toml:ro
      - center-tls:/data/tls
    restart: unless-stopped
```

---

## 18. 实现阶段（里程碑）

### Phase 0 — 骨架（可编译可跑）

- [ ] Cargo workspace  
- [ ] 配置加载  
- [ ] 明文 UDP DNS：固定应答或简单逻辑  
- [ ] DomainIndex HashMap 最长后缀  
- [ ] `resolve`：regional/global 返回配置里写死的 IP  
- [ ] 单测：匹配与 scope  

### Phase 1 — MVP 可用

- [ ] DoT + DoH（自定义 path）  
- [ ] Profile path 解析  
- [ ] 节点表 + pick + healthy 探针  
- [ ] AI 跟随 / path 覆盖  
- [ ] UNLOCK_SCOPE  
- [ ] 非解锁 nearest passthrough UDP  
- [ ] 缓存  
- [ ] `build-domain-map.sh` + 示例 map  
- [ ] selfsigned TLS  

### Phase 2 — 生产对齐

- [ ] LE + CF DNS-01 脚本与 reload  
- [ ] 日更 URL 热加载  
- [ ] GeoIP nearest  
- [ ] Metrics  
- [ ] AAAA 策略与 unlock 一致  
- [ ] Dockerfile + CI  
- [ ] 压测报告  

### Phase 3 — 增强（按需）

- [ ] DoT SNI 多 profile  
- [ ] DoH Bearer  
- [ ] 中心多副本  
- [ ] 节点 HTTP 注册 API  
- [ ] Trie 替换 HashMap（若内存/性能需要）  

---

## 19. 测试规格

### 19.1 单元

| 用例 | 期望 |
|---|---|
| `a.dmm.co.jp` regional jp | unlock-jp IP |
| `netflix.com` + profile us | unlock-us IP |
| `openai.com` + profile us, ai=jp | unlock-jp IP |
| `openai.com` + profile us, ai=follow | unlock-us IP |
| `netflix.com` + SCOPE=regional | passthrough 非 unlock IP |
| `example.com` other | 非节点 unlock_ip |
| Google 域名不在 map | other |
| path 非法 | DoH 404 |

### 19.2 集成

- 三个 mock unlock（不同 IP + DNS 返回可区分的结果）  
- 中心指向 mock  
- dig / curl DoH 验证  

### 19.3 回归与 unlock 仓库

- map 构建脚本：无 Google；min count  
- 可选：CI 用 `cargo test` + 脚本 `sh -n`  

---

## 20. 客户端用法（文档用）

```bash
# DoH（伪装 path + 全局美区）
curl -H 'content-type: application/dns-message' \
  --data-binary @query.bin \
  "https://dns.example.com/api/v2/weather/us"

# 全局美区 + AI 日区
# path: /api/v2/weather/us/ai/jp

# DoT
# sni = dns.example.com:853

# 明文（默认区）
dig @center.example.com netflix.com +short
# → unlock-us 公网 IP
```

路由器/系统 DoH URL 示例：

```text
https://dns.example.com/api/v2/weather/us
```

---

## 21. 风险与决策记录

| 风险 | 缓解 |
|---|---|
| 单中心 DoH RTT | 接受（架构选型）；日后多副本 GeoDNS |
| 代查走解锁机 WARP | 接受（保持现状）；nearest 降低离谱出口 |
| 解锁机 53 对中心暴露 | ACL 仅中心 IP |
| 域名表错误导致错区 | 构建校验 + 可回滚 map + 短 TTL |
| 自定义 path 被扫 | ACL + TLS；path 非唯一安全层 |
| Rust 开发慢于 Go | Phase 切片；先 UDP 后 DoH |

**决策记录：**

1. 中心 Rust；解锁机不改 SmartDNS  
2. 中心无 sniproxy  
3. 全局/AI 定区靠 path/默认，不靠 GeoIP  
4. 非解锁 nearest 代查真实 DNS  
5. DoH path 可配置  

---

## 22. 验收标准（MVP 完成定义）

1. 可同时或分别开启 DNS/DoT/DoH，非法全关拒绝启动  
2. DoH 使用非 `/dns-query` 的 `doh_base_path` 成功解析  
3. `domain-region.map` 加载后：DMM→jp 机 IP，Netflix→path 全局区 IP  
4. AI 默认跟随全局；`/us/ai/jp` 时 AI 域名 → jp 机  
5. `UNLOCK_SCOPE=global` 时 regional 域名不返回 unlock IP  
6. `example.com` 返回真实解析（经 mock/最近节点），不是 unlock IP  
7. 规则文件热更新不中断服务  
8. 基础单测通过；README 含配置与客户端示例  

---

## 23. 开放问题（实现前可拍板）

| # | 问题 | 建议默认 |
|---|---|---|
| 1 | Europe 整段 vs 拆 uk | map 里 `eu`；Rules uk 覆盖为 `uk` |
| 2 | China Media 是否解锁 | 并入 global；bilibili* → hk |
| 3 | 解锁机是否对中心单独开 DoH | MVP UDP 53 即可 |
| 4 | AAAA 解锁命中 | `empty` |
| 5 | 中心是否实现 DoQ | 不做 |

---

## 24. 参考链接

- 1-stream 列表：https://github.com/1-stream/1stream-public-utils/blob/main/stream.smartdns.list  
- unlock 日更域名：https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock/domains/all.txt  
- Rules Domain：https://github.com/Lanlan13-14/Rules/tree/main/rules/Domain  
- RFC 8484 DoH  
- 现有 unlock 证书与三开关：`unlock/scripts/cert-manager.sh`、`unlock/scripts/gen-configs.sh`、`unlock/.env.example`  

---

## 25. 修订历史

| 日期 | 说明 |
|---|---|
| 2026-08-04 | 初版：Rust 中心完整开发规格（架构/匹配/配置/性能/阶段） |

---

**文档结束。** 实现以 Phase 0→1 顺序推进；接口（map 格式、path 语义、scope）变更需同步改本文与构建脚本。
