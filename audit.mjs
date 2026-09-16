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

/**
 * Send a push notification via ntfy.sh.
 *
 * Silent no-op if no topic is configured (~/termux-mcp/.ntfy_topic missing).
 * 2-second timeout — if the network is slow, the notification is skipped
 * rather than hanging any request handling. Never awaited by callers.
 *
 * Messages must not include IPs, client IDs, or secrets.
 */
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
  } catch {
    // Network errors are non-fatal — notification is best-effort
  }
}
