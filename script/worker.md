知道各位想要极致懒人同时又保证安全性特此提供这种可能的方式，所需代码在本目录下（这都不想找你更不想动）

🧭 第一部分：在 Cloudflare 网页部署 Worker

✅ 1️⃣ 登录 Cloudflare Dashboard

👉 https://dash.cloudflare.com

左边菜单点：

Workers & Pages → Create


---

✅ 2️⃣ 创建一个 Worker

点击「Create Worker」

弹出来后点击「Start from scratch（从零开始）」


进入代码编辑界面后：
右边是 Worker 代码区域，把默认示例删掉，换成我给你的代码👇


---

✅ 3️⃣ 复制 Worker 代码

注意:
SERVER_TOKEN
>
CLIENT_TOKEN
>
UA
必须修改，若不修改后果自负

✅ 4️⃣ 创建 KV 命名空间

左侧菜单：

Workers & Pages → KV

→ 「Create namespace」 → 名称填 NODE_STORAGE

创建后，点进去复制 Namespace ID（不用放到代码里，网页里绑）


---

✅ 5️⃣ 绑定 KV 到 Worker

回到 Worker 编辑界面 → 顶部点「Settings」
下拉找到「KV Namespace Bindings」 → 「Add binding」

Binding name：NODE_STORAGE

Namespace：选刚刚创建的 KV


点击「Save」


---

✅ 6️⃣ 部署 Worker

回到「Code」界面，点击右上角「Deploy」
Cloudflare 会生成一个地址，例如：

https://substore.yourname.workers.dev

到这里就部署完成 ✅
🧠 第二部分：多服务器 Token 管理方式

你问的重点来了👇

> “如果有 n 台服务器，那我在哪里加 token 呢？”

答案就是：
👉 你在 Worker 代码里 SERVER_TOKENS 这块添加新的 token 即可👇

✅ 7️⃣ 示例
假设：

Worker 域名：https://example.workers.dev

Sub-Store 拉取 token（CLIENT_TOKEN）：supersecretclienttoken123456

后端 push token（服务器标识）：hk01、sg01、us01

UA：Iclash/1.0



---

1️⃣ Push 节点（服务器端）


curl -X POST 'https://example.workers.dev/push' \
  -H "Content-Type: application/json" \
  -d '{"token":"hk01","uri":"vmess://AAAAAA"}'

> 替换 "hk01" 和 "vmess://AAAAAA" “https://example.workers.dev/push”为对应服务器和节点 URI




---

2️⃣ 拉取订阅（Sub-Store 用）

拉取所有节点（拼接）

curl -A 'Iclash/1.0' 'https://example.workers.dev/sub?token=supersecretclienttoken123456'

拉取单个服务器节点

curl -A 'Iclash/1.0' 'https://example.workers.dev/sub?token=supersecretclienttoken123456&server=hk01'

> 注意：UA 必须包含 Iclash，token 必须和 CLIENT_TOKEN 匹配, 单个节点拉取必须和 SERVER_TOKEN 匹配




---

3️⃣ 删除单个服务器节点

curl 'https://example.workers.dev/delete?token=supersecretclienttoken123456&server=hk01'

> 删除指定 push token 节点
不需要 UA 校验，只要 CLIENT_TOKEN 正确即可




---

4️⃣ 删除全部节点

curl -A 'Iclash/1.0' 'https://example.workers.dev/delete?token=supersecretclienttoken123456'

> 会删除 KV 中所有服务器节点
必须 UA 包含 Iclash，且 token 是 Sub-Store 拉取 token




---

✅ 这样就完成了 多服务器 push + 安全拉取 + 单个/全部删除 全流程的 curl 操作

> 可以直接放在服务器脚本里做定时更新或清理
