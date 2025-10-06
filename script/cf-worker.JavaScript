// 配置项
const SERVER_TOKENS = ["hk01", "sg01", "us01"];  // 后端 push token 列表
const CLIENT_TOKEN = "supersecretclienttoken123456"; // Sub-Store 拉取 token

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // -------------------------
    // Push 接口 /push
    // -------------------------
    if (path === "/push") {
      let token, uri;
      if (request.method === "POST") {
        try {
          const j = await request.json();
          token = j.token;
          uri = j.uri;
        } catch {
          token = url.searchParams.get("token");
          uri = url.searchParams.get("content") || url.searchParams.get("uri");
        }
      } else {
        token = url.searchParams.get("token");
        uri = url.searchParams.get("content") || url.searchParams.get("uri");
      }

      if (!token || !uri) return new Response("Missing token or uri", { status: 400 });
      if (!SERVER_TOKENS.includes(token)) return new Response("Unauthorized token", { status: 401 });

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
      const ua = (request.headers.get("User-Agent") || "").toLowerCase();
      if (!ua.includes("iclash")) return new Response("Forbidden: UA not allowed", { status: 403 });

      const token = url.searchParams.get("token");
      if (!token || token !== CLIENT_TOKEN) return new Response("Unauthorized: wrong client token", { status: 401 });

      const server = url.searchParams.get("server");
      const raw = await env.NODE_STORAGE.get("SERVERS");
      const servers = raw ? JSON.parse(raw) : {};

      let outList = [];
      if (server) {
        // 单个服务器
        if (!SERVER_TOKENS.includes(server)) return new Response("Bad Request: unknown server", { status: 400 });
        if (servers[server]) outList.push(servers[server]);
      } else {
        // ✅ 按 SERVER_TOKENS 顺序排列
        outList = SERVER_TOKENS
          .map(key => servers[key])
          .filter(Boolean);
      }

      const headers = {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
        "Surrogate-Control": "no-store"
      };

      if (outList.length === 0) return new Response("", { status: 204, headers });
      return new Response(outList.join("\n"), { status: 200, headers });
    }

    // -------------------------
    // 删除接口 /delete
    // -------------------------
    if (path === "/delete") {
      const ua = (request.headers.get("User-Agent") || "").toLowerCase();
      const clientToken = url.searchParams.get("token");
      const serverToken = url.searchParams.get("server");

      if (!clientToken || clientToken !== CLIENT_TOKEN) {
        return new Response("Unauthorized: wrong client token", { status: 401 });
      }

      const raw = await env.NODE_STORAGE.get("SERVERS");
      const servers = raw ? JSON.parse(raw) : {};

      if (serverToken) {
        // 删除单个
        if (!SERVER_TOKENS.includes(serverToken)) return new Response("Bad Request: unknown server", { status: 400 });
        delete servers[serverToken];
        await env.NODE_STORAGE.put("SERVERS", JSON.stringify(servers));
        return new Response(`Deleted server ${serverToken}`, { status: 200 });
      } else {
        // 删除全部（需要 UA 验证）
        if (!ua.includes("iclash")) return new Response("Forbidden: UA not allowed for delete all", { status: 403 });
        await env.NODE_STORAGE.put("SERVERS", JSON.stringify({}));
        return new Response("Deleted all servers", { status: 200 });
      }
    }

    // -------------------------
    // 404
    // -------------------------
    return new Response("Not Found", { status: 404 });
  }
};