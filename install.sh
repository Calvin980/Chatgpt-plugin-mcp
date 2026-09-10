#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "Installing Termux MCP server..."

pkg update -y && pkg upgrade -y
pkg install -y nodejs-lts cloudflared tmux || pkg install -y nodejs cloudflared tmux

mkdir -p ~/termux-mcp
cd ~/termux-mcp

npm init -y >/dev/null
npm install @modelcontextprotocol/sdk express zod >/dev/null

# Generate secrets
if [ ! -f .secret ]; then
  head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32 > .secret
fi
if [ ! -f .auth_token ]; then
  head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32 > .auth_token
fi

cat > server.mjs <<'EOF'
import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";

const execAsync = promisify(exec);
const WORKDIR = path.join(os.homedir(), "mcp-work");
await fs.mkdir(WORKDIR, { recursive: true });

const SECRET = process.env.MCP_SECRET;
const AUTH_TOKEN = process.env.MCP_AUTH_TOKEN;
const ALLOW_UNRESTRICTED = process.env.MCP_ALLOW_UNRESTRICTED === "1";

if (!SECRET) {
  console.error("MCP_SECRET not set");
  process.exit(1);
}

const ALLOWED = new Set([
  "ls", "pwd", "cat", "echo", "grep", "find", "head", "tail", "wc",
  "python3", "pip", "git", "curl", "wget", "node", "npm", "pkg"
]);

function safePath(p = ".") {
  const base = path.resolve(WORKDIR);
  const target = path.resolve(base, p);
  if (target !== base && !target.startsWith(base + path.sep)) {
    throw new Error("path escapes workspace");
  }
  return target;
}

function makeServer() {
  const server = new McpServer({ name: "termux", version: "1.0.0" });

  server.tool(
    "run",
    { cmd: z.string().describe("Shell command to run in ~/mcp-work") },
    async ({ cmd }) => {
      if (!ALLOW_UNRESTRICTED) {
        const first = cmd.trim().split(/\s+/)[0];
        if (!ALLOWED.has(first) && !first.startsWith("termux-")) {
          return {
            content: [{ type: "text", text: "command not allowed" }],
            isError: true
          };
        }
      }

      try {
        const { stdout, stderr } = await execAsync(cmd, {
          cwd: WORKDIR,
          timeout: 20000,
          maxBuffer: 1024 * 1024,
          shell: "/data/data/com.termux/files/usr/bin/bash",
        });
        return {
          content: [{
            type: "text",
            text: `exit=0\nSTDOUT:\n${stdout.slice(-4000)}\nSTDERR:\n${stderr.slice(-4000)}`
          }]
        };
      } catch (e) {
        return {
          content: [{
            type: "text",
            text: `ERROR:\n${e.message}\n${e.stdout || ""}\n${e.stderr || ""}`
          }],
          isError: true
        };
      }
    }
  );

  server.tool(
    "read_file",
    { path: z.string() },
    async ({ path: p }) => {
      const text = await fs.readFile(safePath(p), "utf8");
      return { content: [{ type: "text", text: text.slice(-8000) }] };
    }
  );

  server.tool(
    "write_file",
    { path: z.string(), content: z.string() },
    async ({ path: p, content }) => {
      const target = safePath(p);
      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.writeFile(target, content, "utf8");
      return { content: [{ type: "text", text: `wrote ${target}` }] };
    }
  );

  server.tool(
    "list_dir",
    { path: z.string().default(".") },
    async ({ path: p }) => {
      const entries = await fs.readdir(safePath(p), { withFileTypes: true });
      return {
        content: [{
          type: "text",
          text: entries.map(e => `${e.isDirectory() ? "d" : "-"} ${e.name}`).join("\n")
        }]
      };
    }
  );

  return server;
}

const app = express();
app.use(express.json());

app.post(`/mcp/${SECRET}`, async (req, res) => {
  if (AUTH_TOKEN) {
    const auth = req.headers.authorization;
    if (auth !== `Bearer ${AUTH_TOKEN}`) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
  }

  try {
    const server = makeServer();
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
    });

    res.on("close", () => {
      transport.close();
      server.close();
    });

    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (err) {
    console.error(err);
    if (!res.headersSent) res.status(500).json({ error: "MCP error" });
  }
});

app.listen(8000, "127.0.0.1", () => {
  console.log("MCP server listening on 127.0.0.1:8000");
});
EOF

cat > start.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp
export MCP_SECRET=$(cat .secret)
export MCP_AUTH_TOKEN=$(cat .auth_token 2>/dev/null || true)
# Set to 1 if you want unrestricted shell (dangerous):
export MCP_ALLOW_UNRESTRICTED=0

tmux kill-session -t mcp-server 2>/dev/null
tmux kill-session -t mcp-tunnel 2>/dev/null

tmux new-session -d -s mcp-server 'node server.mjs'

rm -f ~/termux-mcp/tunnel.log
tmux new-session -d -s mcp-tunnel 'cloudflared tunnel --url http://127.0.0.1:8000 > ~/termux-mcp/tunnel.log 2>&1'

URL=""
for i in $(seq 1 30); do
  URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' ~/termux-mcp/tunnel.log | head -n1)
  [ -n "$URL" ] && break
  sleep 1
done

if [ -z "$URL" ]; then
  echo "Failed to get tunnel URL. Check ~/termux-mcp/tunnel.log"
  exit 1
fi

echo ""
echo "=============================================="
echo "Termux MCP is running!"
echo "Add this as a custom connector in ChatGPT:"
echo ""
echo "  $URL/mcp/$(cat ~/termux-mcp/.secret)"
echo ""
echo "Optional auth token (if ChatGPT supports headers):"
echo "  Authorization: Bearer $(cat ~/termux-mcp/.auth_token)"
echo ""
echo "To stop:"
echo "  tmux kill-session -t mcp-server"
echo "  tmux kill-session -t mcp-tunnel"
echo "=============================================="
EOF

chmod +x start.sh

cat > $PREFIX/bin/termux-mcp <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
bash ~/termux-mcp/start.sh
EOF
chmod +x $PREFIX/bin/termux-mcp

echo ""
echo "Installation complete!"
echo "Run: termux-mcp"
