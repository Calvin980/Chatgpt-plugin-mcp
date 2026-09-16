import crypto from "node:crypto";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import { createRemoteJWKSet, jwtVerify, createLocalJWKSet } from "jose";
import {
  DATA_DIR, SHELL, T_FAST,
  TOKEN_TTL_MS, REFRESH_TTL_MS,
  MAX_REGISTERED_CLIENTS, MAX_PENDING_AUTH_CODES,
  TOTP_MAX_FAILURES, TOTP_LOCKOUT_MS,
  ALLOWED_REDIRECT_HOSTS
} from "./config.mjs";
import { audit, notify } from "./audit.mjs";
import { timingSafeEq } from "./lib.mjs";
import { initState, loadMap, makePersister } from "./state.mjs";

const execAsync = promisify(exec);

// ============================================================
// Factory — creates a fresh state + mount function per app
// ============================================================

export async function createOAuth() {
  let CONSENT_PASSWORD = null;
  let TOTP_SECRET = null;
  let USE_DIALOG = false;

  try {
    CONSENT_PASSWORD = (await fs.readFile(path.join(DATA_DIR, ".consent_password"), "utf8")).trim();
  } catch {}
  try {
    TOTP_SECRET = (await fs.readFile(path.join(DATA_DIR, ".totp_secret"), "utf8")).trim();
  } catch {}
  try {
    await fs.access(path.join(DATA_DIR, ".use_dialog"));
    USE_DIALOG = true;
  } catch {}

  await initState();
  const clients = await loadMap("clients");
  const tokens = await loadMap("tokens");
  const refreshTokens = await loadMap("refresh_tokens");

  const persistClients = makePersister("clients", clients);
  const persistTokens = makePersister("tokens", tokens);
  const persistRefreshTokens = makePersister("refresh_tokens", refreshTokens);

  {
    const now = Date.now();
    for (const [k, v] of tokens) if (!v.expiresAt || v.expiresAt < now) tokens.delete(k);
    for (const [k, v] of refreshTokens) if (!v.expiresAt || v.expiresAt < now) refreshTokens.delete(k);
    persistTokens.schedule();
    persistRefreshTokens.schedule();
  }

  const authCodes = new Map();
  const jwksCache = new Map();
  const totpAttempts = new Map();
  const rateBuckets = new Map();

  function rateLimit(key, max, windowMs) {
    const now = Date.now();
    const arr = (rateBuckets.get(key) || []).filter(t => now - t < windowMs);
    if (arr.length >= max) return false;
    arr.push(now);
    rateBuckets.set(key, arr);
    return true;
  }

  const cleanupTimer = setInterval(() => {
    const now = Date.now();

    for (const [k, arr] of rateBuckets) {
      const fresh = arr.filter(t => now - t < 60_000);
      if (fresh.length) rateBuckets.set(k, fresh);
      else rateBuckets.delete(k);
    }

    for (const [k, v] of authCodes) if (v.expiresAt < now) authCodes.delete(k);

    let tokensChanged = false;
    for (const [k, v] of tokens) {
      if (!v.expiresAt || v.expiresAt < now) {
        tokens.delete(k);
        tokensChanged = true;
      }
    }
    if (tokensChanged) persistTokens.schedule();

    let refreshChanged = false;
    for (const [k, v] of refreshTokens) {
      if (!v.expiresAt || v.expiresAt < now) {
        refreshTokens.delete(k);
        refreshChanged = true;
      }
    }
    if (refreshChanged) persistRefreshTokens.schedule();
  }, 60_000);
  cleanupTimer.unref();

  function publicUrl(req) {
    const host = req.headers["x-forwarded-host"] || req.headers.host;
    const proto = req.headers["x-forwarded-proto"] || "https";
    return `${proto}://${host}`;
  }

  function clientIp(req) {
    return (req.headers["x-forwarded-for"] || "").split(",")[0].trim() || req.socket.remoteAddress || "unknown";
  }

  function getJwks(uri) {
    if (!jwksCache.has(uri)) jwksCache.set(uri, createRemoteJWKSet(new URL(uri)));
    return jwksCache.get(uri);
  }

  function isAllowedRedirect(uri) {
    try {
      const u = new URL(uri);
      const isLocal = u.hostname === "localhost" || u.hostname === "127.0.0.1";
      if (!isLocal && u.protocol !== "https:") return false;
      return ALLOWED_REDIRECT_HOSTS.some(h =>
        u.hostname === h || u.hostname.endsWith("." + h)
      );
    } catch {
      return false;
    }
  }

  async function verifyTotp(code) {
    if (!TOTP_SECRET) return { ok: true, skipped: true };
    if (!/^[0-9]{6}$/.test(code || "")) return { ok: false, reason: "format" };
    try {
      const now = Math.floor(Date.now() / 1000);
      for (const offset of [-30, 0, 30]) {
        const t = now + offset;
        const { stdout } = await execAsync(
          `oathtool --totp -b -N @${t} ${JSON.stringify(TOTP_SECRET)}`,
          { shell: SHELL, timeout: T_FAST }
        );
        if (timingSafeEq(stdout.trim(), code)) return { ok: true };
      }
      return { ok: false, reason: "wrong" };
    } catch (e) {
      return { ok: false, reason: "error", err: e.message };
    }
  }

  function isLockedOut(ip) {
    const attempts = totpAttempts.get(ip) || [];
    const recent = attempts.filter(a => Date.now() - a.ts < TOTP_LOCKOUT_MS && !a.ok);
    return recent.length >= TOTP_MAX_FAILURES;
  }

  function recordTotpAttempt(ip, ok) {
    const attempts = totpAttempts.get(ip) || [];
    attempts.push({ ts: Date.now(), ok });
    totpAttempts.set(ip, attempts.slice(-20));
    if (ok) totpAttempts.set(ip, []);
  }

  async function requestDeviceApproval() {
    if (!USE_DIALOG) return { ok: true, skipped: true };
    try {
      const { stdout } = await execAsync(
        `termux-dialog confirm -t "Termux MCP" -i "Approve connection?"`,
        { shell: SHELL, timeout: 60000 }
      );
      const result = JSON.parse(stdout.trim());
      if (result.code === 0 && result.text === "yes") return { ok: true };
      return { ok: false, reason: "denied" };
    } catch (e) {
      return { ok: false, reason: "error", err: e.message };
    }
  }

  async function authenticateClient(reqBody, base) {
    const { client_id, client_assertion, client_assertion_type } = reqBody;
    if (client_assertion && client_assertion_type === "urn:ietf:params:oauth:client-assertion-type:jwt-bearer") {
      let decoded;
      try {
        decoded = JSON.parse(Buffer.from(client_assertion.split(".")[1], "base64url").toString());
      } catch {
        return { ok: false, error: "invalid_client" };
      }
      const candidateId = decoded.iss || decoded.sub;
      const client = clients.get(candidateId);
      if (!client) return { ok: false, error: "invalid_client" };
      try {
        let jwks;
        if (client.jwks?.keys?.length) jwks = createLocalJWKSet(client.jwks);
        else if (client.jwks_uri) jwks = getJwks(client.jwks_uri);
        else return { ok: false, error: "invalid_client" };
        await jwtVerify(client_assertion, jwks, {
          issuer: candidateId, subject: candidateId, audience: `${base}/token`
        });
        return { ok: true, clientId: candidateId };
      } catch (e) {
        audit({ event: "token_bad_assertion", err: e.message });
        return { ok: false, error: "invalid_client" };
      }
    }
    if (client_id) {
      const client = clients.get(client_id);
      if (!client) return { ok: false, error: "invalid_client" };
      return { ok: true, clientId: client_id };
    }
    return { ok: false, error: "invalid_client" };
  }

  function checkBearer(req) {
    const auth = req.headers.authorization;
    if (!auth?.startsWith("Bearer ")) return null;
    const token = auth.slice(7);
    const tok = tokens.get(token);
    if (!tok) return null;
    if (!tok.expiresAt || tok.expiresAt < Date.now()) {
      tokens.delete(token);
      persistTokens.schedule();
      return null;
    }
    return tok;
  }

  function mountOAuth(app) {

    app.get("/.well-known/oauth-authorization-server", (req, res) => {
      const base = publicUrl(req);
      res.json({
        issuer: base,
        authorization_endpoint: `${base}/authorize`,
        token_endpoint: `${base}/token`,
        registration_endpoint: `${base}/register`,
        scopes_supported: ["mcp:tools"],
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        token_endpoint_auth_methods_supported: ["none", "private_key_jwt"],
        code_challenge_methods_supported: ["S256"],
      });
    });

    app.get("/.well-known/oauth-protected-resource", (req, res) => {
      const base = publicUrl(req);
      res.json({
        resource: `${base}/mcp`,
        authorization_servers: [base],
        bearer_methods_supported: ["header"],
        scopes_supported: ["mcp:tools"],
      });
    });

    app.post("/register", (req, res) => {
      const ip = clientIp(req);
      if (!rateLimit(`reg:${ip}`, 5, 60_000)) {
        audit({ event: "register_rate_limited", ip });
        return res.status(429).json({ error: "rate_limited" });
      }
      if (clients.size >= MAX_REGISTERED_CLIENTS) {
        audit({ event: "register_cap_reached", size: clients.size });
        return res.status(429).json({ error: "too_many_clients" });
      }

      const { client_name, redirect_uris, token_endpoint_auth_method, jwks_uri, jwks } = req.body || {};

      if (!Array.isArray(redirect_uris) || redirect_uris.length === 0) {
        audit({ event: "register_no_redirect", ip });
        return res.status(400).json({ error: "invalid_redirect_uri", error_description: "redirect_uris required" });
      }
      for (const uri of redirect_uris) {
        if (!isAllowedRedirect(uri)) {
          audit({ event: "register_bad_redirect", uri, ip });
          return res.status(400).json({
            error: "invalid_redirect_uri",
            error_description: `redirect_uri not allowed: ${uri}`
          });
        }
      }

      const clientId = crypto.randomUUID();
      clients.set(clientId, {
        client_id: clientId, client_name,
        redirect_uris,
        token_endpoint_auth_method: token_endpoint_auth_method || "none",
        jwks_uri: jwks_uri || null, jwks: jwks || null,
      });
      persistClients.schedule();
      audit({ event: "register", client_id: clientId, name: client_name, ip });

      res.status(201).json({
        client_id: clientId,
        client_id_issued_at: Math.floor(Date.now() / 1000),
        redirect_uris,
        token_endpoint_auth_method: token_endpoint_auth_method || "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
      });
    });

    app.get("/authorize", (req, res) => {
      const ip = clientIp(req);
      if (!rateLimit(`auth:${ip}`, 20, 60_000)) {
        audit({ event: "authorize_rate_limited", ip });
        return res.status(429).send("Too many requests");
      }
      const { client_id, redirect_uri, state, code_challenge, code_challenge_method, scope } = req.query;
      const client = clients.get(client_id);
      if (!client) return res.status(400).send("Unknown client_id");

      if (!code_challenge || code_challenge_method !== "S256") {
        audit({ event: "authorize_no_pkce", client_id });
        return res.status(400).send("PKCE required (S256)");
      }

      if (!client.redirect_uris.includes(redirect_uri)) {
        audit({ event: "authorize_redirect_mismatch", client_id, redirect_uri, ip });
        return res.status(400).send("redirect_uri does not match registration");
      }

      const pwField = CONSENT_PASSWORD ? `<label>Password: <input type="password" name="password" required autofocus></label><br><br>` : "";
      const totpField = TOTP_SECRET ? `<label>TOTP code: <input type="text" name="totp_code" required pattern="[0-9]{6}" inputmode="numeric" autocomplete="one-time-code"></label><br><br>` : "";
      const dialogNote = USE_DIALOG ? `<p style="color:#666;font-size:0.9em">After submitting, you'll be asked to approve on your phone.</p>` : "";

      res.send(`<!DOCTYPE html><html><body style="font-family:sans-serif;padding:2rem;max-width:500px;margin:auto">
<h1>Approve Access</h1>
<p><b>${client.client_name || client_id}</b> wants to use your Termux tools.</p>
<form method="POST" action="/authorize/approve">
<input type="hidden" name="client_id" value="${client_id}">
<input type="hidden" name="redirect_uri" value="${redirect_uri}">
<input type="hidden" name="state" value="${state || ""}">
<input type="hidden" name="code_challenge" value="${code_challenge}">
<input type="hidden" name="code_challenge_method" value="${code_challenge_method}">
<input type="hidden" name="scope" value="${scope || "mcp:tools"}">
${pwField}${totpField}${dialogNote}
<button type="submit" style="padding:1rem 2rem;background:#0070f3;color:#fff;border:none;border-radius:5px;cursor:pointer">Approve</button>
</form></body></html>`);
    });

    app.post("/authorize/approve", async (req, res) => {
      const ip = clientIp(req);
      if (!rateLimit(`approve:${ip}`, 10, 60_000)) {
        audit({ event: "approve_rate_limited", ip });
        return res.status(429).send("Too many requests");
      }

      if (isLockedOut(ip)) {
        audit({ event: "approve_locked_out", ip });
        return res.status(429).send("Too many failed attempts. Try again later.");
      }

      const { client_id, redirect_uri, state, code_challenge, code_challenge_method, scope, password, totp_code } = req.body;

      if (CONSENT_PASSWORD && !timingSafeEq(password || "", CONSENT_PASSWORD)) {
        await audit({ event: "approve_wrong_password", client_id, ip });
        return res.status(401).send("Wrong password");
      }

      if (TOTP_SECRET) {
        const totp = await verifyTotp(totp_code);
        recordTotpAttempt(ip, totp.ok);
        if (!totp.ok) {
          await audit({ event: "approve_wrong_totp", client_id, ip, reason: totp.reason });
          if (isLockedOut(ip)) notify("Termux MCP: too many failed login attempts");
          return res.status(401).send("Wrong or expired TOTP code");
        }
      }

      if (USE_DIALOG) {
        const dialog = await requestDeviceApproval();
        if (!dialog.ok) {
          await audit({ event: "approve_dialog_denied", client_id, ip, reason: dialog.reason });
          return res.status(401).send("Device approval denied or failed");
        }
      }

      if (!code_challenge || code_challenge_method !== "S256") {
        return res.status(400).send("PKCE required");
      }

      const client = clients.get(client_id);
      if (!client || !client.redirect_uris.includes(redirect_uri)) {
        audit({ event: "approve_redirect_mismatch", client_id, ip });
        return res.status(400).send("redirect_uri does not match registration");
      }

      if (authCodes.size >= MAX_PENDING_AUTH_CODES) {
        const oldest = authCodes.keys().next().value;
        authCodes.delete(oldest);
      }

      const code = crypto.randomBytes(32).toString("hex");
      authCodes.set(code, {
        client_id, redirect_uri,
        scope: scope || "mcp:tools",
        codeChallenge: code_challenge,
        codeChallengeMethod: code_challenge_method,
        expiresAt: Date.now() + 5 * 60 * 1000,
      });

      await audit({
        event: "authorize_approved",
        client_id, ip,
        factors: [
          CONSENT_PASSWORD && "password",
          TOTP_SECRET && "totp",
          USE_DIALOG && "dialog"
        ].filter(Boolean)
      });

      notify(`Termux MCP: new client connected (${client.client_name || "unknown"})`).catch(() => {});

      const url = new URL(redirect_uri);
      url.searchParams.set("code", code);
      if (state) url.searchParams.set("state", state);
      res.redirect(url.toString());
    });

    app.post("/token", async (req, res) => {
      const ip = clientIp(req);
      if (!rateLimit(`token:${ip}`, 20, 60_000)) {
        audit({ event: "token_rate_limited", ip });
        return res.status(429).json({ error: "rate_limited" });
      }

      try {
        const base = publicUrl(req);
        const { grant_type } = req.body;

        const auth = await authenticateClient(req.body, base);
        if (!auth.ok) return res.status(401).json({ error: auth.error });
        const authedId = auth.clientId;

        if (grant_type === "authorization_code") {
          const { code, redirect_uri, code_verifier } = req.body;
          const ac = authCodes.get(code);
          if (!ac || ac.client_id !== authedId || ac.expiresAt < Date.now() || ac.redirect_uri !== redirect_uri) {
            return res.status(400).json({ error: "invalid_grant" });
          }
          if (ac.codeChallenge) {
            const computed = crypto.createHash("sha256").update(code_verifier || "").digest("base64url");
            if (computed !== ac.codeChallenge) {
              return res.status(400).json({ error: "invalid_grant", error_description: "pkce mismatch" });
            }
          }
          authCodes.delete(code);

          const accessToken = crypto.randomBytes(32).toString("hex");
          const refreshToken = crypto.randomBytes(32).toString("hex");
          const now = Date.now();

          tokens.set(accessToken, { client_id: authedId, scope: ac.scope, expiresAt: now + TOKEN_TTL_MS });
          refreshTokens.set(refreshToken, { client_id: authedId, scope: ac.scope, expiresAt: now + REFRESH_TTL_MS });
          persistTokens.schedule();
          persistRefreshTokens.schedule();

          await audit({ event: "token_issued", client_id: authedId });
          return res.json({
            access_token: accessToken,
            refresh_token: refreshToken,
            token_type: "Bearer",
            expires_in: Math.floor(TOKEN_TTL_MS / 1000),
            scope: ac.scope,
          });
        }

        if (grant_type === "refresh_token") {
          const { refresh_token } = req.body;
          const rt = refreshTokens.get(refresh_token);
          if (!rt || rt.client_id !== authedId || rt.expiresAt < Date.now()) {
            return res.status(400).json({ error: "invalid_grant" });
          }
          refreshTokens.delete(refresh_token);
          const accessToken = crypto.randomBytes(32).toString("hex");
          const newRefreshToken = crypto.randomBytes(32).toString("hex");
          const now = Date.now();
          tokens.set(accessToken, { client_id: authedId, scope: rt.scope, expiresAt: now + TOKEN_TTL_MS });
          refreshTokens.set(newRefreshToken, { client_id: authedId, scope: rt.scope, expiresAt: now + REFRESH_TTL_MS });
          persistTokens.schedule();
          persistRefreshTokens.schedule();
          await audit({ event: "token_refreshed", client_id: authedId });
          return res.json({
            access_token: accessToken,
            refresh_token: newRefreshToken,
            token_type: "Bearer",
            expires_in: Math.floor(TOKEN_TTL_MS / 1000),
            scope: rt.scope,
          });
        }

        return res.status(400).json({ error: "unsupported_grant_type" });
      } catch (e) {
        console.error("token error:", e);
        res.status(500).json({ error: "server_error" });
      }
    });
  }

  return { mountOAuth, checkBearer, rateLimit };
}
