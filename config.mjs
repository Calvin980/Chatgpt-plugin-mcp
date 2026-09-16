import os from "node:os";
import path from "node:path";

export const HOME = os.homedir();
export const DATA_DIR = process.env.MCP_DATA_DIR || path.join(HOME, "termux-mcp");
export const WORKDIR = path.join(HOME, "mcp-work");

export const SHELL = "/data/data/com.termux/files/usr/bin/bash";
export const PORT = process.env.PORT || 8000;

export const ALLOW_UNRESTRICTED = process.env.MCP_ALLOW_UNRESTRICTED === "1";

// PUBLIC_URL: required unless running in test mode.
// start.sh sets it. Test files set MCP_TEST=1 to skip the check.
export const PUBLIC_URL = process.env.PUBLIC_URL;
if (!PUBLIC_URL) {
  if (process.env.MCP_TEST === "1") {
    process.env.PUBLIC_URL = `http://127.0.0.1:${PORT}`;
  } else {
    console.error("");
    console.error("ERROR: PUBLIC_URL is not set.");
    console.error("");
    console.error("This is required for OAuth metadata to work.");
    console.error("If you started the server manually, set it:");
    console.error("");
    console.error("  PUBLIC_URL=https://your-machine.ts.net node server.mjs");
    console.error("");
    console.error("If you used termux-mcp, this is a bug. Please report it.");
    console.error("");
    process.exit(1);
  }
}

export const ISOLATED_SESSION = "mcp-ai";
export const ISOLATED_HOME = path.join(HOME, "mcp-ai-home");
export const PROTECTED_SESSIONS = new Set(["mcp-server", "mcp-tunnel"]);

export const T_FAST = 3000;
export const T_MED = 5000;
export const T_SLOW = 10000;

export const WRITE_MAX_BYTES = 128 * 1024;
export const WRITE_ALLOWED_EXT = new Set([
  ".txt", ".md", ".json", ".csv", ".log",
  ".yaml", ".yml", ".toml", ".ini", ".conf",
  ".html", ".css", ".xml", ".svg"
]);

export const TOKEN_TTL_MS = 30 * 60 * 1000;
export const REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000;

export const MAX_REGISTERED_CLIENTS = 20;
export const MAX_PENDING_AUTH_CODES = 50;
export const TOTP_MAX_FAILURES = 5;
export const TOTP_LOCKOUT_MS = 15 * 60 * 1000;

export const ALLOWED_REDIRECT_HOSTS = [
  "chatgpt.com",
  "chat.openai.com",
  "openai.com",
  "claude.ai",
  "anthropic.com",
  "localhost",
  "127.0.0.1"
];
