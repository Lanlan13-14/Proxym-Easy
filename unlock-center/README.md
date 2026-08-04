# unlock-center

**DNS 解锁控制面**（Rust）：客户端只连 **一个** 中心 DoH/DoT/53；**每一次 DNS 查询按域名独立选区**，可同时把日本限定、香港限定、英国限定等解析到不同解锁机。视频与 sniproxy / WARP **不经过中心**，由各区域 [unlock](../unlock/) 数据面处理。

> **重要（请先读）：**  
> - **支持多区并发。** 同一 DoH、同一时刻：`dmm.co.jp` → 日本机，`mytvsuper.com` → 香港机，`bbc.co.uk` → 英国机，互不排斥。  
> - **不是**「整台中心只能开一个地域」。  
> - `DEFAULT_GLOBAL_REGION` / DoH path 里的 `/us` **只钉 global（如 Netflix）和 AI 的默认出口**，**不会**关掉其它 regional 区锁。  
> - 要同时看日+港限定：中心 1 台 + **至少** jp、hk 各一台 unlock，并在 `nodes.toml` 登记即可。

| 组件 | 职责 |
|---|---|
| **unlock-center（本目录）** | 聪明 DNS：按 **单次查询的域名** 匹配分类、选区、选节点；非解锁就近代查 |
| **unlock（兄弟目录）** | 傻数据面：SmartDNS + sniproxy + **单区** WARP 出口；一区一机（或一区多机） |

设计规格全文：[DEVELOPMENT.md](./DEVELOPMENT.md)

---

## 1. 它解决什么问题

单台解锁机只有一个 WARP 出口区。多台解锁机（美/日/港/英…）时需要：

1. **一个入口**给客户端（不要每个 App 配一堆 DoH）
2. **多种区锁内容同时可用**：日区 DMM、港区 myTV、英区 BBC… **同一条 DoH 上按域名自动分流到不同机**
3. **全局流媒体**（Netflix 等）由路径/默认区钉死出口，**不要**用客户端 IP 库猜导致区漂
4. **AI** 默认跟全局区，也可路径单独指定
5. **普通网站**解析成真实 CDN；DNS 代查尽量走离用户近的解锁机

`unlock-center` 就是做这些的控制面。  
**「一个全局默认 + 任意多个 regional 区」同时生效** 是默认能力，不是阉割模式。

---

## 2. 架构（一眼看懂）

```text
手机 / 路由 / Clash
        │  唯一 DoH/DoT/53
        ▼
┌───────────────────┐
│  unlock-center    │  无 sniproxy / 无 WARP
│  每个查询独立选区  │
└─────────┬─────────┘
          │  例：同一客户端连续查询
          │  dmm.co.jp      → jp 机 IP
          │  mytvsuper.com  → hk 机 IP
          │  netflix.com    → us 机 IP（path/默认全局）
   ┌──────┼──────────────┐
   ▼      ▼              ▼
unlock-us  unlock-jp  unlock-hk / uk …
(WARP US)  (WARP JP)  (区出口)
   │
   └─ 客户端 80/443 直连「该次 DNS 返回的那台」机（sniproxy）
```

**决策（每个查询单独算一遍）：**

| 域名类型 | 如何定区 | 返回什么 |
|---|---|---|
| **regional**（区锁） | `domain-region.map` 里该域名绑定的区；**path/Geo 不能改** | **该区** `unlock_ip`（可同时存在 jp+hk+uk+…） |
| **global**（全球向流媒体） | **仅此项** 受 DoH path / `DEFAULT_GLOBAL_REGION` 影响 | 指定全局池的 `unlock_ip` |
| **ai** | path 的 AI 区，否则跟随 global | 对应池 `unlock_ip` |
| **other**（不在表内） | 客户端 IP → GeoIP → **最近**解锁机 DNS 代查 | **真实** A/AAAA（不是 unlock IP） |

`UNLOCK_SCOPE`：只开 global / 只开 regional / 全开（`all`）。  
在 `all` 下：**所有已登记节点对应的 regional 区同时有效**，不存在「选了 us 全局就丢了 jp/hk 区锁」。

**同一 DoH 上的并发示例：**

```bash
# 客户端只配一个 DoH：https://dns.example.com/api/v2/weather/us
dig @center dmm.co.jp +short       # → 日本 unlock 公网 IP
dig @center mytvsuper.com +short   # → 香港 unlock 公网 IP
dig @center netflix.com +short     # → 美国 unlock 公网 IP（path=/us）
```

---

## 2.1 DNS 查询逻辑（逐步 + 各种情况）

下面按 **代码真实顺序** 说明：中心每收到 **一条** DNS 查询，只根据这一条的「问谁、什么类型、从哪来、path 是什么」算答案。  
**上一条查日区、下一条查港区，互不影响。**

### 输入有哪些

| 输入 | 从哪来 | 干什么用 |
|---|---|---|
| `qname` | 查询名，如 `www.dmm.co.jp` | 匹配域名表（最长后缀） |
| `qtype` | A / AAAA / 其它 | A 完整调度；AAAA 默认解锁命中给空；其它默认拒绝 |
| `client_ip` | UDP/TCP/DoT/DoH 连接对端 | **仅** other 代查时 GeoIP nearest；**不**决定 Netflix 区 |
| `profile` | DoH path 解析；明文/DoT 用默认 | **仅** global / ai 选区 |
| `UNLOCK_SCOPE` | 配置 | 哪些 class 允许劫持 |
| `enable_ai_unlock` | 配置 | ai 类是否当解锁 |

### 总流程图（含未命中）

「命中」= 在 `domain-region.map` 最长后缀匹配到条目，且 `UNLOCK_SCOPE` 允许劫持该类。  
「未命中」= 表里没有，或有但被 SCOPE 关掉 → 一律当 **other**，走 **代查真实 DNS**（答案不是 unlock IP）。

```text
收到查询
  │
  ├─ 无 question ──────────────────────────────────────► SERVFAIL
  │
  ├─ qtype 不是 A / AAAA
  │     ├─ other_qtype_mode=refused（默认）─────────────► REFUSED
  │     └─ passthrough ────────────────────────────────► 【未命中通道】代查真实记录
  │
  ├─ qtype = AAAA
  │     │
  │     ├─ 先做与 A 相同的「分类」（见下）
  │     │
  │     ├─ 命中解锁 (global/regional/ai 且 scope 允许)
  │     │     └─ aaaa_mode=empty|soa（默认 empty）─────► NOERROR 空答案（防 IPv6 绕过 sniproxy）
  │     │
  │     └─ 未命中 (other) 或 aaaa_mode=passthrough ───► 【未命中通道】代查真实 AAAA
  │
  └─ qtype = A
        │
        ▼
     规范化 qname
        │
        ▼
     domain-region.map 最长后缀匹配
        │
        ├─ 未匹配到任何后缀 ──────────────────────────► class = other ──┐
        │                                                              │
        └─ 匹配到 class + region?                                      │
              │                                                        │
              ▼                                                        │
           UNLOCK_SCOPE 是否允许该类？                                   │
              │                                                        │
              ├─ 不允许（降级）─────────────────────────────────────────► class = other ──┤
              │                                                        │
              └─ 允许 ──► class = regional / global / ai               │
                            │                                          │
          ┌─────────────────┼─────────────────┐                        │
          ▼                 ▼                 ▼                        ▼
     ① regional        ② global           ③ ai              ④【未命中通道】other
     map 强制区         path/默认全局区     path AI 或跟随 global    代查真实 DNS
     A = 该区 unlock_ip  A = 该池 unlock_ip  A = 该池 unlock_ip     A/AAAA = 真实结果
          │                 │                 │                        │
          └─────────────────┴─────────────────┴── 客户端去连 unlock 80/443
                                                                   │
                                                                   └─ 客户端去连真实 CDN
                                                                      （不经 sniproxy）
```

### A 记录：分类怎么来

1. 规范化 `qname`（小写、去尾点）。  
2. 在 `domain-region.map` 做 **最长后缀匹配**  
   - 查 `a.b.dmm.co.jp` → 试 `a.b.dmm.co.jp` → `b.dmm.co.jp` → `dmm.co.jp` → …  
   - 命中则得到 `class` + 可选 `region`（regional 必有 region）。  
   - **整条后缀链都匹配不到 → 未命中 → class = other（不是丢弃查询）。**  
3. 套 `UNLOCK_SCOPE`（见下表）。不允许劫持的 class **降级为 other**（同样走未命中通道）。  
4. 按最终 class 分支：命中三类回 unlock IP；**other 只走代查**。

**SCOPE 与 class（谁会被劫持）：**

| UNLOCK_SCOPE | global | regional | ai（enable_ai=true） | 表外 other |
|---|---|---|---|---|
| `all`（默认） | 劫持 | 劫持 | 劫持 | 代查 |
| `global` | 劫持 | **不劫持→代查** | 劫持 | 代查 |
| `regional` | **不劫持→代查** | 劫持 | **不劫持→代查** | 代查 |

`enable_ai_unlock=false` 时：ai 一律当 other（代查），即使 scope=all。

### A 记录：四类结果分别怎么做

#### ① class = regional（区锁，如 DMM / myTV / BBC）

```text
pool = map 里该域名的 region          # 例 dmm.co.jp → jp
忽略：DoH path、DEFAULT_GLOBAL、客户端 IP/GeoIP
节点 = nodes 里 region==pool 且 healthy 的机（可加权）
返回：A = 该节点 unlock_ip，TTL≈45s
若该 region 无健康节点：
  allow_region_fallback=false（默认）→ SERVFAIL
  true → 任意健康节点（一般不要开）
```

**要点：** path 写 `/us` 也 **不能** 把 DMM 派去美国。  
**多区：** map 里 jp/hk/uk 各有域名时，只要 nodes 都有对应机，**全部同时有效**。

#### ② class = global（如 Netflix）

```text
pool = profile.global_region
     = DoH path 里的 {g}   若 path 是 /{base}/{g} 或 /{base}/{g}/ai/{a}
     = DEFAULT_GLOBAL_REGION  若 path 是 /{base} 或明文/DoT 默认 profile
节点 = region==pool 的 unlock
返回：A = unlock_ip
```

**要点：**  
- 只影响 global（和下面的 ai 跟随逻辑），**不影响** regional。  
- 新机用 `/sg`、美机用 `/us` → 同一中心、同一时刻 Netflix 可去不同区。  
- **默认不用** 客户端 IP 猜 global 区（防漂）。

#### ③ class = ai（如 openai.com）

```text
pool = profile.ai_region
     若 path 含 /ai/{a} → a
     否则若 DEFAULT_AI_REGION 非空 → 该值
     否则 → 与 global 相同（跟随 profile.global_region）
返回：A = 该 pool 的 unlock_ip
```

| path 示例 | global 池 | ai 池 |
|---|---|---|
| `/api/v2/weather` | DEFAULT（如 us） | 跟随 us |
| `/api/v2/weather/sg` | sg | 跟随 sg |
| `/api/v2/weather/us/ai/jp` | us | **jp** |
| `/api/v2/weather/ai/jp` | DEFAULT | **jp** |

#### ④ class = other（**未命中**，或被 SCOPE 关掉）

这是流程图里原先容易漏画的一支：**表里没有 / 被 scope 降级，不会拒绝查询，也不会乱指到某台 unlock 当网站 IP。**

**哪些情况会进 other（未命中通道）**

| 情况 | 例子 |
|---|---|
| map 完全没有该后缀 | `example.com`、`github.com`、任意普通站 |
| map 有，但 `UNLOCK_SCOPE` 不允许该类 | `SCOPE=global` 时查 `dmm.co.jp`（regional 被关） |
| map 标 ai，但 `enable_ai_unlock=false` | `openai.com` → 当 other |
| AAAA 且域名 other | 代查真实 AAAA |
| 非 A/AAAA 且 `other_qtype_mode=passthrough` | 少见；默认是 REFUSED 不进这里 |

**未命中处理流程（passthrough）**

```text
class = other
  │
  │  目的：答案 = 公网真实解析，客户端直连 CDN（不经 unlock sniproxy）
  │
  ▼
选「代查用」解锁机（只当 DNS 上游，答案里不会填它的 unlock_ip）
  │
  ├─ nearest_for_passthrough=true（默认）
  │     ├─ GeoIP 根据 client_ip 得到 lat/lon
  │     │     └─ 在 nodes 里按 lat/lon 选最近机
  │     └─ GeoIP 失败/未加载
  │           └─ default_passthrough_region 池（如 us）
  └─ nearest_for_passthrough=false
        └─ 只用 default_passthrough_region
  │
  ├─ 该选择失败 → 任意 healthy 节点
  │
  ▼
向节点 dns_upstream（例 203.0.113.20:53）发【相同 qname/qtype】
  │
  ├─ 成功 → 把上游 DNS 应答原样回给客户端（TTL 可截断到 passthrough_max_ttl）
  │         可缓存 key=(qname, qtype, 节点id)
  │
  └─ 失败 → 试 fallback_upstreams（默认 1.1.1.1:53、8.8.8.8:53）
        ├─ 成功 → 同样原样返回
        └─ 全失败 → SERVFAIL
```

**和「命中」的对比（务必分清）**

| | 命中 global/regional/ai | **未命中 other** |
|---|---|---|
| DNS 答案里的 A | **unlock 公网 IP** | **网站真实 IP** |
| 客户端接下来连谁 | 该区 sniproxy → WARP | 真实 CDN/源站 |
| 用不用 path 定区 | global/ai 用 | **不用** |
| 用不用 GeoIP | 否（regional/global/ai 定区） | **是**（只选代查从哪台机出去） |
| 解锁机 53 | 不必须给客户端 | **必须给中心**访问 `dns_upstream` |

**要点：**

- 未命中 **不是** 丢弃，也 **不是** 把 example.com 解析成某台 unlock_ip。  
- 代查从哪台 unlock 出去，只影响解析视角/延迟；答案仍是真实 RRset。  
- 若解锁机 53 未对中心放行，且 fallback 也挂 → 普通站会 SERVFAIL。

### Profile 从哪来（和协议有关）

| 协议 | profile 怎么定 |
|---|---|
| **DoH** | 解析 URL path（见 §6）；非法 path → **HTTP 404**，不进 DNS 逻辑 |
| **DoT** | MVP：固定 `Profile::default`（`DEFAULT_GLOBAL` + 可选 `DEFAULT_AI`） |
| **明文 DNS** | 同上默认 Profile |

因此：**「新机 Netflix→sg、美机 Netflix→us」靠 DoH path 区分**；只开 DoT 时两边 global 默认相同，除非你改默认或上多 SNI（未做）。

### 一张表看完「各种情况」

约定：nodes 有 us/jp/hk/sg；map 含下表域名；`DEFAULT_GLOBAL=us`；`SCOPE=all`；`aaaa_mode=empty`。

| # | 客户端 DoH path | 查询 | qtype | 结果 |
|---|---|---|---|---|
| 1 | `/…/us` | `dmm.co.jp` | A | **jp** unlock_ip（regional，忽略 path） |
| 2 | `/…/us` | `mytvsuper.com` | A | **hk** unlock_ip |
| 3 | `/…/us` | `netflix.com` | A | **us** unlock_ip |
| 4 | `/…/sg` | `netflix.com` | A | **sg** unlock_ip |
| 5 | `/…/us` | `netflix.com` | AAAA | **空** NOERROR（防 v6 绕过） |
| 6 | `/…/us` | `openai.com` | A | **us** unlock_ip（ai 跟随 global） |
| 7 | `/…/us/ai/jp` | `openai.com` | A | **jp** unlock_ip |
| 8 | `/…/us/ai/jp` | `netflix.com` | A | **us** unlock_ip（global 仍是 us） |
| 9 | `/…/us` | `example.com` | A | **未命中** → 真实 IP（other 代查，**不是** unlock_ip） |
| 10 | `/…/us` | `github.com` | A | 同上，表外域名一律未命中代查 |
| 11 | `/…/us` | `dmm.co.jp` | MX 等 | **REFUSED**（默认，未走代查） |
| 12 | SCOPE=`global` | `dmm.co.jp` | A | map 有但 scope 关 regional → **降级未命中** → 真实/代查 |
| 13 | SCOPE=`regional` | `netflix.com` | A | map 有但 scope 关 global → **降级未命中** → 真实/代查 |
| 14 | path 乱写 | 任意 | — | DoH **HTTP 404**（请求未进入 DNS 逻辑） |
| 15 | map 有 `uk` 但 nodes 无 uk 机 | `bbc.co.uk` | A | **命中 regional** 但无节点 → **SERVFAIL**（不是未命中代查） |
| 16 | 同 path 连查 jp 站再查 hk 站 | 两条 A | A | 分别 jp/hk unlock_ip，**同时成立** |
| 17 | 代查：unlock:53 全不通且 fallback 挂 | `example.com` | A | **未命中通道失败** → SERVFAIL |

### 和「客户端连上以后」的关系

```text
DNS 只负责告诉客户端「去连哪个 IP」
  ├─ 解锁命中 → 连 unlock_ip:443（sniproxy → 该区 WARP）
  └─ other    → 连真实 CDN IP（不经 unlock）

中心 绝不代理视频；也不会因为你在新加坡就把 DMM 改成新区。
```

### 错误码怎么理解

| 应答 | 常见原因 |
|---|---|
| A = 某 203.x unlock_ip | 解锁命中，去播流 |
| A = 公网 CDN IP | other 代查成功 |
| NOERROR 无 AAAA | 解锁域名的 AAAA 被策略掏空 |
| SERVFAIL | 该 region 无节点 / 代查全失败 |
| REFUSED | 非 A/AAAA 且未开 passthrough |
| HTTP 404 | DoH path 不是合法 base/profile |

---

## 3. 功能清单

- 明文 DNS / DoT / DoH **独立开关**，各最多一个端口
- DoH **可自定义路径**（伪装，不限于 `/dns-query`）
- 路径 **只** 指定全局区 / AI 区：`/us`、`/us/ai/jp`、`/ai/jp`（**不影响**其它 regional）
- 域名分类：`global` / `regional` / `ai`（日更 map）
- **多区并发 + 可自定义区域**（jp/hk/uk/… 同时在线）：节点 + map + `allow_regions`
- GeoIP City MMDB：**内置默认下载 URL**，可自定义日更时刻
- TLS：自签 或 **Let’s Encrypt + Cloudflare DNS-01 only**（与 unlock 同思路）
- 域名表定时拉取热更新；GeoIP `SIGUSR1` 热加载
- 无 sniproxy、无 TUN、无 WARP

---

## 4. 端到端配置教程（解锁机 + 中心机）

下面按 **真实联调顺序**：先多台区域解锁机，再中心，再客户端。  
假设你要同时：

- **日本限定**（DMM 等）→ 日本 unlock  
- **香港限定**（myTV 等）→ 香港 unlock  
- **新加坡机器看 Netflix** → path `/sg` → 新加坡 unlock  
- **美国机器看 Netflix** → path `/us` → 美国 unlock  

需要机器示例：

| 角色 | 公网 IP（示例） | 说明 |
|---|---|---|
| 中心 center | `203.0.113.1` | 只跑 unlock-center；域名 `dns.example.com` → 此 IP |
| 解锁 us | `203.0.113.10` | WARP 出口美国 |
| 解锁 jp | `203.0.113.20` | WARP 出口日本 |
| 解锁 hk | `203.0.113.30` | WARP 出口香港 |
| 解锁 sg | `203.0.113.50` | WARP 出口新加坡 |

客户端：新加坡家宽 `198.51.100.10`、美国家宽 `198.51.100.20`（按你实际改 ACL）。

---

### 4.1 总览：谁开什么端口、谁连谁

```text
[客户端]
  DoH → center:443  (或 DoT:853 / DNS:53)
  80/443 → 中心返回的那台 unlock 公网 IP（sniproxy）

[center]
  出站 UDP/TCP → 各 unlock:53   （非解锁代查；必须放行中心 IP）
  不连 unlock 的 80/443 做视频

[unlock-xx]
  53   ：可只给中心 IP（代查）+ 可选自己测试
  80/443：给「会看流媒体的客户端 IP」（sniproxy）
  DoT/DoH：可选；给中心当数据面时客户端通常只连中心 DoH，unlock 上 DoT/DoH 可关
```

防火墙/安全组最小集：

| 机器 | 放行入站 | 来源 |
|---|---|---|
| center | 443（DoH）、可选 853/53 | 你的客户端网段 |
| 每台 unlock | 80, 443 | 客户端网段 |
| 每台 unlock | 53/udp+tcp | **仅中心 IP** `203.0.113.1`（推荐） |

---

### 4.2 解锁机配置（每一台区域机各做一遍）

目录：[../unlock](../unlock/)。镜像：

```text
ghcr.io/lanlan13-14/proxym-easy-unlock:latest
```

#### 4.2.1 日区机 `unlock-jp` 示例 `.env`

在 **日本 VPS** 上 `unlock/` 目录：

```bash
cp .env.example .env
# 编辑 .env
```

```bash
TZ=Asia/Shanghai

# 本机公网 IP（DNS 解锁返回给客户端的地址，必须填对）
UNLOCK_IP=203.0.113.20

# ACL：客户端网段 + 中心 IP（中心要查 53 代查）
# 不要只写自己测试 IP 却漏掉中心，否则 center passthrough 失败
ALLOWED_IPS=198.51.100.0/24,203.0.113.1/32
ENABLE_ACL=1

# 给中心当数据面时：建议开明文 DNS 供中心代查；DoT/DoH 可关（客户端走中心）
ENABLE_DNS=1
DNS_UDP_PORT=53
ENABLE_DOT=0
ENABLE_DOH=0
# 若仍开 DoT/DoH，勿占 443（443 给 sniproxy）
# ENABLE_DOT=1
# DOT_PORT=853
# ENABLE_DOH=1
# DOH_PORT=4430
# DOT_DOMAIN=jp-dot.example.com
# DOT_TLS_MODE=letsencrypt
# LE_EMAIL=...
# CF_DNS_API_TOKEN=...

UPSTREAM_DNS=1.1.1.1,1.0.0.1
FORCE_AAAA_SOA=yes
PLATFORMS=all
REGIONS=

# 域名日更（解锁机劫持列表；URL/时刻可改，不是写死）
# 默认拉仓库 all.txt；可改 DOMAIN_LIST_URL 或 ENABLE_DOMAIN_AUTO_UPDATE=0 只用镜像内列表
ENABLE_DOMAIN_AUTO_UPDATE=1
DOMAIN_LIST_URL=https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock/domains/all.txt
DOMAIN_UPDATE_HOUR=4
DOMAIN_UPDATE_MINUTE=0
MIN_DOMAIN_COUNT=800

# Cloudflare Zero Trust WARP（出口必须是日本策略）
WARP_ORGANIZATION=your-team
WARP_CLIENT_ID=...
WARP_CLIENT_SECRET=...
WARP_REGISTER_TIMEOUT=240
WARP_CONNECT_TIMEOUT=120
ZT_RESTART_HOURS=12

ENABLE_SOCKS5=0
```

启动：

```bash
cd unlock
docker compose pull   # 或 build
docker compose up -d
docker compose logs -f
# 确认 WARP warp=on、smartdns/sniproxy 正常
```

**自检（在解锁机或你电脑上）：**

```bash
# 本机 DNS 是否把流媒体指到 UNLOCK_IP
dig @203.0.113.20 netflix.com +short
# 应接近 203.0.113.20

# 中心 IP 必须能打到 53（在中心机上测）
dig @203.0.113.20 example.com +short
```

#### 4.2.2 港区 / 美区 / 新区机

复制同一套，只改：

| 项 | us | hk | sg |
|---|---|---|---|
| `UNLOCK_IP` | `203.0.113.10` | `203.0.113.30` | `203.0.113.50` |
| `ALLOWED_IPS` | 同样含客户端网段 + **中心 IP** | 同左 | 同左 |
| WARP 组织/策略 | 美国出口 | 香港出口 | 新加坡出口 |

**每一台都是完整 unlock 镜像**，不是「中心附属进程」。WARP 失败则该机 fail-closed，中心只是选不到健康节点。

#### 4.2.3 解锁机端口对照（compose 默认）

| 端口 | 用途 | 中心联调时 |
|---|---|---|
| 53/udp+tcp | SmartDNS 明文 | **建议开**，给中心 `dns_upstream` |
| 80/443 | sniproxy | **必须开**，给客户端播流 |
| 853 / 4430 | DoT / DoH | 可选；客户端只连中心时可关 |
| 1080 | SOCKS5 | 可选，与中心无关 |

详细 unlock 变量见 [../unlock/README.md](../unlock/README.md) 与 [../unlock/.env.example](../unlock/.env.example)。

---

### 4.3 中心机配置（unlock-center）

镜像：

```text
ghcr.io/lanlan13-14/proxym-easy-unlock-center:latest
```

#### 4.3.1 准备文件

在中心机 `unlock-center/`（或任意部署目录）：

```bash
cp .env.example .env
cp nodes.example.toml nodes.toml
```

#### 4.3.2 `nodes.toml`（把所有解锁机登记进来）

```toml
[[nodes]]
id = "us-1"
region = "us"
unlock_ip = "203.0.113.10"          # 客户端最终连这个播 Netflix(美)
dns_upstream = "203.0.113.10:53"    # 中心代查普通域名
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
lat = 22.32
lon = 114.17

[[nodes]]
id = "sg-1"
region = "sg"
unlock_ip = "203.0.113.50"
dns_upstream = "203.0.113.50:53"
weight = 10
lat = 1.35
lon = 103.82
```

字段含义：

| 字段 | 含义 |
|---|---|
| `region` | 逻辑区名，与 map / DoH path 一致（`us`/`jp`/`hk`/`sg`/`uk`/自定义） |
| `unlock_ip` | 写入 DNS A 记录、客户端去连 sniproxy 的地址 |
| `dns_upstream` | 中心做 **非解锁代查** 时问谁；通常 `unlock_ip:53` |
| `lat`/`lon` | GeoIP nearest 用；建议填准 |

#### 4.3.3 中心 `.env` 完整示例

```bash
TZ=Asia/Shanghai

# —— 客户端入口：建议只开 DoH（或 DoT），明文按需 ——
CENTER_ENABLE_DNS=0
DNS_UDP_PORT=53
CENTER_ENABLE_DOT=1
DOT_PORT=853
CENTER_ENABLE_DOH=1
DOH_PORT=443
DOH_BASE_PATH=/api/v2/weather

# —— 策略：多区 regional 全开；默认全局区仅影响 Netflix 等 ——
UNLOCK_SCOPE=all
DEFAULT_GLOBAL_REGION=us
DEFAULT_AI_REGION=
DEFAULT_PASSTHROUGH_REGION=us
DOMAIN_MAP_URL=https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock-center/domains/domain-region.map

# —— 证书（中心自己的 dns.example.com）——
CENTER_TLS_MODE=letsencrypt
CENTER_DOT_DOMAIN=dns.example.com
LE_EMAIL=admin@example.com
CF_DNS_API_TOKEN=你的CF_Token
RENEW_CHECK_HOURS=12
RENEW_BEFORE_DAYS=30

# —— GeoIP（内置 URL，可不改）——
GEOIP_ENABLE=1
GEOIP_ENABLE_AUTO_UPDATE=1
GEOIP_UPDATE_HOUR=4
GEOIP_UPDATE_MINUTE=0
GEOIP_DB_PATH=/data/geoip/GeoLite2-City.mmdb
GEOIP_DB_URL=https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb

CENTER_LOG_LEVEL=info
```

DNS：`dns.example.com` 的 A 记录 → `203.0.113.1`（中心），Cloudflare **DNS only 灰云**（DoT/DoH 证书用 DNS-01，代理橙云按你网络习惯自行取舍；LE DNS-01 不依赖 80）。

#### 4.3.4 启动中心

```bash
cd unlock-center   # 含 docker-compose.yml 的目录
docker compose pull
docker compose up -d
docker compose logs -f

# 应看到：domain index loaded、nodes loaded、geoip、证书 ensure
```

Compose 映射：`53`（若开 DNS）、`853` DoT、`443` DoH；卷持久化证书与 GeoIP。

#### 4.3.5 中心侧自检

```bash
# 在中心或任意能访问中心 DNS 的机器（明文需 ENABLE_DNS=1 时）
# 或 dig 走 DoT/DoH 工具

# 区锁：多区同时正确
dig @203.0.113.1 dmm.co.jp +short          # → 203.0.113.20 (jp)
dig @203.0.113.1 mytvsuper.com +short      # → 203.0.113.30 (hk)

# 全局：默认 us（未带 path 的明文/DoT 默认 profile）
dig @203.0.113.1 netflix.com +short        # → 203.0.113.10 (us)

# 普通站：真实 IP，不是 203.0.113.x 解锁机
dig @203.0.113.1 example.com +short
```

DoH 用 path 区分 Netflix 区（见下节客户端）。

---

### 4.4 客户端配置（对照）

| 客户端位置 | DoH URL | Netflix 去哪 | 日/港区锁 |
|---|---|---|---|
| 新加坡机器 | `https://dns.example.com/api/v2/weather/sg` | **sg** 机 | 仍按 map → jp/hk 机 |
| 美国机器 | `https://dns.example.com/api/v2/weather/us` | **us** 机 | 同上 |
| 只关心默认全局 | `https://dns.example.com/api/v2/weather` | `DEFAULT_GLOBAL_REGION` | 同上 |

```text
# 全局美区 + AI 日本（区锁仍多区并发）
https://dns.example.com/api/v2/weather/us/ai/jp
```

DoT：主机 `dns.example.com:853`（MVP 用默认全局区；区锁仍按 map）。

系统 / 路由 / Clash 把 **DNS 指到中心** 即可；**不要**再把流媒体域名手动指到某一台 unlock（否则绕过中心调度）。

---

### 4.5 联调检查清单（务必按序勾）

**解锁机（每台）**

- [ ] `UNLOCK_IP` = 该机公网 IP  
- [ ] WARP 已连接且出口区正确（日机日本、港机香港…）  
- [ ] `ENABLE_DNS=1`，中心 `dig @unlockIP example.com` 通  
- [ ] `ALLOWED_IPS` 含 **客户端网段 + 中心 IP**  
- [ ] 80/443 对客户端可达；容器 sniproxy 在跑  

**中心**

- [ ] `nodes.toml` 每区至少一节点，IP 与上表一致  
- [ ] `region` 名与 path / map 一致（`sg` 不要写成 `singapore` 却 path 用 `/sg` 对不上）  
- [ ] 证书签发成功（`letsencrypt` 时）  
- [ ] GeoIP 文件已下载（日志无长期 missing）  
- [ ] 从中心能访问各 `dns_upstream:53`  

**客户端**

- [ ] DoH/DoT 指向中心域名  
- [ ] 新机 `/sg`、美机 `/us`（若要 Netflix 分区）  
- [ ] 播流时抓 DNS：奈飞 A 记录应是对应区 `unlock_ip`，不是中心 IP  

**常见翻车**

| 现象 | 原因 |
|---|---|
| 中心查区锁 SERVFAIL | `nodes.toml` 缺该 `region` 或节点全 unhealthy |
| 代查失败 / 普通站解析慢失败 | 解锁机 53 未放行中心 IP，或 `ENABLE_DNS=0` |
| 能解析到 unlock IP 但播不了 | 解锁机 80/443 ACL 没放行客户端，或 WARP 挂了 |
| 新机 Netflix 仍是美区 | DoH 仍用 `/us` 或默认 `DEFAULT_GLOBAL_REGION=us`，应改 `/sg` |
| 所有流媒体都进同一台机 | 只有一台 unlock 登记，或 map/节点 region 写错 |

---

### 4.6 最小拓扑（只有日+美）

若暂时没有港/新：

1. 只部署 `unlock-us` + `unlock-jp`  
2. `nodes.toml` 只留 us、jp  
3. 客户端 DoH：`.../us` 或 `.../jp` 选 Netflix 区  
4. 日区锁仍然只靠 jp 机；港区 map 有但无节点 → 该区查询会失败/降级（可补机或先不管）

---

### 4.7 镜像与 Compose 速查

| | 解锁机 | 中心 |
|---|---|---|
| 镜像 | `ghcr.io/lanlan13-14/proxym-easy-unlock:latest` | `ghcr.io/lanlan13-14/proxym-easy-unlock-center:latest` |
| 目录 | [../unlock](../unlock/) | 本目录 |
| 必填 | WARP + `UNLOCK_IP` + `ALLOWED_IPS` | `nodes.toml` + 域名/证书（若 DoT/DoH） |
| 发布 | `build-unlock-image.yml`（version+latest） | `build-unlock-center-image.yml`（version+latest，默认 v1.0.0） |

中心本地 Compose：

```bash
cp .env.example .env && cp nodes.example.toml nodes.toml
# 改真实 IP 与证书变量
docker compose up -d && docker compose logs -f
```

---

## 5. 本地开发（Cargo，无 Docker 时）

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

- 路径只影响 **global / ai** 的默认出口
- **regional 永远跟 map，且多区同时生效**：即使用 `/us`，查 `dmm.co.jp` 仍回日本机、查港区域名仍回香港机
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

**Q: 是不是只能解锁「一个全局 + 一个地域」？**  
**不是。** 那是文档曾写糊导致的误解。默认 `UNLOCK_SCOPE=all` 时，map 里所有 regional 区（jp/hk/uk/…）只要 `nodes.toml` 有对应机，就 **同时** 可解锁；`DEFAULT_GLOBAL_REGION` / path 只钉 Netflix 一类 global，不关掉其它区锁。

**Q: 为什么 DMM 走了日本，Netflix 却是美国，港区也能看？**  
同一 DoH 上按域名分流：DMM=regional→jp，港区站=regional→hk，Netflix=global→path/默认区。这是预期行为。

**Q: 想全家默认日区 Netflix？**  
`DEFAULT_GLOBAL_REGION=jp`，或客户端 DoH 固定 `.../jp`。日区/港区等 **regional 不受影响**。

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
