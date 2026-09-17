import {
  PORT, ALLOW_UNRESTRICTED, DATA_DIR,
  ACTIVITY_FILE, IDLE_TIMEOUT_MS, IDLE_CHECK_INTERVAL_MS,
  ISOLATED_SESSION, SHELL
} from "./config.mjs";
import { createApp } from "./http.mjs";
import { flushAll } from "./state.mjs";
import { initAudit, audit } from "./audit.mjs";
import { verifyToolIntegrity } from "./tools.mjs";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";

const execAsync = promisify(exec);

await initAudit();

// ---------- Startup integrity check ----------
const integrity = await verifyToolIntegrity();
if (!integrity.ok) {
  console.log("");
  console.log("╔══════════════════════════════════════════════╗");
  console.log("║  ⚠️  TOOL INTEGRITY MISMATCH                 ║");
  console.log("║  tools.mjs has changed since last startup.   ║");
  if (integrity.expected) {
    console.log(`║  Expected: ${integrity.expected}                       ║`);
    console.log(`║  Actual:   ${integrity.actual}                       ║`);
  }
  console.log("║                                              ║");
  console.log("║  If you didn't update it, stop and inspect.  ║");
  console.log("╚══════════════════════════════════════════════╝");
  console.log("");
}

const { app, oauth } = await createApp();

const server = app.listen(PORT, "127.0.0.1", () => {
  console.log(`MCP server on 127.0.0.1:${PORT}  mode=${ALLOW_UNRESTRICTED ? "UNRESTRICTED" : "restricted"}`);
  console.log(`Data dir: ${DATA_DIR}`);
  console.log(`Clients: ${oauth.getClientCount()}  Tokens: ${oauth.getTokenCount()}  Refresh: ${oauth.getRefreshCount()}`);
});

// ---------- Idle session reaper ----------
async function reapIdleSession() {
  try {
    await execAsync(`tmux has-session -t ${ISOLATED_SESSION}`, { shell: SHELL, timeout: 3000 });
  } catch {
    return;
  }

  let last = 0;
  try {
    const raw = await fs.readFile(ACTIVITY_FILE, "utf8");
    last = parseInt(raw.trim(), 10) || 0;
  } catch {
    return;
  }

  const idleMs = Date.now() - last;
  if (idleMs < IDLE_TIMEOUT_MS) return;

  console.log(`[idle] ${ISOLATED_SESSION} idle ${Math.round(idleMs / 60000)} min — killing`);
  try {
    await execAsync(`tmux kill-session -t ${ISOLATED_SESSION}`, { shell: SHELL, timeout: 3000 });
    await audit({ event: "idle_session_killed", minutes: Math.round(idleMs / 60000) });
  } catch (e) {
    console.error(`[idle] kill failed: ${e.message}`);
  }
}

const idleTimer = setInterval(reapIdleSession, IDLE_CHECK_INTERVAL_MS);
idleTimer.unref();

// ---------- Shutdown ----------
async function shutdown(signal) {
  console.log(`\nReceived ${signal}, flushing state...`);
  try {
    await flushAll();
    console.log("State flushed.");
  } catch (e) {
    console.error("Flush error:", e.message);
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
