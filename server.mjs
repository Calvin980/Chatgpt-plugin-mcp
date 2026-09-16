import { PORT, ALLOW_UNRESTRICTED, DATA_DIR } from "./config.mjs";
import { createApp } from "./http.mjs";
import { flushAll } from "./state.mjs";

const app = await createApp();

const server = app.listen(PORT, "127.0.0.1", () => {
  console.log(`MCP server on 127.0.0.1:${PORT}  mode=${ALLOW_UNRESTRICTED ? "UNRESTRICTED" : "restricted"}`);
  console.log(`Data dir: ${DATA_DIR}`);
});

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
