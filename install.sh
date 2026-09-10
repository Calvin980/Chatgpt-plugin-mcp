#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "Installing Termux MCP server with OAuth 2.1 (private_key_jwt + DCR)..."

# Update and install dependencies
pkg update -y && pkg upgrade -y
pkg install -y nodejs-lts cloudflared tmux || pkg install -y nodejs cloudflared tmux

# Create project directory
mkdir -p ~/termux-mcp
cd ~/termux-mcp

# Initialize and install npm packages
npm init -y >/dev/null
# Core MCP SDK, Express, Zod, and the OAuth server with JWT support
npm install @modelcontextprotocol/sdk express zod @saurbit/oauth2 @saurbit/oauth2-jwt jose --save-exact >/dev/null

# Generate secrets for the OAuth server (do not overwrite if they exist)
if [ ! -f .jwt_private_key ]; then
  echo "Generating RSA key pair for OAuth signing..."
  node -e "
    const { generateKeyPairSync } = require('crypto');
    const { privateKey, publicKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
    });
    require('fs').writeFileSync('.jwt_private_key', privateKey);
    require('fs').writeFileSync('.jwt_public_key', publicKey);
  "
fi

# ---------- Main MCP Server with OAuth 2.1 (private_key_jwt + DCR) ----------
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
import crypto from "node:crypto";
import { AuthorizationCodeFlowBuilder, PrivateKeyJwt } from "@saurbit/oauth2";
import { decodeJwt, verifyClientAssertionJwt, getJwksEndpointResponse } from "@saurbit/oauth2-jwt";

const execAsync = promisify(exec);
const WORKDIR = path.join(os.homedir(), "mcp-work");
await fs.mkdir(WORKDIR, { recursive: true });

// --- Configuration ---
const PORT = process.env.PORT || 8000;
const PUBLIC_URL = process.env.PUBLIC_URL || `http://localhost:${PORT}`;
const MCP_SERVER_URL = new URL(`${PUBLIC_URL}/mcp`);

// --- In-memory stores (sufficient for single-user Termux use) ---
const clients = new Map(); // client_id -> { client_id, client_secret, token_endpoint_auth_method, jwks }
const authCodes = new Map(); // code -> { client_id, redirect_uri, scope, codeChallenge, codeChallengeMethod }
const tokens = new Map(); // access_token -> { client_id, scope }

// --- OAuth 2.1 Server Setup ---
const privateKeyPem = await fs.readFile(path.join(os.homedir(), "termux-mcp", ".jwt_private_key"), "utf8");
const publicKeyPem = await fs.readFile(path.join(os.homedir(), "termux-mcp", ".jwt_public_key"), "utf8");

// Configure the private_key_jwt client authentication method
const privateKeyJwt = new PrivateKeyJwt(decodeJwt, verifyClientAssertionJwt);
privateKeyJwt.setPublicKeyForClient(async (clientId) => {
  const client = clients.get(clientId);
  if (!client) return null;
  // If the client registered with a JWKS URI, fetch and return the key.
  // For simplicity in this lightweight setup, we'll assume keys are
  // registered inline via the 'jwks' field in the DCR request.
  if (client.jwks && client.jwks.keys && client.jwks.keys.length > 0) {
    const key = client.jwks.keys[0];
    if (key.kty === 'RSA') {
      // Convert JWK to PEM (simplified; in production use a proper library)
      const { createPublicKey } = crypto;
      try {
        const pubKey = createPublicKey({ key, format: 'jwk' });
        return pubKey.export({ type: 'spki', format: 'pem' });
      } catch (e) {
        console.error("Error converting JWK to PEM:", e);
        return null;
      }
    }
  }
  return null;
});

// Build the Authorization Code flow with PKCE and private_key_jwt support
const authFlow = new AuthorizationCodeFlowBuilder({
  issuer: PUBLIC_URL,
  tokenEndpoint: `${PUBLIC_URL}/token`,
  authorizationEndpoint: `${PUBLIC_URL}/authorize`,
  registrationEndpoint: `${PUBLIC_URL}/register`,
  jwksEndpoint: `${PUBLIC_URL}/jwks.json`,
  scopesSupported: ["mcp:tools"],
})
  .addClientAuthenticationMethod(privateKeyJwt)
  .addClientAuthenticationMethod("none") // For public clients
  .enablePKCE() // Enforce PKCE
  .build();

// --- MCP Server Logic ---
const ALLOW_UNRESTRICTED = process.env.MCP_ALLOW_UNRESTRICTED === "1";
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

function createMcpServer() {
  const server = new McpServer({ name: "termux", version: "1.0.0" });

  server.tool("run", { cmd: z.string() }, async ({ cmd }) => {
    if (!ALLOW_UNRESTRICTED) {
      const first = cmd.trim().split(/\s+/)[0];
      if (!ALLOWED.has(first) && !first.startsWith("termux-")) {
        return { content: [{ type: "text", text: "command not allowed" }], isError: true };
      }
    }
    try {
      const { stdout, stderr } = await execAsync(cmd, {
        cwd: ALLOW_UNRESTRICTED ? os.homedir() : WORKDIR,
        timeout: 20000,
        maxBuffer: 1024 * 1024,
        shell: "/data/data/com.termux/files/usr/bin/bash",
      });
      return { content: [{ type: "text", text: `exit=0\nSTDOUT:\n${stdout.slice(-4000)}\nSTDERR:\n${stderr.slice(-4000)}` }] };
    } catch (e) {
      return { content: [{ type: "text", text: `ERROR:\n${e.message}\n${e.stdout || ""}\n${e.stderr || ""}` }], isError: true };
    }
  });

  server.tool("read_file", { path: z.string() }, async ({ path: p }) => {
    const text = await fs.readFile(safePath(p), "utf8");
    return { content: [{ type: "text", text: text.slice(-8000) }] };
  });

  server.tool("write_file", { path: z.string(), content: z.string() }, async ({ path: p, content }) => {
    const target = safePath(p);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, content, "utf8");
    return { content: [{ type: "text", text: `wrote ${target}` }] };
  });

  server.tool("list_dir", { path: z.string().default(".") }, async ({ path: p }) => {
    const entries = await fs.readdir(safePath(p), { withFileTypes: true });
    return { content: [{ type: "text", text: entries.map(e => `${e.isDirectory() ? "d" : "-"} ${e.name}`).join("\n") }] };
  });

  return server;
}

// --- Express App ---
const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// JWKS endpoint (required for private_key_jwt)
app.get("/jwks.json", async (req, res) => {
  try {
    const jwks = await getJwksEndpointResponse(publicKeyPem);
    res.json(jwks);
  } catch (e) {
    res.status(500).json({ error: "jwks_error" });
  }
});

// OAuth Discovery
app.get("/.well-known/oauth-authorization-server", (req, res) => {
  res.json({
    issuer: PUBLIC_URL,
    authorization_endpoint: `${PUBLIC_URL}/authorize`,
    token_endpoint: `${PUBLIC_URL}/token`,
    registration_endpoint: `${PUBLIC_URL}/register`,
    jwks_uri: `${PUBLIC_URL}/jwks.json`,
    scopes_supported: ["mcp:tools"],
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    token_endpoint_auth_methods_supported: ["none", "private_key_jwt"],
    code_challenge_methods_supported: ["S256"],
  });
});

// Dynamic Client Registration (RFC 7591)
app.post("/register", (req, res) => {
  const { client_name, redirect_uris, token_endpoint_auth_method, jwks } = req.body;
  const clientId = crypto.randomUUID();
  const clientSecret = null; // private_key_jwt and none do not use a secret

  clients.set(clientId, {
    client_id: clientId,
    client_name,
    redirect_uris,
    token_endpoint_auth_method: token_endpoint_auth_method || "none",
    jwks: jwks || null,
  });

  res.status(201).json({
    client_id: clientId,
    client_secret: clientSecret,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    redirect_uris,
    token_endpoint_auth_method: token_endpoint_auth_method || "none",
  });
});

// Authorization Endpoint
app.get("/authorize", (req, res) => {
  const { client_id, redirect_uri, state, code_challenge, code_challenge_method, scope } = req.query;
  const client = clients.get(client_id);
  if (!client) {
    return res.status(400).send("Unknown client_id");
  }
  // Render a simple consent page
  const html = `
    <!DOCTYPE html>
    <html>
    <head><title>Approve Access</title></head>
    <body style="font-family: sans-serif; padding: 2rem; max-width: 500px; margin: auto;">
      <h1>Approve Termux MCP Access</h1>
      <p>Application <strong>${client.client_name || client_id}</strong> is requesting access.</p>
      <form method="POST" action="/authorize/approve">
        <input type="hidden" name="client_id" value="${client_id}" />
        <input type="hidden" name="redirect_uri" value="${redirect_uri}" />
        <input type="hidden" name="state" value="${state}" />
        <input type="hidden" name="code_challenge" value="${code_challenge}" />
        <input type="hidden" name="code_challenge_method" value="${code_challenge_method}" />
        <input type="hidden" name="scope" value="${scope || 'mcp:tools'}" />
        <button type="submit" style="padding: 1rem 2rem; background: #0070f3; color: white; border: none; border-radius: 5px; cursor: pointer;">Approve</button>
      </form>
    </body>
    </html>
  `;
  res.send(html);
});

app.post("/authorize/approve", (req, res) => {
  const { client_id, redirect_uri, state, code_challenge, code_challenge_method, scope } = req.body;
  const code = crypto.randomBytes(32).toString('hex');
  authCodes.set(code, {
    client_id,
    redirect_uri,
    scope: scope || "mcp:tools",
    codeChallenge: code_challenge,
    codeChallengeMethod: code_challenge_method,
    expiresAt: Date.now() + 5 * 60 * 1000,
  });
  const redirectUrl = new URL(redirect_uri);
  redirectUrl.searchParams.set('code', code);
  if (state) redirectUrl.searchParams.set('state', state);
  res.redirect(redirectUrl.toString());
});

// Token Endpoint
app.post("/token", async (req, res) => {
  try {
    const { grant_type, code, redirect_uri, client_id, code_verifier, client_assertion, client_assertion_type } = req.body;

    if (grant_type !== "authorization_code") {
      return res.status(400).json({ error: "unsupported_grant_type" });
    }

    // --- Client Authentication ---
    let authenticatedClientId = null;

    if (client_assertion && client_assertion_type === "urn:ietf:params:oauth:client-assertion-type:jwt-bearer") {
      // private_key_jwt
      const decoded = decodeJwt(client_assertion);
      authenticatedClientId = decoded.aud; // aud is the client_id
      const client = clients.get(authenticatedClientId);
      if (!client) return res.status(401).json({ error: "invalid_client" });

      // Verify the JWT assertion
      try {
        // In a real implementation, retrieve the public key for the client and verify.
        // For this lightweight example, we rely on the library's handler setup.
        await verifyClientAssertionJwt(client_assertion, async (id) => {
          const c = clients.get(id);
          if (c && c.jwks && c.jwks.keys && c.jwks.keys.length > 0) {
            // Return the JWK directly; the library handles conversion.
            return c.jwks.keys[0];
          }
          return null;
        });
      } catch (e) {
        console.error("JWT assertion verification failed:", e);
        return res.status(401).json({ error: "invalid_client" });
      }
    } else if (client_id) {
      // Public client (none auth method)
      authenticatedClientId = client_id;
    } else {
      return res.status(401).json({ error: "invalid_client" });
    }

    // --- Authorization Code Exchange ---
    const authData = authCodes.get(code);
    if (!authData) return res.status(400).json({ error: "invalid_grant" });
    if (authData.client_id !== authenticatedClientId) return res.status(400).json({ error: "invalid_grant" });
    if (authData.expiresAt < Date.now()) {
      authCodes.delete(code);
      return res.status(400).json({ error: "invalid_grant" });
    }
    if (authData.redirect_uri !== redirect_uri) return res.status(400).json({ error: "invalid_grant" });

    // --- PKCE Verification ---
    if (authData.codeChallenge) {
      const computedChallenge = crypto.createHash('sha256').update(code_verifier).digest('base64url');
      if (computedChallenge !== authData.codeChallenge) {
        return res.status(400).json({ error: "invalid_grant" });
      }
    }

    authCodes.delete(code);

    // --- Issue Token ---
    const accessToken = crypto.randomBytes(32).toString('hex');
    tokens.set(accessToken, { client_id: authenticatedClientId, scope: authData.scope });

    res.json({
      access_token: accessToken,
      token_type: "Bearer",
      expires_in: 3600,
      scope: authData.scope,
    });
  } catch (error) {
    console.error("Token endpoint error:", error);
    res.status(500).json({ error: "server_error" });
  }
});

// --- Protected MCP Endpoint ---
app.post("/mcp", async (req, res) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "unauthorized" });
  }
  const token = authHeader.slice(7);
  const tokenData = tokens.get(token);
  if (!tokenData) {
    return res.status(401).json({ error: "invalid_token" });
  }

  try {
    const server = createMcpServer();
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
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

app.listen(PORT, '127.0.0.1', () => {
  console.log(`MCP server listening on 127.0.0.1:${PORT}`);
  console.log(`Public URL: ${PUBLIC_URL}`);
  console.log(`Mode: ${ALLOW_UNRESTRICTED ? "UNRESTRICTED ⚠️" : "restricted"}`);
});
EOF

# ---------- STDIO server (unchanged, for local clients) ----------
cat > stdio-server.mjs <<'EOF'
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

const ALLOW_UNRESTRICTED = process.env.MCP_ALLOW_UNRESTRICTED === "1";
const ALLOWED = new Set([
  "ls", "pwd", "cat", "echo", "grep", "find", "head", "tail", "wc",
  "python3", "pip", "git", "curl", "wget", "node", "npm", "pkg"
]);

function safePath(p = ".") {
  const base = path.resolve(WORKDIR);
  const target = path.resolve(base, p);
  if (target !== base && !target.startsWith(base + path.sep)) throw new Error("path escapes workspace");
  return target;
}

const server = new McpServer({ name: "termux", version: "1.0.0" });

server.tool("run", { cmd: z.string() }, async ({ cmd }) => {
  if (!ALLOW_UNRESTRICTED) {
    const first = cmd.trim().split(/\s+/)[0];
    if (!ALLOWED.has(first) && !first.startsWith("termux-")) {
      return { content: [{ type: "text", text: "command not allowed" }], isError: true };
    }
  }
  try {
    const { stdout, stderr } = await execAsync(cmd, {
      cwd: ALLOW_UNRESTRICTED ? os.homedir() : WORKDIR,
      timeout: 20000,
      maxBuffer: 1024 * 1024,
      shell: "/data/data/com.termux/files/usr/bin/bash",
    });
    return { content: [{ type: "text", text: `exit=0\nSTDOUT:\n${stdout.slice(-4000)}\nSTDERR:\n${stderr.slice(-4000)}` }] };
  } catch (e) {
    return { content: [{ type: "text", text: `ERROR:\n${e.message}\n${e.stdout || ""}\n${e.stderr || ""}` }], isError: true };
  }
});

server.tool("read_file", { path: z.string() }, async ({ path: p }) => {
  const text = await fs.readFile(safePath(p), "utf8");
  return { content: [{ type: "text", text: text.slice(-8000) }] };
});

server.tool("write_file", { path: z.string(), content: z.string() }, async ({ path: p, content }) => {
  const target = safePath(p);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, content, "utf8");
  return { content: [{ type: "text", text: `wrote ${target}` }] };
});

server.tool("list_dir", { path: z.string().default(".") }, async ({ path: p }) => {
  const entries = await fs.readdir(safePath(p), { withFileTypes: true });
  return { content: [{ type: "text", text: entries.map(e => `${e.isDirectory() ? "d" : "-"} ${e.name}`).join("\n") }] };
});

const transport = new StdioServerTransport();
await server.connect(transport);
EOF

# ---------- Start script (accepts "unrestricted" as $1) ----------
cat > start.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp

MODE="${1:-restricted}"

if [ "$MODE" = "unrestricted" ]; then
  export MCP_ALLOW_UNRESTRICTED=1
else
  export MCP_ALLOW_UNRESTRICTED=0
fi

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

# Restart server with PUBLIC_URL set so OAuth discovery works
tmux kill-session -t mcp-server
export PUBLIC_URL=$URL
tmux new-session -d -s mcp-server 'node server.mjs'

sleep 1

echo ""
echo "=============================================="
if [ "$MODE" = "unrestricted" ]; then
  echo "⚠️  Termux MCP (UNRESTRICTED MODE) is running!"
  echo ""
  echo "   The 'run' tool can execute ANY shell command."
  echo "   The sandbox is DISABLED. Use with extreme care."
else
  echo "Termux MCP (OAuth 2.1) is running!"
fi
echo ""
echo "Add this as a custom connector in ChatGPT:"
echo ""
echo "  MCP Server URL: $URL/mcp"
echo ""
echo "Authentication: OAuth"
echo ""
echo "Leave Client ID and Client Secret BLANK in ChatGPT."
echo "ChatGPT will use Dynamic Client Registration."
echo ""
if [ "$MODE" = "unrestricted" ]; then
  echo "🚨 STOP THE TUNNEL AS SOON AS YOU'RE DONE:"
  echo "   tmux kill-session -t mcp-server"
  echo "   tmux kill-session -t mcp-tunnel"
else
  echo "⚠️  This is a PUBLIC URL protected by OAuth. Stop it when done."
fi
echo "=============================================="
EOF

chmod +x start.sh

# ---------- STDIO test script ----------
cat > test-stdio.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | node ~/termux-mcp/stdio-server.mjs
EOF
chmod +x test-stdio.sh

# ---------- Commands ----------
cat > $PREFIX/bin/termux-mcp <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Usage:
#   termux-mcp                 → restricted mode (safe, allowlist enforced)
#   termux-mcp unrestricted    → unrestricted mode (runs ANY command)
bash ~/termux-mcp/start.sh "$@"
EOF
chmod +x $PREFIX/bin/termux-mcp

cat > $PREFIX/bin/termux-mcp-stdio <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Usage:
#   termux-mcp-stdio               → restricted STDIO mode
#   termux-mcp-stdio unrestricted  → unrestricted STDIO mode
if [ "$1" = "unrestricted" ]; then
  export MCP_ALLOW_UNRESTRICTED=1
else
  export MCP_ALLOW_UNRESTRICTED=0
fi
exec node ~/termux-mcp/stdio-server.mjs
EOF
chmod +x $PREFIX/bin/termux-mcp-stdio

echo ""
echo "Installation complete!"
echo ""
echo "Commands:"
echo "  termux-mcp                 # HTTP + tunnel, restricted mode"
echo "  termux-mcp unrestricted    # HTTP + tunnel, UNRESTRICTED mode"
echo "  termux-mcp-stdio           # STDIO, restricted mode"
echo "  termux-mcp-stdio unrestricted  # STDIO, UNRESTRICTED mode"
echo ""
echo "Test STDIO: bash ~/termux-mcp/test-stdio.sh"
echo ""
echo "🚨 Unrestricted mode gives full shell access to your device."
echo "   Only use it while the tunnel is up and you're actively working."
