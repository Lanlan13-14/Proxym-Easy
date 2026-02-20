# Proxym-Easy

> [!Caution]
> 禁止任何形式的转载或发布至 🇨🇳 大陆平台  
>
> Any form of reprinting or posting to the 🇨🇳 mainland platform is prohibited

> [!WARNING]
> 中国大陆用户使用请遵守本国法律法规  
>
> Mainland China users please abide by the laws and regulations of your country.

---

## 免责申明 / Disclaimer

> [!IMPORTANT]
> 任何以任何方式查看此项目的人或直接或间接使用该项目的使用者都应仔细阅读此声明。  
> 保留随时更改或补充此免责声明的权利。  
> 一旦使用并复制了该项目的任何文件，则视为您已接受此免责声明。  
>
> Anyone who views this project in any way or uses it directly or indirectly should read this statement carefully.  
> We reserve the right to change or supplement this disclaimer at any time.  
> Once you use and copy any file of this project, you are deemed to have accepted this disclaimer.

- 本项目涉及的文件仅用于资源共享和学习研究，不能保证其合法性、准确性、完整性和有效性，请根据情况自行判断  
- 请勿将本项目的任何内容用于商业或非法目的

---

# ✨ Proxym-Easy（重构版）

通过 Xray 实现对 **VLESS Encryption / VLESS Reality / SS2022** 等节点服务端的快速部署与管理。

新版相较旧版有以下变化：

## 🆕 新版优势（推荐使用）

### ✔ 支持 x25519 / ML-KEM768  
旧版也支持 ML-KEM768，但新版结构更稳定、逻辑更清晰。

### ✔ 新增 GitHub 镜像加速  
可在脚本菜单中设置 GitHub 加速前缀，解决国内环境下载困难的问题。

### ✔ 新版 Xray 内核管理更完善  
旧版也支持 Xray 内核管理，但新版功能更完整：

- 安装 / 更新 / 卸载  
- 日志查看  
- DNS 管理  
- 定时重启  
- 入站管理（VLESS-ENC / Reality / SS2022）


---

# 🧩 旧版说明

旧版仍然可用，并具备以下特点：

### ✔ 支持 ML-KEM768  
旧版同样支持 ML-KEM768（VLESS-ENC）。

### ✔ 支持 Xray 内核管理  
旧版也能安装、更新、管理 Xray。

### ✔ 支持上传 worker（新版已移除）  
旧版允许上传 worker 文件用于自定义节点行为。

### ✔ 自动根据 IP 生成节点名称（新版已移除）  
旧版会自动根据服务器 IP 生成节点名称，新版不再包含此功能。

---

# 🔄 新旧版差异总结

| 功能 | 旧版 | 新版 |
|------|------|------|
| ML-KEM768 支持 | ✔ 支持 | ✔ 支持 |
| x25519 支持 | ❌ 不支持 | ✔ 支持 |
| ss2022 支持 | ❌ 不支持 | ✔ 支持 |
| GitHub 加速前缀 | ❌ 不支持 | ✔ 支持 |
| 上传 worker | ✔ 支持 | ❌ 移除 |
| 自动生成节点名称 | ✔ 支持 | ❌ 移除 |
| Xray 内核管理 | ✔ 支持 | ✔ 支持（更完善） |
| 配置结构 | 单文件 | 模块化 conf.d |
| 推荐程度 | ⚠ 可用 | ⭐ 强烈推荐 |

---

# 📂 新旧版文件结构差异

新版与旧版的文件结构完全不同，这是两者最核心的差异之一。

---

## 🆕 新版（重构版）文件结构

新版采用 **Xray 官方推荐的模块化结构**，所有配置分离、可扩展性更强。

```
/usr/local/bin/proxym-easy        ← 主脚本（新版）
/etc/xray/                        ← Xray 主目录
├── config.json                   ← 主配置（入口）
├── conf.d/                       ← 子配置目录（模块化）
│   ├── 01-dns.json
│   ├── 02-base.json
│   ├── xx-inbound-*.json         ← 各类入站（Reality / ENC / SS2022）
│   └── xx-outbound.json
├── bin/xray                      ← Xray 内核
└── githubproxy                   ← GitHub 加速前缀（新版新增）
```

### 新版特点
- 模块化 conf.d 结构
- 支持 GitHub 镜像加速
- 支持 x25519 / ML-KEM768
- 入站出站DNS配置独立文件，互不影响
- Xray 内核由脚本自动管理

---

## 🧩 旧版文件结构

旧版采用 **单文件配置结构**，并包含 worker 上传等旧功能。

```
/usr/local/bin/proxym-easy        ← 主脚本（旧版）
/usr/local/etc/xray/config.json   ← 单文件配置（旧版结构）
/etc/proxym/
├── vless.json                    ← URI 保存位置
└── worker/                       ← worker 上传目录（新版已移除）
```

### 旧版特点
- 单文件 config.json  
- 支持 worker 上传  
- 自动根据 IP 生成节点名称  
- ML-KEM768 支持（但结构不如新版稳定）  
- 无 GitHub 加速前缀功能  

---

# 🚀 安装（新版）

```
wget -O /usr/local/bin/proxym-easy https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/xray.sh && chmod +x /usr/local/bin/proxym-easy && /usr/local/bin/proxym-easy
```

---

# 📦 安装（旧版）

旧版安装脚本仍然保留，适用于需要旧功能（如 worker 上传、自动节点命名）的用户：

```
curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/vless-encryption.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy /usr/local/bin/proxym-easy && sudo proxym-easy
```

---

# ▶ 已安装后执行

```
sudo proxym-easy
```

---

# ❌ 卸载

卸载选项已内置在脚本菜单中，可选择：

- 仅卸载脚本  
- 仅卸载 Xray  
- 全部卸载  

---

# 📁 文件路径说明

### URI 保存位置（仅旧版）
```
/etc/proxym/vless.json
```

### Xray 配置文件（新版）
```
/etc/xray
```

---

# 🔧 重置 UUID / 密码（仅旧版）

```
sudo proxym-easy reset
```

---

# ⚠ 重要提示（仅旧版）

### ❗ VLESS Encryption 与 VLESS Reality **无法同时启用**  
当你启用 Reality 时，之前生成的 VLESS Encryption 配置将不会生效。

---

# 🔐 TLS / WS 推荐

若使用 **VLESS Encryption + WS + TLS**  
推荐搭配：

👉 [Cert-Easy](https://github.com/Lanlan13-14/Cert-Easy)

可实现输入域名后自动填充证书与 TLS 配置。

---

# 🌐 Reality 域名推荐

👉 [点击查看](https://www.v2ray-agent.com/archives/1689439383686)

---

# 📘 部分功能解答（可选）

👉 [点击查看](https://github.com/Lanlan13-14/Proxym-Easy/blob/main/script%2Fworker.md)