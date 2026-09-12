#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "Installing Termux MCP..."
pkg update -y && pkg upgrade -y
pkg install -y nodejs-lts cloudflared tmux || pkg install -y nodejs cloudflared tmux
mkdir -p ~/termux-mcp && cd ~/termux-mcp
npm init -y >/dev/null
npm install @modelcontextprotocol/sdk express zod jose --save-exact >/dev/null

cat > server.mjs <<'MCPEOF'
import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { createRemoteJWKSet, jwtVerify, createLocalJWKSet } from "jose";

const execAsync = promisify(exec);
const WORKDIR = path.join(os.homedir(), "mcp-work");
await fs.mkdir(WORKDIR, { recursive: true });

const PORT = process.env.PORT || 8000;
const SHELL = "/data/data/com.termux/files/usr/bin/bash";
const ALLOW_UNRESTRICTED = process.env.MCP_ALLOW_UNRESTRICTED === "1";
const ISOLATED_SESSION = "mcp-ai";
const PROTECTED_SESSIONS = new Set(["mcp-server", "mcp-tunnel"]);

const WRITE_MAX_BYTES = 256 * 1024;
const WRITE_ALLOWED_EXT = new Set([
  ".txt", ".md", ".json", ".csv", ".log",
  ".yaml", ".yml", ".toml", ".ini", ".conf",
  ".html", ".css", ".xml", ".svg"
]);

const clients = new Map();
const authCodes = new Map();
const tokens = new Map();
const jwksCache = new Map();

function publicUrl(req) {
  if (process.env.PUBLIC_URL) return process.env.PUBLIC_URL;
  const host = req.headers["x-forwarded-host"] || req.headers.host;
  const proto = req.headers["x-forwarded-proto"] || "https";
  return `${proto}://${host}`;
}

function safePath(p = ".") {
  const base = path.resolve(WORKDIR);
  const target = path.resolve(base, p);
  if (target !== base && !target.startsWith(base + path.sep)) throw new Error("path escapes sandbox");
  return target;
}

function validSession(name) {
  return typeof name === "string" && /^[a-zA-Z0-9_-]{1,40}$/.test(name);
}

function getJwks(uri) {
  if (!jwksCache.has(uri)) jwksCache.set(uri, createRemoteJWKSet(new URL(uri)));
  return jwksCache.get(uri);
}

function createMcpServer() {
  const server = new McpServer({ name: "termux", version: "2.0.0" });

  server.tool("whoami", {}, async () => ({
    content: [{ type: "text", text: os.userInfo().username || "unknown" }]
  }));

  server.tool("pwd", {}, async () => ({
    content: [{ type: "text", text: WORKDIR }]
  }));

  server.tool("date", {}, async () => {
    const { stdout } = await execAsync("date '+%Y-%m-%d %H:%M:%S %Z (%A)'", { shell: SHELL });
    return { content: [{ type: "text", text: stdout.trim() }] };
  });

  server.tool("system_info", {}, async () => {
    const { stdout } = await execAsync(
      "uname -a; echo; uptime; echo; df -h $HOME | tail -1; echo; free -m 2>/dev/null | head -2",
      { shell: SHELL }
    );
    return { content: [{ type: "text", text: stdout }] };
  });

  server.tool("list_apps", {}, async () => {
    const { stdout } = await execAsync("pm list packages | sed 's/package://' | sort", { shell: SHELL });
    return { content: [{ type: "text", text: stdout }] };
  });

  server.tool("open_app",
    { package_name: z.string().describe("Android package name") },
    async ({ package_name }) => {
      if (!/^[a-zA-Z0-9._]+$/.test(package_name)) {
        return { content: [{ type: "text", text: "Invalid package name" }], isError: true };
      }
      try {
        const { stdout, stderr } = await execAsync(
          `monkey -p ${package_name} -c android.intent.category.LAUNCHER 1`,
          { timeout: 10000, shell: SHELL }
        );
        if (stdout.includes("No activities found") || stderr.includes("No activities found")) {
          return { content: [{ type: "text", text: `App not found: ${package_name}` }], isError: true };
        }
        return { content: [{ type: "text", text: `Launched ${package_name}` }] };
      } catch (e) {
        return { content: [{ type: "text", text: `Failed: ${e.message}` }], isError: true };
      }
    }
  );

  server.tool("list_dir",
    { path: z.string().default(".") },
    async ({ path: p }) => {
      const entries = await fs.readdir(safePath(p), { withFileTypes: true });
      const out = entries.map(e => `${e.isDirectory() ? "d" : "-"} ${e.name}`).join("\n");
      return { content: [{ type: "text", text: out || "(empty)" }] };
    }
  );

  server.tool("read_file",
    { path: z.string() },
    async ({ path: p }) => {
      const text = await fs.readFile(safePath(p), "utf8");
      return { content: [{ type: "text", text: text.slice(-10000) }] };
    }
  );

  server.tool("write_file",
    {
      path: z.string().describe("Relative path inside the sandbox"),
      content: z.string().describe("File contents"),
      mode: z.enum(["create", "overwrite"]).default("create").describe(
        "create = fail if file exists. overwrite = replace it with a .bak backup."
      ),
    },
    async ({ path: p, content, mode }) => {
      const target = safePath(p);
      const ext = path.extname(target).toLowerCase();

      if (!WRITE_ALLOWED_EXT.has(ext)) {
        return { content: [{ type: "text", text: `Extension not allowed: ${ext || "(none)"}` }], isError: true };
      }

      const bytes = Buffer.byteLength(content, "utf8");
      if (bytes > WRITE_MAX_BYTES) {
        return { content: [{ type: "text", text: `Too large: ${bytes} bytes (max ${WRITE_MAX_BYTES})` }], isError: true };
      }

      if (content.startsWith("#!")) {
        return { content: [{ type: "text", text: "Shebang not allowed" }], isError: true };
      }

      let exists = false;
      try { await fs.access(target); exists = true; } catch {}

      if (exists && mode !== "overwrite") {
        return { content: [{ type: "text", text: `File exists: ${target}. Use mode=overwrite to replace.` }], isError: true };
      }

      if (exists && mode === "overwrite") {
        try { await fs.copyFile(target, target + ".bak"); } catch {}
      }

      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.writeFile(target, content, "utf8");

      return {
        content: [{
          type: "text",
          text: exists ? `overwrote ${target} (backup at ${target}.bak)` : `created ${target}`
        }]
      };
    }
  );

  server.tool("append_file",
    { path: z.string(), content: z.string() },
    async ({ path: p, content }) => {
      const target = safePath(p);
      const ext = path.extname(target).toLowerCase();

      if (!WRITE_ALLOWED_EXT.has(ext)) {
        return { content: [{ type: "text", text: `Extension not allowed: ${ext || "(none)"}` }], isError: true };
      }

      const bytes = Buffer.byteLength(content, "utf8");
      if (bytes > WRITE_MAX_BYTES) {
        return { content: [{ type: "text", text: `Too large: ${bytes} bytes (max ${WRITE_MAX_BYTES})` }], isError: true };
      }

      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.appendFile(target, content, "utf8");
      return { content: [{ type: "text", text: `appended to ${target}` }] };
    }
  );

  server.tool("tmux",
    {
      action: z.enum(["list", "read", "send", "create", "kill", "attach"]),
      target: z.enum(["isolated", "session"]).default("isolated"),
      name: z.string().optional(),
      command: z.string().optional(),
      lines: z.number().optional(),
    },
    async ({ action, target, name, command, lines = 50 }) => {
      if (target === "session" && !ALLOW_UNRESTRICTED) {
        return { content: [{ type: "text", text: "Not permitted in restricted mode. Use target=isolated." }], isError: true };
      }

      let session;
      if (target === "isolated") {
        session = ISOLATED_SESSION;
        try {
          await execAsync(`tmux has-session -t ${ISOLATED_SESSION} 2>/dev/null`, { shell: SHELL });
        } catch {
          await execAsync(`tmux new-session -d -s ${ISOLATED_SESSION}`, { shell: SHELL });
        }
      } else {
        if (!validSession(name)) return { content: [{ type: "text", text: "Invalid session name" }], isError: true };
        if (PROTECTED_SESSIONS.has(name)) return { content: [{ type: "text", text: "Session is protected" }], isError: true };
        session = name;
      }

      try {
        switch (action) {
          case "list": {
            if (!ALLOW_UNRESTRICTED) {
              try {
                await execAsync(`tmux has-session -t ${ISOLATED_SESSION} 2>/dev/null`, { shell: SHELL });
                return { content: [{ type: "text", text: `${ISOLATED_SESSION}: 1 windows (isolated)` }] };
              } catch {
                return { content: [{ type: "text", text: "(no sessions)" }] };
              }
            }
            const { stdout } = await execAsync("tmux ls 2>&1 || true", { shell: SHELL });
            return { content: [{ type: "text", text: stdout.trim() || "(no sessions)" }] };
          }
          case "read": {
            const { stdout } = await execAsync(
              `tmux capture-pane -t ${session} -p -S -${Math.min(lines, 500)}`,
              { shell: SHELL }
            );
            return { content: [{ type: "text", text: stdout.replace(/\s+$/g, "") || "(empty)" }] };
          }
          case "attach": {
            return { content: [{ type: "text", text: `tmux attach -t ${session}` }] };
          }
          case "create": {
            if (target === "session") {
              try {
                await execAsync(`tmux has-session -t ${session} 2>/dev/null`, { shell: SHELL });
              } catch {
                await execAsync(`tmux new-session -d -s ${session}`, { shell: SHELL });
              }
            }
            if (command) {
              await execAsync(
                `tmux send-keys -t ${session} -l ${JSON.stringify(command)} && tmux send-keys -t ${session} Enter`,
                { shell: SHELL }
              );
            }
            return { content: [{ type: "text", text: `Ready: ${session}` }] };
          }
          case "send": {
            await execAsync(
              `tmux send-keys -t ${session} -l ${JSON.stringify(command || "")} && tmux send-keys -t ${session} Enter`,
              { shell: SHELL }
            );
            return { content: [{ type: "text", text: `Sent to ${session}` }] };
          }
          case "kill": {
            await execAsync(`tmux kill-session -t ${session}`, { shell: SHELL });
            return { content: [{ type: "text", text: `Killed ${session}` }] };
          }
        }
      } catch (e) {
        return { content: [{ type: "text", text: `Failed: ${e.message}` }], isError: true };
      }
    }
  );

  return server;
}

const app = express();
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: true }));

app.get("/.well-known/oauth-authorization-server", (req, res) => {
  const base = publicUrl(req);
  res.json({
    issuer: base,
    authorization_endpoint: `${base}/authorize`,
    token_endpoint: `${base}/token`,
    registration_endpoint: `${base}/register`,
    scopes_supported: ["mcp:tools"],
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code"],
    token_endpoint_auth_methods_supported: ["none", "private_key_jwt"],
    code_challenge_methods_supported: ["S256"],
  });
});

app.get("/.well-known/oauth-protected-resource", (req, res) => {
  const base = publicUrl(req);
  res.json({
    resource: `${base}/mcp`,
    authorization_servers: [base],
    bearer_methods_supported: ["header"],
    scopes_supported: ["mcp:tools"],
  });
});

app.post("/register", (req, res) => {
  const { client_name, redirect_uris, token_endpoint_auth_method, jwks_uri, jwks } = req.body || {};
  const clientId = crypto.randomUUID();
  clients.set(clientId, {
    client_id: clientId, client_name,
    redirect_uris: redirect_uris || [],
    token_endpoint_auth_method: token_endpoint_auth_method || "none",
    jwks_uri: jwks_uri || null, jwks: jwks || null,
  });
  res.status(201).json({
    client_id: clientId,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    redirect_uris: redirect_uris || [],
    token_endpoint_auth_method: token_endpoint_auth_method || "none",
    grant_types: ["authorization_code"],
    response_types: ["code"],
  });
});

app.get("/authorize", (req, res) => {
  const { client_id, redirect_uri, state, code_challenge, code_challenge_method, scope } = req.query;
  const client = clients.get(client_id);
  if (!client) return res.status(400).send("Unknown client_id");
  res.send(`<!DOCTYPE html><html><body style="font-family:sans-serif;padding:2rem;max-width:500px;margin:auto">
<h1>Approve Access</h1>
<p><b>${client.client_name || client_id}</b> wants to use your Termux tools.</p>
<form method="POST" action="/authorize/approve">
<input type="hidden" name="client_id" value="${client_id}">
<input type="hidden" name="redirect_uri" value="${redirect_uri}">
<input type="hidden" name="state" value="${state || ""}">
<input type="hidden" name="code_challenge" value="${code_challenge || ""}">
<input type="hidden" name="code_challenge_method" value="${code_challenge_method || ""}">
<input type="hidden" name="scope" value="${scope || "mcp:tools"}">
<button type="submit" style="padding:1rem 2rem;background:#0070f3;color:#fff;border:none;border-radius:5px;cursor:pointer">Approve</button>
</form></body></html>`);
});

app.post("/authorize/approve", (req, res) => {
  const { client_id, redirect_uri, state, code_challenge, code_challenge_method, scope } = req.body;
  const code = crypto.randomBytes(32).toString("hex");
  authCodes.set(code, {
    client_id, redirect_uri,
    scope: scope || "mcp:tools",
    codeChallenge: code_challenge,
    codeChallengeMethod: code_challenge_method,
    expiresAt: Date.now() + 5 * 60 * 1000,
  });
  const url = new URL(redirect_uri);
  url.searchParams.set("code", code);
  if (state) url.searchParams.set("state", state);
  res.redirect(url.toString());
});

app.post("/token", async (req, res) => {
  try {
    const { grant_type, code, redirect_uri, client_id, code_verifier, client_assertion, client_assertion_type } = req.body;
    if (grant_type !== "authorization_code") return res.status(400).json({ error: "unsupported_grant_type" });

    const base = publicUrl(req);
    let authedId = null;

    if (client_assertion && client_assertion_type === "urn:ietf:params:oauth:client-assertion-type:jwt-bearer") {
      let decoded;
      try {
        decoded = JSON.parse(Buffer.from(client_assertion.split(".")[1], "base64url").toString());
      } catch (e) {
        return res.status(401).json({ error: "invalid_client", error_description: "bad assertion" });
      }
      const candidateId = decoded.iss || decoded.sub;
      const client = clients.get(candidateId);
      if (!client) return res.status(401).json({ error: "invalid_client", error_description: "unknown client" });
      try {
        let jwks;
        if (client.jwks?.keys?.length) jwks = createLocalJWKSet(client.jwks);
        else if (client.jwks_uri) jwks = getJwks(client.jwks_uri);
        else return res.status(401).json({ error: "invalid_client", error_description: "no jwks" });
        await jwtVerify(client_assertion, jwks, {
          issuer: candidateId, subject: candidateId, audience: `${base}/token`
        });
        authedId = candidateId;
      } catch (e) {
        console.error("assertion verify failed:", e.message);
        return res.status(401).json({ error: "invalid_client", error_description: e.message });
      }
    } else if (client_id) {
      const client = clients.get(client_id);
      if (!client) return res.status(401).json({ error: "invalid_client" });
      authedId = client_id;
    } else {
      return res.status(401).json({ error: "invalid_client" });
    }

    const auth = authCodes.get(code);
    if (!auth || auth.client_id !== authedId || auth.expiresAt < Date.now() || auth.redirect_uri !== redirect_uri) {
      return res.status(400).json({ error: "invalid_grant" });
    }
    if (auth.codeChallenge) {
      const computed = crypto.createHash("sha256").update(code_verifier || "").digest("base64url");
      if (computed !== auth.codeChallenge) return res.status(400).json({ error: "invalid_grant", error_description: "pkce mismatch" });
    }
    authCodes.delete(code);

    const accessToken = crypto.randomBytes(32).toString("hex");
    tokens.set(accessToken, { client_id: authedId, scope: auth.scope, expiresAt: Date.now() + 3600 * 1000 });

    res.json({
      access_token: accessToken,
      token_type: "Bearer",
      expires_in: 3600,
      scope: auth.scope,
    });
  } catch (e) {
    console.error("token error:", e);
    res.status(500).json({ error: "server_error" });
  }
});

app.post("/mcp", async (req, res) => {
  const auth = req.headers.authorization;
  if (!auth?.startsWith("Bearer ")) return res.status(401).json({ error: "unauthorized" });
  const token = auth.slice(7);
  const tok = tokens.get(token);
  if (!tok || tok.expiresAt < Date.now()) return res.status(401).json({ error: "invalid_token" });

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

app.listen(PORT, "127.0.0.1", () => {
  console.log(`MCP server on 127.0.0.1:${PORT}  mode=${ALLOW_UNRESTRICTED ? "UNRESTRICTED" : "restricted"}`);
});
MCPEOF

cat > stdio-server.mjs <<'STDIOEOF'
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";

const execAsync = promisify(exec);
const WORKDIR = path.join(os.homedir(), "mcp-work");
await fs.mkdir(WORKDIR, { recursive: true });
const SHELL = "/data/data/com.termux/files/usr/bin/bash";
const ISOLATED_SESSION = "mcp-ai";
const PROTECTED_SESSIONS = new Set(["mcp-server", "mcp-tunnel"]);
const WRITE_MAX_BYTES = 256 * 1024;
const WRITE_ALLOWED_EXT = new Set([
  ".txt", ".md", ".json", ".csv", ".log",
  ".yaml", ".yml", ".toml", ".ini", ".conf",
  ".html", ".css", ".xml", ".svg"
]);

function safePath(p = ".") {
  const base = path.resolve(WORKDIR);
  const target = path.resolve(base, p);
  if (target !== base && !target.startsWith(base + path.sep)) throw new Error("path escapes sandbox");
  return target;
}

function validSession(name) {
  return typeof name === "string" && /^[a-zA-Z0-9_-]{1,40}$/.test(name);
}

const server = new McpServer({ name: "termux", version: "2.0.0" });

server.tool("whoami", {}, async () => ({ content: [{ type: "text", text: os.userInfo().username || "unknown" }] }));
server.tool("pwd", {}, async () => ({ content: [{ type: "text", text: WORKDIR }] }));
server.tool("date", {}, async () => {
  const { stdout } = await execAsync("date '+%Y-%m-%d %H:%M:%S %Z (%A)'", { shell: SHELL });
  return { content: [{ type: "text", text: stdout.trim() }] };
});

server.tool("system_info", {}, async () => {
  const { stdout } = await execAsync("uname -a; echo; uptime; echo; df -h $HOME | tail -1; echo; free -m 2>/dev/null | head -2", { shell: SHELL });
  return { content: [{ type: "text", text: stdout }] };
});

server.tool("list_apps", {}, async () => {
  const { stdout } = await execAsync("pm list packages | sed 's/package://' | sort", { shell: SHELL });
  return { content: [{ type: "text", text: stdout }] };
});

server.tool("open_app", { package_name: z.string() }, async ({ package_name }) => {
  if (!/^[a-zA-Z0-9._]+$/.test(package_name)) return { content: [{ type: "text", text: "Invalid package name" }], isError: true };
  try {
    const { stdout, stderr } = await execAsync(`monkey -p ${package_name} -c android.intent.category.LAUNCHER 1`, { timeout: 10000, shell: SHELL });
    if (stdout.includes("No activities found") || stderr.includes("No activities found")) return { content: [{ type: "text", text: `App not found: ${package_name}` }], isError: true };
    return { content: [{ type: "text", text: `Launched ${package_name}` }] };
  } catch (e) {
    return { content: [{ type: "text", text: `Failed: ${e.message}` }], isError: true };
  }
});

server.tool("list_dir", { path: z.string().default(".") }, async ({ path: p }) => {
  const entries = await fs.readdir(safePath(p), { withFileTypes: true });
  return { content: [{ type: "text", text: entries.map(e => `${e.isDirectory() ? "d" : "-"} ${e.name}`).join("\n") || "(empty)" }] };
});

server.tool("read_file", { path: z.string() }, async ({ path: p }) => {
  return { content: [{ type: "text", text: (await fs.readFile(safePath(p), "utf8")).slice(-10000) }] };
});

server.tool("write_file",
  { path: z.string(), content: z.string(), mode: z.enum(["create", "overwrite"]).default("create") },
  async ({ path: p, content, mode }) => {
    const target = safePath(p);
    const ext = path.extname(target).toLowerCase();
    if (!WRITE_ALLOWED_EXT.has(ext)) return { content: [{ type: "text", text: `Extension not allowed: ${ext || "(none)"}` }], isError: true };
    if (Buffer.byteLength(content, "utf8") > WRITE_MAX_BYTES) return { content: [{ type: "text", text: "Too large" }], isError: true };
    if (content.startsWith("#!")) return { content: [{ type: "text", text: "Shebang not allowed" }], isError: true };
    let exists = false;
    try { await fs.access(target); exists = true; } catch {}
    if (exists && mode !== "overwrite") return { content: [{ type: "text", text: `File exists: ${target}` }], isError: true };
    if (exists) { try { await fs.copyFile(target, target + ".bak"); } catch {} }
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, content, "utf8");
    return { content: [{ type: "text", text: exists ? `overwrote ${target}` : `created ${target}` }] };
  }
);

server.tool("append_file", { path: z.string(), content: z.string() }, async ({ path: p, content }) => {
  const target = safePath(p);
  const ext = path.extname(target).toLowerCase();
  if (!WRITE_ALLOWED_EXT.has(ext)) return { content: [{ type: "text", text: `Extension not allowed: ${ext || "(none)"}` }], isError: true };
  if (Buffer.byteLength(content, "utf8") > WRITE_MAX_BYTES) return { content: [{ type: "text", text: "Too large" }], isError: true };
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.appendFile(target, content, "utf8");
  return { content: [{ type: "text", text: `appended to ${target}` }] };
});

server.tool("tmux", {
  action: z.enum(["list", "read", "send", "create", "kill", "attach"]),
  target: z.enum(["isolated", "session"]).default("isolated"),
  name: z.string().optional(),
  command: z.string().optional(),
  lines: z.number().optional(),
}, async ({ action, target, name, command, lines = 50 }) => {
  let session;
  if (target === "isolated") {
    session = ISOLATED_SESSION;
    try {
      await execAsync(`tmux has-session -t ${ISOLATED_SESSION} 2>/dev/null`, { shell: SHELL });
    } catch {
      await execAsync(`tmux new-session -d -s ${ISOLATED_SESSION}`, { shell: SHELL });
    }
  } else {
    if (!validSession(name)) return { content: [{ type: "text", text: "Invalid session name" }], isError: true };
    if (PROTECTED_SESSIONS.has(name)) return { content: [{ type: "text", text: "Session is protected" }], isError: true };
    session = name;
  }
  try {
    switch (action) {
      case "list": { const { stdout } = await execAsync("tmux ls 2>&1 || true", { shell: SHELL }); return { content: [{ type: "text", text: stdout.trim() || "(no sessions)" }] }; }
      case "read": { const { stdout } = await execAsync(`tmux capture-pane -t ${session} -p -S -${Math.min(lines, 500)}`, { shell: SHELL }); return { content: [{ type: "text", text: stdout.replace(/\s+$/g, "") || "(empty)" }] }; }
      case "attach": { return { content: [{ type: "text", text: `tmux attach -t ${session}` }] }; }
      case "create": {
        if (target === "session") {
          try { await execAsync(`tmux has-session -t ${session} 2>/dev/null`, { shell: SHELL }); }
          catch { await execAsync(`tmux new-session -d -s ${session}`, { shell: SHELL }); }
        }
        if (command) await execAsync(`tmux send-keys -t ${session} -l ${JSON.stringify(command)} && tmux send-keys -t ${session} Enter`, { shell: SHELL });
        return { content: [{ type: "text", text: `Ready: ${session}` }] };
      }
      case "send": { await execAsync(`tmux send-keys -t ${session} -l ${JSON.stringify(command || "")} && tmux send-keys -t ${session} Enter`, { shell: SHELL }); return { content: [{ type: "text", text: `Sent to ${session}` }] }; }
      case "kill": { await execAsync(`tmux kill-session -t ${session}`, { shell: SHELL }); return { content: [{ type: "text", text: `Killed ${session}` }] }; }
    }
  } catch (e) {
    return { content: [{ type: "text", text: `Failed: ${e.message}` }], isError: true };
  }
});

await server.connect(new StdioServerTransport());
STDIOEOF

cat > start.sh <<'STARTEOF'
#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp

if [ "$1" = "stop" ]; then
  tmux kill-session -t mcp-server 2>/dev/null
  tmux kill-session -t mcp-tunnel 2>/dev/null
  termux-wake-unlock 2>/dev/null
  echo "MCP stopped."
  exit 0
fi

MODE="restricted"
[ "$1" = "unrestricted" ] && MODE="unrestricted"

tmux kill-session -t mcp-server 2>/dev/null
tmux kill-session -t mcp-tunnel 2>/dev/null
rm -f tunnel.log
tmux new-session -d -s mcp-tunnel 'cloudflared tunnel --url http://127.0.0.1:8000 > ~/termux-mcp/tunnel.log 2>&1'

URL=""
for i in $(seq 1 30); do
  URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' tunnel.log 2>/dev/null | head -n1)
  [ -n "$URL" ] && break
  sleep 1
done

[ -z "$URL" ] && { echo "Failed to get tunnel URL. Check ~/termux-mcp/tunnel.log"; exit 1; }

export MCP_ALLOW_UNRESTRICTED=$([ "$MODE" = "unrestricted" ] && echo 1 || echo 0)
tmux new-session -d -s mcp-server "PUBLIC_URL='$URL' MCP_ALLOW_UNRESTRICTED=$MCP_ALLOW_UNRESTRICTED node /data/data/com.termux/files/home/termux-mcp/server.mjs"
sleep 2
echo "$URL" > ~/termux-mcp/.last_url

echo ""
echo "=============================================="
if [ "$MODE" = "unrestricted" ]; then
  echo "⚠️  Termux MCP — UNRESTRICTED MODE"
else
  echo "✓ Termux MCP running (restricted)"
fi
echo "=============================================="
echo "MCP URL:  $URL/mcp"
echo "Auth:     OAuth (Client ID + Secret blank)"
echo "Stop:     termux-mcp stop"
echo "=============================================="
STARTEOF

chmod +x start.sh

cat > test-stdio.sh <<'TESTEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | node ~/termux-mcp/stdio-server.mjs
TESTEOF
chmod +x test-stdio.sh

cat > $PREFIX/bin/termux-mcp <<'CMDEOF'
#!/data/data/com.termux/files/usr/bin/bash
bash ~/termux-mcp/start.sh "$@"
CMDEOF
chmod +x $PREFIX/bin/termux-mcp

cat > $PREFIX/bin/termux-mcp-stdio <<'CMDEOF'
#!/data/data/com.termux/files/usr/bin/bash
exec node ~/termux-mcp/stdio-server.mjs
CMDEOF
chmod +x $PREFIX/bin/termux-mcp-stdio

echo ""
echo "Commands:"
echo "  termux-mcp                    start (restricted)"
echo "  termux-mcp unrestricted       start (full access)"
echo "  termux-mcp stop               stop"
echo "  termux-mcp-stdio              local STDIO mode"
