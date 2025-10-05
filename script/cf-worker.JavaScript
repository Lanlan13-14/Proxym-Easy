// 配置项：请修改成你自己的 token 列表与 client token
const SERVER_TOKENS = [ "hk01", "sg01", "us01" ]; // 允许 push 的服务器 token 列表（示例）
const CLIENT_TOKEN = "supersecretclienttoken123456"; // 订阅口令，客户端拉取时必须带上这个 token

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // -------------------------
    // Push 接口 （POST 或 GET 都支持）
    // -------------------------
    if (path === "/push") {
      // 支持 POST JSON 或 query string (方便 curl 测试)
      let token, uri;
      if (request.method === "POST") {
        try {
          const j = await request.json();
          token = j.token;
          uri = j.uri;
        } catch (e) {
          // 如果不是 json，就尝试 query
          token = url.searchParams.get("token");
          uri = url.searchParams.get("content") || url.searchParams.get("uri");
        }
      } else {
        token = url.searchParams.get("token");
        uri = url.searchParams.get("content") || url.searchParams.get("uri");
      }

      if (!token || !uri) {
        return new Response("Missing token or uri", { status: 400 });
      }
      if (!SERVER_TOKENS.includes(token)) {
        return new Response("Unauthorized token", { status: 401 });
      }

      // 将所有服务器内容存在单个 key "SERVERS" 的 JSON 里
      const raw = await env.NODE_STORAGE.get("SERVERS");
      const servers = raw ? JSON.parse(raw) : {};
      servers[token] = uri;
      await env.NODE_STORAGE.put("SERVERS", JSON.stringify(servers));

      return new Response("OK");
    }

    // -------------------------
    // 订阅接口 /sub
    // -------------------------
    if (path === "/sub") {
      // 1) UA 校验（不区分大小写）
      const ua = (request.headers.get("User-Agent") || "").toLowerCase();
      if (!ua.includes("iclash")) {
        return new Response("Forbidden: UA not allowed", { status: 403 });
      }

      // 2) 客户端订阅 token 校验（必须带 CLIENT_TOKEN）
      const clientToken = url.searchParams.get("token");
      if (!clientToken || clientToken !== CLIENT_TOKEN) {
        return new Response("Unauthorized: missing or wrong client token", { status: 401 });
      }

      // 3) 可选按单服务器拉取 ?server=<server_token>
      const server = url.searchParams.get("server"); // 若传 server，就返回该 server 的节点
      const raw = await env.NODE_STORAGE.get("SERVERS");
      const servers = raw ? JSON.parse(raw) : {};

      let outList = [];
      if (server) {
        // 只能按已注册的 SERVER_TOKENS 拉
        if (!SERVER_TOKENS.includes(server)) {
          return new Response("Bad Request: unknown server", { status: 400 });
        }
        if (servers[server]) outList.push(servers[server]);
      } else {
        // 返回所有已存的值（过滤空）
        outList = Object.values(servers).filter(Boolean);
      }

      // 4) 防止边缘缓存（确保每次都触发 Worker）
      const headers = {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
        "Surrogate-Control": "no-store"
      };

      if (outList.length === 0) {
        return new Response("", { status: 204, headers });
      }
      return new Response(outList.join("\n"), { status: 200, headers });
    }

    return new Response("Not Found", { status: 404 });
  }
};