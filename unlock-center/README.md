# unlock-center

DNS 解锁 **控制面**（Rust）：明文 DNS / DoT / DoH → 按域名分类调度到区域解锁机。

详细设计见 [DEVELOPMENT.md](./DEVELOPMENT.md)。

## 功能

- 三端口：`ENABLE_DNS` / `ENABLE_DOT` / `ENABLE_DOH`
- DoH **可自定义路径**（`doh_base_path`，可伪装）
- 域名分类：`global` / `regional` / `ai`（`domains/domain-region.map`）
- `UNLOCK_SCOPE`：`global` | `regional` | `all`
- 全局 / AI 区：DoH path 指定（如 `/us`、`/us/ai/jp`）
- **可自定义区域**（如 `uk`）：节点 `region` + map 标注 + `allow_regions`
- 非解锁：向最近（或默认区）解锁机 DNS 代查真实记录
- 无 sniproxy / 无 WARP（解锁机 `../unlock` 保持现状）

## 域名列表（GitHub 分类存放）

| 文件 | 含义 |
|---|---|
| [domains/domain-region.map](domains/domain-region.map) | 主表：`domain\\tclass\\tregion`（中心加载） |
| [domains/global.txt](domains/global.txt) | 仅全局类域名 |
| [domains/regional.txt](domains/regional.txt) | 仅区域限定域名 |
| [domains/ai.txt](domains/ai.txt) | 仅 AI 类域名 |

生成：

```sh
sh scripts/build-domain-map.sh
```

日更：仓库 Action `update-unlock-domains` 会一并重建（见 workflow）。

固定 URL 示例：

```text
https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/unlock-center/domains/domain-region.map
```

## 快速开始

```sh
# 1) 生成分类域名表
sh scripts/build-domain-map.sh

# 2) 编辑节点（填真实 unlock 公网 IP）
cp nodes.example.toml nodes.toml

# 3) 配置
cp config.example.toml config.toml
# 开发可只开明文 DNS、高位端口

# 4) 运行
cargo run -p unlock-center --release -- -c config.toml
```

测试查询：

```sh
dig @127.0.0.1 -p 5353 netflix.com +short
# → 对应 default_global_region 节点的 unlock_ip

dig @127.0.0.1 -p 5353 dmm.co.jp +short
# → jp 节点 unlock_ip
```

DoH（自签证书需 -k）：

```text
https://dns.example.com:8443/api/v2/weather/us
https://dns.example.com:8443/api/v2/weather/us/ai/jp
```

## 添加 UK 等新区

1. 部署英区 `unlock` 实例  
2. `nodes.toml` 增加 `region = "uk"`  
3. `allow_regions` 包含 `uk`  
4. map 中英区域名为 `regional` + `uk`（`build-domain-map` 已从 Rules `streaming_uk` / 1-stream Europe 等生成；可手改 map）  
5. 全局走英区出口：客户端 DoH path `.../uk`

## 构建

```sh
cargo build -p unlock-center --release
cargo test --workspace
```
