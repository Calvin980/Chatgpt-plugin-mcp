process.env.MCP_TEST = "1";
process.env.MCP_DATA_DIR = `/tmp/termux-mcp-test-${Date.now()}`;
process.env.PUBLIC_URL = "https://test.example.com";

import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import fs from "node:fs/promises";

await fs.mkdir(process.env.MCP_DATA_DIR, { recursive: true });

const { createApp } = await import("./http.mjs");
const app = await createApp();
const server = createServer(app);
await new Promise(r => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

test.after(async () => {
  server.close();
  try { await fs.rm(process.env.MCP_DATA_DIR, { recursive: true, force: true }); } catch {}
});

// ---------- Discovery ----------

test("discovery: oauth-authorization-server", async () => {
  const r = await fetch(`${base}/.well-known/oauth-authorization-server`);
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.ok(j.issuer);
  assert.ok(j.authorization_endpoint);
  assert.ok(j.token_endpoint);
  assert.ok(j.registration_endpoint);
  assert.deepEqual(j.code_challenge_methods_supported, ["S256"]);
  assert.ok(j.grant_types_supported.includes("refresh_token"));
});

test("discovery: oauth-protected-resource", async () => {
  const r = await fetch(`${base}/.well-known/oauth-protected-resource`);
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.ok(j.resource.endsWith("/mcp"));
});

// ---------- Register ----------

test("register: rejects missing redirect_uris", async () => {
  const r = await fetch(`${base}/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: "Test" })
  });
  assert.equal(r.status, 400);
  const j = await r.json();
  assert.equal(j.error, "invalid_redirect_uri");
});

test("register: rejects attacker.com redirect", async () => {
  const r = await fetch(`${base}/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "Evil",
      redirect_uris: ["https://attacker.example.com/cb"]
    })
  });
  assert.equal(r.status, 400);
  const j = await r.json();
  assert.match(j.error_description, /not allowed/);
});

test("register: rejects http:// (non-localhost)", async () => {
  const r = await fetch(`${base}/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "Test",
      redirect_uris: ["http://chatgpt.com/cb"]
    })
  });
  assert.equal(r.status, 400);
});

test("register: accepts chatgpt.com redirect", async () => {
  const r = await fetch(`${base}/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "ChatGPT",
      redirect_uris: ["https://chatgpt.com/connector/oauth/cb"]
    })
  });
  assert.equal(r.status, 201);
  const j = await r.json();
  assert.ok(j.client_id);
  assert.ok(j.redirect_uris.includes("https://chatgpt.com/connector/oauth/cb"));
});

// ---------- Authorize ----------

test("authorize: rejects missing PKCE", async () => {
  const reg = await fetch(`${base}/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "ChatGPT",
      redirect_uris: ["https://chatgpt.com/cb"]
    })
  });
  const { client_id } = await reg.json();
  const r = await fetch(`${base}/authorize?client_id=${client_id}&redirect_uri=https://chatgpt.com/cb`);
  assert.equal(r.status, 400);
});

test("authorize: rejects redirect_uri mismatch", async () => {
  const reg = await fetch(`${base}/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "ChatGPT",
      redirect_uris: ["https://chatgpt.com/cb"]
    })
  });
  const { client_id } = await reg.json();
  const r = await fetch(`${base}/authorize?client_id=${client_id}&redirect_uri=https://chatgpt.com/different&code_challenge=abc&code_challenge_method=S256`);
  assert.equal(r.status, 400);
});

// ---------- MCP ----------

test("mcp: rejects request without bearer", async () => {
  const r = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" })
  });
  assert.equal(r.status, 401);
});

test("mcp: rejects invalid bearer", async () => {
  const r = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer fake" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" })
  });
  assert.equal(r.status, 401);
});

// ---------- Token ----------

test("token: rejects unknown client", async () => {
  const r = await fetch(`${base}/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=authorization_code&client_id=fake"
  });
  assert.equal(r.status, 401);
});

test("token: rejects refresh with unknown client", async () => {
  const r = await fetch(`${base}/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=refresh_token&refresh_token=fake&client_id=fake"
  });
  assert.equal(r.status, 401);
});
