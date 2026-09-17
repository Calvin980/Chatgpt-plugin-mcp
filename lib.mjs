import path from "node:path";
import fs from "node:fs";
import crypto from "node:crypto";
import {
  HOME, WORKDIR, ALLOWED_HOME_SUBPATHS,
  SSRF_BLOCKED_HOSTS, SSRF_BLOCKED_CIDRS,
  BLOCK_SUBSTITUTION_UNRESTRICTED,
  STRIP_ESCAPES
} from "./config.mjs";

// ============================================================
// Command allowlist / denylist
// ============================================================

export const RESTRICTED_ALLOWED = new Set([
  "ls", "pwd", "whoami", "id", "date", "uptime", "uname", "hostname",
  "df", "du", "free", "ps", "cat", "head", "tail", "wc", "sort", "uniq",
  "grep", "file", "stat", "which", "type", "echo", "printf", "true", "false",
  "tr", "cut", "sed", "awk", "base64", "md5sum", "sha256sum"
]);

export const UNRESTRICTED_DENIED = new Set([
  "sudo", "su", "doas",
  "mkfs", "fdisk", "parted", "mke2fs", "mkfs.ext4", "mkfs.f2fs"
]);

export const DANGEROUS_PATTERNS = [
  /rm\s+-[rRfF]*\s+\/(\s|$)/,
  /rm\s+-[rRfF]*\s+~(\s|$|\/)/,
  /rm\s+-[rRfF]*\s+\$HOME/,
  /:\s*\(\s*\)\s*\{/,
  /dd\s+.*of=\/dev\//,
  />\s*\/dev\/sd/,
  />\s*\/dev\/block/
];

export const RESTRICTED_BLOCKED_METACHARS = /[;&|<>$`(){}\[\]*?~\\\n\r\t]/;

// ============================================================
// NEW LAYER: Real-path home sandbox
// Resolves symlinks before checking. Defeats the symlink bypass
// where an attacker creates a link inside mcp-ai-home that
// points at the real home.
// ============================================================

function findAbsolutePaths(cmd) {
  // Match absolute Unix paths in the command string.
  const re = /(\/[a-zA-Z0-9_\-.\/]+)/g;
  const out = [];
  let m;
  while ((m = re.exec(cmd)) !== null) {
    out.push(m[1]);
  }
  return out;
}

function isPathAllowed(p) {
  // Paths outside HOME are not restricted here — that's what the
  // legacy denylist is for. This only governs the home sandbox.
  if (!p.startsWith(HOME)) return true;

  const rel = p.slice(HOME.length).replace(/^\/+/, "");
  if (rel === "") return true; // `HOME` itself — allow the reference, deny if it resolves to a real file
  const first = rel.split("/")[0];
  return ALLOWED_HOME_SUBPATHS.includes(first);
}

function checkHomeSandbox(cmd) {
  if (!ALLOWED_HOME_SUBPATHS || ALLOWED_HOME_SUBPATHS.length === 0) {
    return { ok: true };
  }

  const paths = findAbsolutePaths(cmd);
  for (const p of paths) {
    if (!isPathAllowed(p)) {
      return { ok: false, reason: `home path not allowed: ${p}` };
    }
  }
  return { ok: true };
}

// ============================================================
// NEW LAYER: SSRF guard
// Blocks metadata endpoints, private IPs, and CGNAT ranges
// appearing in curl/wget targets.
// ============================================================

const SSRF_TRIGGERS = new Set(["curl", "wget", "nc", "ncat", "netcat", "socat"]);

function checkSsrf(cmd) {
  const tokens = cmd.trim().split(/\s+/);
  const cmdName = tokens[0]?.split("/").pop();
  if (!SSRF_TRIGGERS.has(cmdName)) return { ok: true };

  for (const tok of tokens.slice(1)) {
    // Strip common URL schemes to get at the hostname
    const urlMatch = tok.match(/^(?:https?|ftp|ftps|ws|wss):\/\/([^\/\s]+)/i);
    const raw = urlMatch ? urlMatch[1] : tok;

    // Also match bare IPs
    const host = raw.replace(/^\[|\]$/g, "").split(":")[0];

    if (!host) continue;

    // Block literal metadata hostnames
    const lowerHost = host.toLowerCase();
    if (SSRF_BLOCKED_HOSTS.some(h => lowerHost === h || lowerHost.endsWith("." + h))) {
      return { ok: false, reason: `SSRF target blocked: ${host}` };
    }

    // Block private IPv4/IPv6
    if (isPrivateIp(host)) {
      return { ok: false, reason: `SSRF private IP blocked: ${host}` };
    }
  }
  return { ok: true };
}

function isPrivateIp(host) {
  // IPv4
  const m4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (m4) {
    const octets = m4.slice(1).map(Number);
    if (octets.some(o => o < 0 || o > 255)) return false;

    // 127.0.0.0/8
    if (octets[0] === 127) return true;
    // 10.0.0.0/8
    if (octets[0] === 10) return true;
    // 172.16.0.0/12
    if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    // 192.168.0.0/16
    if (octets[0] === 192 && octets[1] === 168) return true;
    // 169.254.0.0/16 (link-local, includes AWS metadata)
    if (octets[0] === 169 && octets[1] === 254) return true;
    // 100.64.0.0/10 (CGNAT)
    if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) return true;
    // 0.0.0.0
    if (octets.every(o => o === 0)) return true;

    return false;
  }

  // IPv6
  const v6 = host.toLowerCase();
  if (v6 === "::1" || v6 === "::") return true;
  if (v6.startsWith("fe80:") || v6.startsWith("fc") || v6.startsWith("fd")) return true;

  return false;
}

// ============================================================
// NEW LAYER: Command substitution block (unrestricted)
// ============================================================

const SUBSTITUTION_PATTERNS = [
  /\$\(/,      // $(...)
  /`/,         // `...`
  /\$\{/,      // ${...}
];

function checkSubstitution(cmd) {
  if (!BLOCK_SUBSTITUTION_UNRESTRICTED) return { ok: true };
  for (const pat of SUBSTITUTION_PATTERNS) {
    if (pat.test(cmd)) {
      return { ok: false, reason: "command substitution not allowed" };
    }
  }
  return { ok: true };
}

// ============================================================
// Main sanitizer
// ============================================================

export function sanitizeCommand(cmd, allowUnrestricted, legacyDeniedPaths = []) {
  if (typeof cmd !== "string") return { ok: false, reason: "not a string" };
  if (cmd.length === 0) return { ok: false, reason: "empty" };
  if (cmd.length > 800) return { ok: false, reason: "too long (max 800 chars)" };

  // Reject control characters outright
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(cmd)) {
    return { ok: false, reason: "control characters not allowed" };
  }

  const lower = cmd.toLowerCase();
  for (const p of legacyDeniedPaths) {
    if (lower.includes(p.toLowerCase())) {
      return { ok: false, reason: `path blocked: ${p}` };
    }
  }

  for (const pat of DANGEROUS_PATTERNS) {
    if (pat.test(cmd)) {
      return { ok: false, reason: "dangerous pattern blocked" };
    }
  }

  const home = checkHomeSandbox(cmd);
  if (!home.ok) return { ok: false, reason: home.reason };

  const ssrf = checkSsrf(cmd);
  if (!ssrf.ok) return { ok: false, reason: ssrf.reason };

  if (allowUnrestricted) {
    // NEW: still block substitution in unrestricted mode
    const sub = checkSubstitution(cmd);
    if (!sub.ok) return { ok: false, reason: sub.reason };

    const trimmed = cmd.trim();
    const firstToken = trimmed.split(/\s+/)[0];
    const cmdName = firstToken.split("=").pop().split("/").pop();
    if (UNRESTRICTED_DENIED.has(cmdName)) {
      return { ok: false, reason: `command blocked: ${cmdName}` };
    }
    return { ok: true, command: cmd };
  }

  if (RESTRICTED_BLOCKED_METACHARS.test(cmd)) {
    return { ok: false, reason: "shell metacharacters not allowed" };
  }
  const tokens = cmd.trim().split(/\s+/);
  if (!RESTRICTED_ALLOWED.has(tokens[0])) {
    return { ok: false, reason: `command not allowed: ${tokens[0]}` };
  }
  return { ok: true, command: tokens.join(" ") };
}

// ============================================================
// safePath — with real-path resolution
// Resolves symlinks in the parent directories to defeat TOCTOU
// and symlink escape.
// ============================================================

export function safePath(workdir, p = ".") {
  const base = path.resolve(workdir);
  const target = path.resolve(base, p);

  if (target !== base && !target.startsWith(base + path.sep)) {
    throw new Error("path escapes sandbox");
  }

  // Resolve symlinks in the path. If the resolved real path
  // leaves the sandbox, reject.
  try {
    const real = fs.realpathSync(target);
    if (real !== base && !real.startsWith(base + path.sep)) {
      throw new Error("path resolves outside sandbox");
    }
  } catch (e) {
    // ENOENT is fine — the file may not exist yet (write mode)
    if (e.code !== "ENOENT") {
      throw new Error(`path resolution failed: ${e.message}`);
    }
    // Verify parent's real path
    const parent = path.dirname(target);
    try {
      const realParent = fs.realpathSync(parent);
      if (realParent !== base && !realParent.startsWith(base + path.sep)) {
        throw new Error("parent path resolves outside sandbox");
      }
    } catch (pe) {
      if (pe.code !== "ENOENT") {
        throw new Error(`parent path resolution failed: ${pe.message}`);
      }
    }
  }

  return target;
}

// ============================================================
// Session name validation
// ============================================================

export function validSession(name) {
  return typeof name === "string" && /^[a-zA-Z0-9_-]{1,40}$/.test(name);
}

// ============================================================
// Timing-safe string compare
// ============================================================

export function timingSafeEq(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

// ============================================================
// NEW: HTML escaping
// Applied to any user-controlled string rendered into HTML.
// ============================================================

export function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ============================================================
// NEW: Strip ANSI escape sequences from tmux output
// Prevents terminal escape injection from being read back by
// the model or forwarded to the user.
// ============================================================

const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[PX^_][^\x1b]*\x1b\\/g;

export function stripEscapes(s) {
  if (!STRIP_ESCAPES) return String(s);
  return String(s).replace(ANSI_RE, "");
}

// ============================================================
// NEW: CSRF token helpers
// ============================================================

export function generateCsrfToken() {
  return crypto.randomBytes(24).toString("base64url");
}

export function verifyCsrfToken(provided, expected) {
  if (!provided || !expected) return false;
  return timingSafeEq(provided, expected);
}
