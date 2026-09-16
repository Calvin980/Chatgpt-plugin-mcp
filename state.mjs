import fs from "node:fs/promises";
import path from "node:path";
import { DATA_DIR } from "./config.mjs";

const STATE_DIR = path.join(DATA_DIR, "state");

// Global registry of persisters so they can all be flushed on shutdown.
const registry = [];

export async function initState() {
  await fs.mkdir(STATE_DIR, { recursive: true, mode: 0o700 });
}

export async function loadMap(name) {
  const file = path.join(STATE_DIR, name + ".json");
  try {
    const raw = await fs.readFile(file, "utf8");
    return new Map(Object.entries(JSON.parse(raw)));
  } catch (e) {
    if (e.code === "ENOENT") {
      return new Map();
    }
    console.error(`[state] Failed to load ${name}.json: ${e.message}`);
    try {
      const backup = path.join(STATE_DIR, `${name}.json.corrupt.${Date.now()}`);
      await fs.rename(file, backup);
      console.error(`[state] Moved corrupt file to: ${backup}`);
    } catch (renameErr) {
      console.error(`[state] Could not move corrupt file: ${renameErr.message}`);
    }
    return new Map();
  }
}

async function writeMap(name, map) {
  const obj = Object.fromEntries(map);
  const tmp = path.join(STATE_DIR, name + ".json.tmp");
  const dest = path.join(STATE_DIR, name + ".json");
  await fs.writeFile(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 });
  await fs.rename(tmp, dest);
}

export function makePersister(name, map) {
  let timer = null;
  let pending = false;

  async function doWrite() {
    try {
      await initState();
      await writeMap(name, map);
      pending = false;
    } catch (e) {
      console.error(`[state] persist ${name} error: ${e.message}`);
    }
  }

  const persister = {
    schedule() {
      pending = true;
      if (timer) return;
      timer = setTimeout(async () => {
        timer = null;
        await doWrite();
      }, 500);
    },
    async flush() {
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      if (pending) {
        await doWrite();
      }
    }
  };

  registry.push(persister);
  return persister;
}

export async function flushAll() {
  await Promise.all(registry.map(p => p.flush()));
}
