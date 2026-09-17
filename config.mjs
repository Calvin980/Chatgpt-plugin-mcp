import os from "node:os";
import fs from "node:fs";
import path from "node:path";

export const HOME = os.homedir();
export const DATA_DIR = process.env.MCP_DATA_DIR || path.join(HOME, "termux-mcp");
export const WORKDIR = path.join(HOME, "mcp-work");

export const SHELL = "/data/data/com.termux/files/usr/bin/bash";
export const PORT = process.env.PORT || 8000;

export const ALLOW_UNRESTRICTED = process.env.MCP_ALLOW_UNRESTRICTED === "1";

// ---------- config.json ----------
const CONFIG_FILE = path.join(DATA_DIR, "config.json");
let userConfig = {};
try {
  userConfig = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
} catch (e) {
  if (e.code !== "ENOENT") {
    console.error(`[config] Failed to load config.json: ${e.message}`);
  }
}

function cfg(key, fallback) {
  return userConfig[key] !== undefined ? userConfig[key] : fallback;
}

// ---------- PUBLIC_URL ----------
export const PUBLIC_URL = process.env.PUBLIC_URL;
if (!PUBLIC_URL) {
  if (process.env.MCP_TEST === "1") {
    process.env.PUBLIC_URL = `http://127.0.0.1:${PORT}`;
  } else {
    console.error("ERROR: PUBLIC_URL is not set.");
    process.exit(1);
  }
}

// ---------- Sessions ----------
export const ISOLATED_SESSION = "mcp-ai";
export const ISOLATED_HOME = path.join(HOME, "mcp-ai-home");
export const PROTECTED_SESSIONS = new Set(["mcp-server", "mcp-tunnel"]);

// ---------- Timeouts ----------
export const T_FAST = cfg("timeout_fast_ms", 3000);
export const T_MED = cfg("timeout_med_ms", 5000);
export const T_SLOW = cfg("timeout_slow_ms", 10000);

// ---------- File tools ----------
export const WRITE_MAX_BYTES = cfg("write_max_bytes", 128 * 1024);
export const WRITE_ALLOWED_EXT = new Set(cfg("write_allowed_ext", [
  ".txt", ".md", ".json", ".csv", ".log",
  ".yaml", ".yml", ".toml", ".ini", ".conf",
  ".html", ".css", ".xml", ".svg"
]));

// ---------- Auth ----------
export const TOKEN_TTL_MS = cfg("token_ttl_ms", 30 * 60 * 1000);
export const REFRESH_TTL_MS = cfg("refresh_ttl_ms", 30 * 24 * 60 * 60 * 1000);
export const MAX_REGISTERED_CLIENTS = cfg("max_clients", 20);
export const MAX_PENDING_AUTH_CODES = cfg("max_pending_codes", 50);
export const TOTP_MAX_FAILURES = cfg("totp_max_failures", 5);
export const TOTP_LOCKOUT_MS = cfg("totp_lockout_ms", 15 * 60 * 1000);

export const ALLOWED_REDIRECT_HOSTS = cfg("allowed_redirect_hosts", [
  "chatgpt.com", "chat.openai.com", "openai.com",
  "claude.ai", "anthropic.com", "localhost", "127.0.0.1"
]);

// ---------- Rate limits ----------
export const RATE_LIMITS = cfg("rate_limits", {
  register: { max: 5, window_ms: 60_000 },
  authorize: { max: 20, window_ms: 60_000 },
  approve: { max: 10, window_ms: 60_000 },
  token: { max: 20, window_ms: 60_000 },
  revoke: { max: 20, window_ms: 60_000 },
  mcp: { max: 120, window_ms: 60_000 }
});

// ---------- Idle session ----------
export const IDLE_TIMEOUT_MS = cfg("idle_timeout_ms", 30 * 60 * 1000);
export const IDLE_CHECK_INTERVAL_MS = cfg("idle_check_interval_ms", 5 * 60 * 1000);
export const ACTIVITY_FILE = path.join(DATA_DIR, ".mcp_ai_last_activity");

// ---------- Home sandbox ----------
export const ALLOWED_HOME_SUBPATHS = cfg("allowed_home_subpaths", [
  "mcp-work", "mcp-ai-home", "termux-mcp"
]);

export const LEGACY_DENIED_PATHS = [
  ".ssh", ".aws", ".netrc", ".git-credentials", ".config/gh",
  ".consent_password", ".tunnel_config", ".unlocked_until",
  "termux-mcp/state/", ".cloudflared/", ".password-store", ".gnupg",
  ".bash_history", ".zsh_history", ".npmrc", ".pypirc",
  ".docker/config.json", ".kube/config", ".env", ".git/config",
  "id_rsa", "id_ed25519", "id_ecdsa", "authorized_keys",
  ".termux/", ".termux_authinfo", ".ssh_keys", ".totp_secret",
  ".totp_recovery", "server.mjs", "start.sh", "config.mjs", "oauth.mjs",
  "tools.mjs", "http.mjs", "audit.mjs", "state.mjs", "lib.mjs"
];

// ============================================================
// NEW: Security constants
// ============================================================

// ---------- SSRF guard ----------
// Hostnames and IP ranges the tmux sanitizer refuses to target.
export const SSRF_BLOCKED_HOSTS = cfg("ssrf_blocked_hosts", [
  "169.254.169.254",         // AWS/GCP/Azure metadata
  "metadata.google.internal",
  "metadata",
  "100.100.100.200",         // Alibaba metadata
  "192.0.0.192",             // Oracle Cloud metadata
  "0.0.0.0", "::1", "::",
  "localhost", "localhost.localdomain"
]);

export const SSRF_BLOCKED_CIDRS = cfg("ssrf_blocked_cidrs", [
  "127.0.0.0/8",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16",
  "169.254.0.0/16",
  "100.64.0.0/10",           // CGNAT
  "fc00::/7", "fe80::/10"    // IPv6 private
]);

// ---------- Command substitution ----------
// Block $() and backticks even in unrestricted mode. Prevents
// shell-injection-style escapes around the path blocklist.
export const BLOCK_SUBSTITUTION_UNRESTRICTED = cfg("block_substitution_unrestricted", true);

// ---------- CSRF ----------
export const CSRF_ENABLED = cfg("csrf_enabled", true);
export const CSRF_TTL_MS = cfg("csrf_ttl_ms", 5 * 60 * 1000);

// ---------- Tool integrity ----------
export const TOOL_INTEGRITY_FILE = path.join(DATA_DIR, ".tools_hash");

// ---------- Audit rotation ----------
export const AUDIT_MAX_BYTES = cfg("audit_max_bytes", 10 * 1024 * 1024);  // 10 MB
export const AUDIT_KEEP_ROTATIONS = cfg("audit_keep_rotations", 5);

// ---------- Per-client TTL overrides ----------
export const CLIENT_TTL_OVERRIDES = cfg("client_ttl_overrides", {});

// ---------- Escape sequence stripping ----------
// Strips ANSI escape codes from tmux read output.
export const STRIP_ESCAPES = cfg("strip_escapes", true);
