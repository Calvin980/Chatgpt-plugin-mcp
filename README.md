# Termux MCP — Connect ChatGPT to an Android Device

Termux MCP runs a [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server on Android through Termux. It exposes a controlled set of device tools to an MCP-compatible client such as ChatGPT.

> **Security warning:** This project gives an internet-connected AI client a path to perform actions on your phone. Read the [Security and warnings](#security-and-warnings) section before installing it. Use restricted mode, keep the server stopped when it is not needed, and do not run it as root.

## What it provides

In restricted mode (the default), the server provides:

- Read-only device information: username, working directory, date, system information, and visible Android package names.
- Sandboxed file operations in `~/mcp-work`: list, read, create, overwrite, and append text files.
- An isolated `tmux` session named `mcp-ai` with its own home directory at `~/mcp-ai-home`.
- OAuth-protected MCP requests over the `/mcp` endpoint.
- Optional TOTP, recovery-code, Android device-dialog, and ntfy notification support.

Mutating tools (`write_file`, `append_file`, `open_app`, and mutating `tmux` actions) are locked until you explicitly run `termux-mcp unlock [minutes]`. The lock can be cleared immediately with `termux-mcp lock` or `termux-mcp panic`.

## How it works

```text
ChatGPT / MCP client
        |
        | HTTPS through Tailscale Funnel + OAuth 2.1 / PKCE
        v
Tailscale Funnel
        |
        | localhost reverse proxy to port 8000
        v
Node.js MCP server (127.0.0.1:8000)
        |-- OAuth registration, authorization, token, and revocation endpoints
        |-- Bearer-token validation and rate limiting
        |-- audit logging
        `-- MCP tool execution
                |-- ~/mcp-work (file sandbox)
                |-- ~/mcp-ai-home (isolated tmux home)
                `-- Termux / Android APIs
```

`start.sh` starts Tailscale Funnel, launches the Node server in the `mcp-server` tmux session, and sets `PUBLIC_URL` from the device's Tailscale DNS name. The Node server listens on `127.0.0.1` only; the public entry point is Tailscale Funnel.

The OAuth flow is:

1. The client registers and receives a client ID.
2. The client begins authorization using PKCE with the S256 method.
3. You approve the request with the consent password and any enabled extra factors.
4. The server issues a short-lived authorization code.
5. The client exchanges it for an access token and refresh token.
6. Requests to `/mcp` must include a valid bearer token.

Access tokens default to 30 minutes and refresh tokens default to 30 days. OAuth state is stored below `~/termux-mcp/state/`.

## Requirements

- Android with [Termux](https://termux.dev/) installed. Use a current Termux release from a trusted source.
- Network access.
- A Tailscale account and a Tailscale installation that supports Funnel on the device.
- An MCP-compatible client.
- Approximately 200 MB of free storage for Node.js and dependencies.

The installer installs Node.js, `tmux`, `jq`, and the project npm dependencies. TOTP, device dialogs, QR codes, and notifications install or use additional optional packages.

## Installation

### Inspect before running

The installer downloads source files and, optionally, third-party scripts. Review it first rather than piping it directly to a shell:

```bash
curl -fsSL -o termux-mcp-install.sh \
  https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh
less termux-mcp-install.sh
bash termux-mcp-install.sh
```

The installer may download scripts from the Termux mirror project and the Tailscale Termux CLI project. Review those scripts too if you enable mirror setup or need to install Tailscale automatically.

During installation you can optionally enable:

- TOTP as an additional authorization factor. Save the displayed secret and one-time recovery codes securely.
- A `termux-dialog` device-approval prompt.
- ntfy push notifications. Treat the topic as a secret because anyone who knows a public topic may be able to read notifications sent to it.

The installer creates:

```text
~/termux-mcp/       Server code, configuration, secrets, state, and audit log
~/mcp-work/         File-operation sandbox
~/mcp-ai-home/      Home directory for the isolated AI tmux session
$PREFIX/bin/termux-mcp
$PREFIX/bin/termux-mcp-stdio
```

## Quick start

Authenticate Tailscale first if necessary:

```bash
tailscale up
```

Enable Funnel for the device in the Tailscale admin console, then start restricted mode:

```bash
termux-mcp
```

The command prints the MCP URL, for example:

```text
https://your-device.your-tailnet.ts.net/mcp
```

Configure that URL in the MCP client and choose OAuth. Client ID and client secret are generated during registration, so normally leave them blank. Approve the authorization request with the consent password shown by:

```bash
termux-mcp password
```

Stop exposure when finished:

```bash
termux-mcp shutdown
```

`shutdown` stops the server and removes the Funnel configuration. `shutdown-all` also stops the Tailscale daemon.

## Modes and locking

### Restricted mode (recommended)

```bash
termux-mcp start
# or simply:
termux-mcp
```

Restricted mode confines file tools to `~/mcp-work`, exposes only the isolated `mcp-ai` session, rejects shell metacharacter chaining, and blocks sensitive paths and dangerous patterns. It is still not a complete security boundary: commands run as your Termux user and can consume device resources.

### Unrestricted mode

```bash
termux-mcp unrestricted
```

This permits access to other non-protected tmux sessions and relaxes command restrictions. It must be treated as a high-risk administrator-like mode. It does **not** make the server safe for untrusted clients and does not remove all path protections.

### Temporarily permit mutations

```bash
termux-mcp unlock 5   # unlock for five minutes
termux-mcp lock       # lock immediately
termux-mcp panic      # stop server, remove Funnel, and clear unlock state
```

The isolated session is automatically reaped after the configured idle timeout (30 minutes by default).

## Available MCP tools

| Tool | Behavior |
|---|---|
| `whoami`, `pwd`, `date`, `system_info` | Read-only device information |
| `list_apps` | Lists up to 80 visible Android package names |
| `list_dir` | Lists entries under `~/mcp-work` |
| `read_file` | Reads a text file under `~/mcp-work`, capped at 3 KB and marked as untrusted data |
| `write_file` | Locked; creates or overwrites allowed text/config files, up to 128 KiB |
| `append_file` | Locked; appends to allowed files, up to 128 KiB per request |
| `open_app` | Locked; launches a validated Android package name |
| `tmux` | Reads or interacts with the isolated session; other sessions require unrestricted mode |
| `debug_env`, `read_ssh_key`, `admin_override` | Honeypot tools; unavailable and logged if called |

Default writable extensions are `.txt`, `.md`, `.json`, `.csv`, `.log`, `.yaml`, `.yml`, `.toml`, `.ini`, `.conf`, `.html`, `.css`, `.xml`, and `.svg`. Files beginning with a shebang are rejected. The server also blocks sensitive locations such as SSH credentials, cloud credentials, Termux configuration, OAuth secrets, and its own source files.

## Configuration

The server reads optional overrides from `~/termux-mcp/config.json`. Start with the example:

```bash
cp ~/termux-mcp/config.json.example ~/termux-mcp/config.json
termux-mcp config-edit
termux-mcp restart
```

Available settings include command timeouts, writable extensions and size, token and refresh-token lifetimes, client and pending-code limits, TOTP lockout settings, allowed OAuth redirect hosts, per-IP/client rate limits, idle-session timing, and allowed home subpaths. Validate the JSON before restarting.

Important environment variables:

| Variable | Default | Purpose |
|---|---:|---|
| `MCP_DATA_DIR` | `~/termux-mcp` | Data, state, secrets, and logs directory |
| `PORT` | `8000` | Local server port |
| `PUBLIC_URL` | Set by `start.sh` | Public HTTPS base URL used in OAuth metadata |
| `MCP_ALLOW_UNRESTRICTED` | `0` | Set to `1` only for unrestricted mode |
| `MCP_TEST` | unset | Uses a local URL for automated HTTP tests |

Do not rely on unrelated variables such as `MCP_WORK_DIR`; the current implementation uses the fixed `~/mcp-work` path.

## CLI commands

Common commands:

```bash
termux-mcp start                         # restricted server
termux-mcp unrestricted                  # high-risk mode
termux-mcp stop                          # stop server and AI session
termux-mcp shutdown                      # stop and remove Funnel
termux-mcp unlock 5 / lock / panic       # mutation and emergency controls
termux-mcp url / test-url                 # show or test the MCP URL
termux-mcp health / info / disk           # diagnostics
termux-mcp audit / audit-stats            # inspect audit activity
termux-mcp audit-analyze 7                # analyze the last seven days
termux-mcp tail                          # follow the audit log
termux-mcp test / test-http               # run test suites
termux-mcp update / check-update          # update or check source files
termux-mcp backup [path] / restore [path] # back up or restore secrets/config
termux-mcp revoke                         # revoke all clients and tokens
termux-mcp revoke-client [client-id]      # revoke one client
termux-mcp list                           # show every available command
```

For local MCP integrations that support stdio, use:

```bash
termux-mcp-stdio
```

This does not create a public tunnel, but the local client still receives the capabilities of the MCP server and must be trusted.

## Security and warnings

### Public exposure

Tailscale Funnel makes the service reachable from the internet. OAuth and PKCE protect authorization, but authentication is not a guarantee that an approved client, model, prompt, or tool request is harmless.

- Use the shortest practical session and run `termux-mcp shutdown` afterward.
- Keep Tailscale, Termux, Android, Node dependencies, and the repository up to date.
- Never share the MCP URL, consent password, TOTP secret, recovery codes, tokens, or backup archives.
- Use at least two factors where practical: consent password, TOTP, and device dialog.
- Revoke clients after an incident: `termux-mcp revoke`.
- Review `~/termux-mcp/audit.log`; command text is truncated but may still contain sensitive information if you put secrets in commands.

### Unrestricted mode

Never enable unrestricted mode on a device containing data you are unwilling to expose or modify. It can affect other tmux sessions, launch apps, alter files accessible to the Termux user, and cause data loss. Keep `MCP_ALLOW_UNRESTRICTED=0` by default and prefer the temporary unlock mechanism instead.

### Secrets and backups

Secret files are stored under `~/termux-mcp`, including `.consent_password`, `.totp_secret`, `.totp_recovery`, and OAuth state. Keep them owner-only:

```bash
chmod 700 ~/termux-mcp ~/mcp-work ~/mcp-ai-home
chmod 600 ~/termux-mcp/.consent_password \
  ~/termux-mcp/.totp_secret ~/termux-mcp/.totp_recovery 2>/dev/null || true
```

`termux-mcp backup` includes authentication secrets and configuration. Encrypt or otherwise protect the resulting archive; do not upload it to a public repository or issue.

### Third-party downloads and notifications

The installer and update command fetch files from GitHub with `curl`; updates are not a substitute for review or signature verification. Inspect changes before running them. If ntfy is enabled, choose a random private topic and understand that the notification service is an external dependency.

## Troubleshooting

### `termux-mcp` is not found

```bash
ls -la ~/termux-mcp
command -v termux-mcp
ls -l "$PREFIX/bin/termux-mcp"
node --version
```

Reinstall dependencies or rerun the reviewed installer if the command or files are missing:

```bash
termux-mcp reinstall-deps
```

### `PUBLIC_URL is not set` or the server exits immediately

Start through `termux-mcp`, which supplies the URL. For a manual local/test run, set it explicitly:

```bash
PUBLIC_URL=http://127.0.0.1:8000 MCP_TEST=1 node ~/termux-mcp/server.mjs
termux-mcp show-server-log
```

Also check that `config.json` contains valid JSON and that `node_modules` is present.

### Tailscale or Funnel is unavailable

```bash
termux-mcp health
tailscale status
tailscale up
termux-mcp funnel status
termux-mcp test-url
```

If Funnel is not enabled, enable it in the Tailscale admin console. Confirm that the local server is listening on port 8000 and that the Funnel points to `127.0.0.1:8000`.

### OAuth authorization fails

Check the exact URL and redirect host, then inspect the log:

```bash
termux-mcp url
termux-mcp password
termux-mcp factors
termux-mcp audit
```

OAuth requires PKCE S256 and the redirect URI must match a registered allowed host. If credentials may be exposed, rotate and restart:

```bash
termux-mcp reset-password
termux-mcp revoke
termux-mcp restart
```

With TOTP enabled, verify the device clock and use a recovery code only once. Five failed TOTP attempts within the lockout window trigger a temporary lockout by default.

### Requests return `Locked`

This is expected for mutating tools. Explicitly unlock for a short period, then lock again:

```bash
termux-mcp unlock 5
# perform the approved operation
termux-mcp lock
```

### File operations fail

Confirm the path is relative to `~/mcp-work`, the extension is allowed, the content is under 128 KiB, and the file is not a protected path:

```bash
ls -ld ~/mcp-work
termux-mcp info
```

### The isolated tmux session fails or commands time out

```bash
termux-mcp sessions
termux-mcp show-ai-screen
termux-mcp show-server-log
termux-mcp stop
termux-mcp start
```

Commands are intentionally time-limited, command chaining is blocked, and the isolated session may be removed after inactivity. Send one command at a time and read the session output afterward.

### Android apps are missing from `list_apps`

Android 11+ package visibility rules may prevent Termux from listing every installed app. This is a platform permission limitation, not necessarily a server failure.

### The phone is slow or storage is filling

Stop the service, inspect disk use, and rotate or export the audit log:

```bash
termux-mcp stop
termux-mcp disk
termux-mcp audit-stats
termux-mcp export-audit
```

## Uninstall

Use the reviewed uninstall script or remove the installation manually:

```bash
termux-mcp shutdown-all
bash ~/termux-mcp/../termux-mcp-uninstall.sh  # only if you downloaded this file
```

The repository's `uninstall.sh` removes `~/termux-mcp`, `~/mcp-work`, `~/mcp-ai-home`, and the installed CLI wrappers, but intentionally does **not** remove the Termux packages `nodejs`, `tmux`, `jq`, or Tailscale. It also does not remove the ChatGPT/MCP connector; revoke and delete that separately.

If you run the script directly from the repository checkout:

```bash
curl -fsSL -o termux-mcp-uninstall.sh \
  https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/uninstall.sh
less termux-mcp-uninstall.sh
bash termux-mcp-uninstall.sh
```

## Development and tests

The project is primarily JavaScript/Node.js with Bash management scripts. From `~/termux-mcp`:

```bash
npm install
node --test test.mjs
MCP_TEST=1 MCP_DATA_DIR="/tmp/termux-mcp-test" node --test test-http.mjs
```

`stdio-server.mjs` provides the local stdio transport. `server.mjs` provides the HTTP server, while `http.mjs`, `oauth.mjs`, `tools.mjs`, `state.mjs`, `audit.mjs`, `config.mjs`, and `lib.mjs` implement the HTTP, authentication, tool, state, audit, configuration, and safety layers.

## License

MIT License. See [LICENSE](LICENSE).
