import express from "express";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createMcpServer } from "./tools.mjs";
import { createOAuth } from "./oauth.mjs";
import { audit } from "./audit.mjs";

export async function createApp() {
  const oauth = await createOAuth();
  const app = express();

  app.use(express.json({ limit: "512kb" }));
  app.use(express.urlencoded({ extended: true }));

  function clientIp(req) {
    return (req.headers["x-forwarded-for"] || "").split(",")[0].trim() || req.socket.remoteAddress || "unknown";
  }

  oauth.mountOAuth(app);

  app.post("/mcp", async (req, res) => {
    const tok = oauth.checkBearer(req);
    if (!tok) return res.status(401).json({ error: "unauthorized" });

    const ip = clientIp(req);
    if (!oauth.rateLimit(ip, "mcp")) {
      audit({ event: "mcp_rate_limited", ip, client_id: tok.client_id });
      return res.status(429).json({ error: "rate_limited" });
    }
    if (!oauth.rateLimitByClient(tok.client_id, "mcp")) {
      audit({ event: "mcp_rate_limited_client", client_id: tok.client_id });
      return res.status(429).json({ error: "rate_limited" });
    }

    const method = req.body?.method;
    const toolName = req.body?.params?.name;
    const args = req.body?.params?.arguments;
    const argsSummary = args ? Object.keys(args) : null;
    const commandSummary = toolName === "tmux" && args?.command ? args.command.slice(0, 200) : null;
    audit({ event: "mcp_call", method, tool: toolName, arg_keys: argsSummary, command: commandSummary, client_id: tok.client_id });

    try {
      const server = createMcpServer();
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      res.on("close", () => { transport.close(); server.close(); });
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (err) {
      console.error(err);
      if (!res.headersSent) res.status(500).json({ error: "MCP error" });
    }
  });

  app.get("/__stats", (req, res) => {
    res.json({
      clients: oauth.getClientCount(),
      tokens: oauth.getTokenCount(),
      refresh_tokens: oauth.getRefreshCount(),
      recovery_codes: oauth.getRecoveryCount()
    });
  });

  return { app, oauth };
}
