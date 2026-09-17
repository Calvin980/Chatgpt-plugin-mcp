import { PORT, ALLOW_UNRESTRICTED, DATA_DIR, ACTIVITY_FILE, IDLE_TIMEOUT_MS, IDLE_CHECK_INTERVAL_MS, ISOLATED_SESSION } from "./config.mjs";
import { createApp } from "./http.mjs";
import { flushAll } from "./state.mjs";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";

const execAsync = promisify(exec);

const { app, oauth } = await createApp();

const server = app.listen(PORT, "127.0.0.1", () => {
  console.log(`MCP server on 127.0.0.1:${PORT}  mode=${ALLOW_UNRESTRICTED ? "UNRESTRICTED" : "restricted"}`);
  console.log(`Data dir: ${DATA_DIR}`);
});

// ---------- Idle session reaper ----------
async function reapIdleSession() {
  try {
    await execAsync(`tmux has-session -t ${ISOLATED_SESSION}`, { shell: "/data/data/com.termux/files/usr/bin/bash", timeout: 3000 });
  } catch {
    return; // session doesn't exist
  }

  let last = 0;
  try {
    const raw = await fs.readFile(ACTIVITY_FILE, "utf8");
    last = parseInt(raw.trim(), 10) || 0;
  } catch {
    return; // no activity file — leave it alone
  }

  const idleMs = Date.now() - last;
  if (idleMs < IDLE_TIMEOUT_MS) return;

  console.log(`[idle] ${ISOLATED_SESSION} idle for ${Math.round(idleMs / 60000)} min — killing`);
  try {
    await execAsync(`tmux kill-session -t ${ISOLATED_SESSION}`, { shell: "/data/data/com.termux/files/usr/bin/bash", timeout: 3000 });
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
