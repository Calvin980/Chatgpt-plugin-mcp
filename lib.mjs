import path from "node:path";
import crypto from "node:crypto";
import { HOME, ALLOWED_HOME_SUBPATHS } from "./config.mjs";

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

function checkHomeSandbox(cmd) {
  if (!ALLOWED_HOME_SUBPATHS || ALLOWED_HOME_SUBPATHS.length === 0) {
    return { ok: true };
  }

  // Match the home prefix followed by optional subpath
  const prefix = HOME.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(prefix + "(\\/[^\\s\"'`;|&<>]*)?", "g");

  let m;
  while ((m = re.exec(cmd)) !== null) {
    const afterHome = m[1];
    if (!afterHome || afterHome === "/") continue;

    const clean = afterHome.startsWith("/") ? afterHome.slice(1) : afterHome;
    if (clean === "") continue;

    const firstSegment = clean.split("/")[0];
    const allowed = ALLOWED_HOME_SUBPATHS.some(p =>
      firstSegment === p || clean === p || clean.startsWith(p + "/")
    );
    if (!allowed) {
      return { ok: false, reason: `home path not allowed: ~/${clean}` };
    }
  }

  return { ok: true };
}

export function sanitizeCommand(cmd, allowUnrestricted, legacyDeniedPaths = []) {
  if (typeof cmd !== "string") return { ok: false, reason: "not a string" };
  if (cmd.length === 0) return { ok: false, reason: "empty" };
  if (cmd.length > 800) return { ok: false, reason: "too long (max 800 chars)" };

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

  // Home sandbox — applies in both modes
  const home = checkHomeSandbox(cmd);
  if (!home.ok) {
    return { ok: false, reason: home.reason };
  }

  if (allowUnrestricted) {
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

export function safePath(workdir, p = ".") {
  const base = path.resolve(workdir);
  const target = path.resolve(base, p);
  if (target !== base && !target.startsWith(base + path.sep)) {
    throw new Error("path escapes sandbox");
  }
  return target;
}

export function validSession(name) {
  return typeof name === "string" && /^[a-zA-Z0-9_-]{1,40}$/.test(name);
}

export function timingSafeEq(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}
