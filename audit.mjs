import fs from "node:fs/promises";
import path from "node:path";
import { DATA_DIR } from "./config.mjs";

const AUDIT_FILE = path.join(DATA_DIR, "audit.log");
const NTFY_FILE = path.join(DATA_DIR, ".ntfy_topic");

export async function audit(event) {
  const line = JSON.stringify({ ts: new Date().toISOString(), ...event }) + "\n";
  try { await fs.appendFile(AUDIT_FILE, line); } catch {}
}

const INJECTION_PATTERNS = [
  /ignore\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules?|context)/i,
  /disregard\s+(the\s+)?(previous|above|prior|system)/i,
  /forget\s+(everything|all|your\s+instructions|previous)/i,
  /override\s+(the\s+)?(system|instructions?|rules?)/i,
  /you\s+are\s+now\s+(a|an|the)/i,
  /act\s+as\s+(a|an|if\s+you\s+are)/i,
  /pretend\s+to\s+be/i,
  /new\s+(instructions?|rules?|system\s+prompt)/i,
  /system\s*:\s*/im,
  /assistant\s*:\s*/im,
  /you\s+must\s+(now|immediately)/i,
  /execute\s+the\s+following/i,
  /run\s+this\s+command/i,
  /curl\s+.*\|\s*(sh|bash)/i,
  /wget\s+.*\|\s*(sh|bash)/i,
  /<\s*script/i,
  /javascript\s*:/i,
  /Important\s*:\s*disregard/i,
  /Instructions?\s+for\s+(the\s+)?(AI|assistant|model)/i,
  /do\s+not\s+(tell|inform|mention\s+to)\s+the\s+user/i
];

export function asUntrusted(content, source) {
  let cleaned = String(content);
  let redactions = 0;
  for (const pattern of INJECTION_PATTERNS) {
    cleaned = cleaned.replace(pattern, () => { redactions++; return "[REDACTED]"; });
  }
  const marker = redactions > 0 ? ` (${redactions} pattern${redactions > 1 ? "s" : ""} redacted)` : "";
  return `[UNTRUSTED DATA FROM ${source}${marker}]\n${cleaned}\n[END UNTRUSTED DATA]`;
}

export async function notify(message) {
  let topic;
  try {
    topic = (await fs.readFile(NTFY_FILE, "utf8")).trim();
  } catch {
    return;
  }
  if (!topic) return;
  try {
    await fetch(`https://ntfy.sh/${topic}`, {
      method: "POST",
      body: message,
      signal: AbortSignal.timeout(2000)
    });
  } catch {}
}

export async function analyzeAudit(options = {}) {
  const days = options.days || 7;
  const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;

  let raw;
  try {
    raw = await fs.readFile(AUDIT_FILE, "utf8");
  } catch {
    return { entries: 0, error: "no audit log" };
  }

  const lines = raw.trim().split("\n").filter(Boolean);
  const entries = [];
  for (const line of lines) {
    try {
      const e = JSON.parse(line);
      if (new Date(e.ts).getTime() >= cutoff) entries.push(e);
    } catch {}
  }

  const byEvent = {};
  const byTool = {};
  const byClient = {};
  const failedAuth = [];
  const commands = [];
  const honeypots = [];

  for (const e of entries) {
    byEvent[e.event] = (byEvent[e.event] || 0) + 1;
    if (e.tool) byTool[e.tool] = (byTool[e.tool] || 0) + 1;
    if (e.client_id) byClient[e.client_id] = (byClient[e.client_id] || 0) + 1;

    if (e.event === "approve_wrong_password" || e.event === "approve_wrong_totp") {
      failedAuth.push({ ts: e.ts, event: e.event, client_id: e.client_id });
    }
    if (e.event === "mcp_call" && e.command) {
      commands.push({ ts: e.ts, tool: e.tool, command: e.command });
    }
    if (e.event === "HONEYPOT_TRIGGERED") {
      honeypots.push({ ts: e.ts, tool: e.tool });
    }
  }

  function topN(obj, n = 5) {
    return Object.entries(obj).sort((a, b) => b[1] - a[1]).slice(0, n);
  }

  return {
    window_days: days,
    entries: entries.length,
    unique_clients: Object.keys(byClient).length,
    events: topN(byEvent, 15),
    tools: topN(byTool, 15),
    clients: topN(byClient, 10),
    failed_auth_count: failedAuth.length,
    failed_auth_recent: failedAuth.slice(-5),
    commands_count: commands.length,
    commands_recent: commands.slice(-10),
    honeypot_count: honeypots.length,
    honeypot_recent: honeypots.slice(-5)
  };
}
