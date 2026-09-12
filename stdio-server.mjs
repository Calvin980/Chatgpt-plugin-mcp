import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";

const execAsync = promisify(exec);
const HOME = os.homedir();
const WORKDIR = path.join(HOME, "mcp-work");
await fs.mkdir(WORKDIR, { recursive: true });
const SHELL = "/data/data/com.termux/files/usr/bin/bash";
const ISOLATED_SESSION = "mcp-ai";
const ISOLATED_HOME = path.join(HOME, "mcp-ai-home");
const PROTECTED_SESSIONS = new Set(["mcp-server", "mcp-tunnel"]);
const T_FAST = 3000;
const T_MED = 5000;
const T_SLOW = 10000;
const WRITE_MAX_BYTES = 128 * 1024;
const WRITE_ALLOWED_EXT = new Set([
  ".txt", ".md", ".json", ".csv", ".log",
  ".yaml", ".yml", ".toml", ".ini", ".conf",
  ".html", ".css", ".xml", ".svg"
]);

function safePath(p = ".") {
  const base = path.resolve(WORKDIR);
  const target = path.resolve(base, p);
  if (target !== base && !target.startsWith(base + path.sep)) throw new Error("path escapes sandbox");
  return target;
}

function validSession(name) {
  return typeof name === "string" && /^[a-zA-Z0-9_-]{1,40}$/.test(name);
}

function asUntrusted(content, source) {
  const cleaned = String(content)
    .replace(/^(ignore (all )?previous|disregard|forget (everything|all)|system\s*:|assistant\s*:|you must|you should|execute the following|run this)/gim, "[REDACTED]");
  return `[UNTRUSTED DATA FROM ${source}]\n${cleaned}\n[END UNTRUSTED DATA]`;
}

const server = new McpServer({ name: "termux", version: "2.2.0" });

server.tool("whoami", {}, async () => ({ content: [{ type: "text", text: os.userInfo().username || "unknown" }] }));
server.tool("pwd", {}, async () => ({ content: [{ type: "text", text: WORKDIR }] }));

server.tool("date", {}, async () => {
  const { stdout } = await execAsync("date '+%Y-%m-%d %H:%M:%S %Z (%A)'", { shell: SHELL, timeout: T_FAST });
  return { content: [{ type: "text", text: stdout.trim() }] };
});

server.tool("system_info", {}, async () => {
  const { stdout } = await execAsync("uname -a; echo; uptime; echo; df -h $HOME | tail -1", { shell: SHELL, timeout: T_MED });
  return { content: [{ type: "text", text: stdout }] };
});

server.tool("list_apps", {}, async () => {
  const { stdout } = await execAsync("pm list packages | sed 's/package://' | sort", { shell: SHELL, timeout: T_MED });
  return { content: [{ type: "text", text: stdout }] };
});

server.tool("open_app", { package_name: z.string() }, async ({ package_name }) => {
  if (!/^[a-zA-Z0-9._]+$/.test(package_name)) return { content: [{ type: "text", text: "Invalid package name" }], isError: true };
  try {
    const { stdout, stderr } = await execAsync(`monkey -p ${package_name} -c android.intent.category.LAUNCHER 1`, { timeout: T_SLOW, shell: SHELL });
    if (stdout.includes("No activities found") || stderr.includes("No activities found")) return { content: [{ type: "text", text: `App not found: ${package_name}` }], isError: true };
    return { content: [{ type: "text", text: `Launched ${package_name}` }] };
  } catch (e) {
    return { content: [{ type: "text", text: `Failed: ${e.message}` }], isError: true };
  }
});

server.tool("list_dir", { path: z.string().default(".") }, async ({ path: p }) => {
  const entries = await fs.readdir(safePath(p), { withFileTypes: true });
  return { content: [{ type: "text", text: entries.map(e => `${e.isDirectory() ? "d" : "-"} ${e.name}`).join("\n") || "(empty)" }] };
});

server.tool("read_file", { path: z.string() }, async ({ path: p }) => {
  return { content: [{ type: "text", text: asUntrusted((await fs.readFile(safePath(p), "utf8")).slice(-4000), "file") }] };
});

server.tool("write_file",
  { path: z.string(), content: z.string(), mode: z.enum(["create", "overwrite"]).default("create") },
  async ({ path: p, content, mode }) => {
    const target = safePath(p);
    const ext = path.extname(target).toLowerCase();
    if (!WRITE_ALLOWED_EXT.has(ext)) return { content: [{ type: "text", text: `Extension not allowed: ${ext || "(none)"}` }], isError: true };
    if (Buffer.byteLength(content, "utf8") > WRITE_MAX_BYTES) return { content: [{ type: "text", text: "Too large" }], isError: true };
    if (content.startsWith("#!")) return { content: [{ type: "text", text: "Shebang not allowed" }], isError: true };
    let exists = false;
    try { await fs.access(target); exists = true; } catch {}
    if (exists && mode !== "overwrite") return { content: [{ type: "text", text: `File exists: ${target}` }], isError: true };
    if (exists) { try { await fs.copyFile(target, target + ".bak"); } catch {} }
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, content, "utf8");
    return { content: [{ type: "text", text: exists ? `overwrote ${target}` : `created ${target}` }] };
  }
);

server.tool("append_file", { path: z.string(), content: z.string() }, async ({ path: p, content }) => {
  const target = safePath(p);
  const ext = path.extname(target).toLowerCase();
  if (!WRITE_ALLOWED_EXT.has(ext)) return { content: [{ type: "text", text: `Extension not allowed: ${ext || "(none)"}` }], isError: true };
  if (Buffer.byteLength(content, "utf8") > WRITE_MAX_BYTES) return { content: [{ type: "text", text: "Too large" }], isError: true };
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.appendFile(target, content, "utf8");
  return { content: [{ type: "text", text: `appended to ${target}` }] };
});

server.tool("tmux", {
  action: z.enum(["list", "read", "send", "create", "kill", "attach"]),
  target: z.enum(["isolated", "session"]).default("isolated"),
  name: z.string().optional(),
  command: z.string().optional(),
  lines: z.number().optional(),
}, async ({ action, target, name, command, lines = 40 }) => {
  let session;
  if (target === "isolated") {
    session = ISOLATED_SESSION;
    try {
      await fs.mkdir(ISOLATED_HOME, { recursive: true });
      await execAsync(`tmux has-session -t ${ISOLATED_SESSION} 2>/dev/null`, { shell: SHELL, timeout: T_FAST });
    } catch {
      try {
        await execAsync(`tmux new-session -d -s ${ISOLATED_SESSION} "cd ${ISOLATED_HOME} && HOME=${ISOLATED_HOME} ${SHELL}"`, { shell: SHELL, timeout: T_MED });
      } catch (e) {
        return { content: [{ type: "text", text: `Failed: ${e.message}` }], isError: true };
      }
    }
  } else {
    if (!validSession(name)) return { content: [{ type: "text", text: "Invalid session name" }], isError: true };
    if (PROTECTED_SESSIONS.has(name)) return { content: [{ type: "text", text: "Session is protected" }], isError: true };
    session = name;
  }
  try {
    switch (action) {
      case "list": {
        const { stdout } = await execAsync("tmux ls 2>&1 || true", { shell: SHELL, timeout: T_FAST });
        return { content: [{ type: "text", text: stdout.trim() || "(no sessions)" }] };
      }
      case "read": {
        const { stdout } = await execAsync(`tmux capture-pane -t ${session} -p -S -${Math.min(lines, 100)}`, { shell: SHELL, timeout: T_FAST });
        return { content: [{ type: "text", text: asUntrusted(stdout.replace(/\s+$/g, "") || "(empty)", "tmux") }] };
      }
      case "attach": {
        return { content: [{ type: "text", text: `tmux attach -t ${session}` }] };
      }
      case "create": {
        if (target === "session") {
          try { await execAsync(`tmux has-session -t ${session} 2>/dev/null`, { shell: SHELL, timeout: T_FAST }); }
          catch { await execAsync(`tmux new-session -d -s ${session}`, { shell: SHELL, timeout: T_MED }); }
        }
        if (command) await execAsync(`tmux send-keys -t ${session} -l ${JSON.stringify(command)} && tmux send-keys -t ${session} Enter`, { shell: SHELL, timeout: T_MED });
        return { content: [{ type: "text", text: `Ready: ${session}` }] };
      }
      case "send": {
        await execAsync(`tmux send-keys -t ${session} -l ${JSON.stringify(command || "")} && tmux send-keys -t ${session} Enter`, { shell: SHELL, timeout: T_MED });
        return { content: [{ type: "text", text: `Sent to ${session}` }] };
      }
      case "kill": {
        await execAsync(`tmux kill-session -t ${session}`, { shell: SHELL, timeout: T_FAST });
        return { content: [{ type: "text", text: `Killed ${session}` }] };
      }
    }
  } catch (e) {
    return { content: [{ type: "text", text: `Failed: ${e.message}` }], isError: true };
  }
});

await server.connect(new StdioServerTransport());
