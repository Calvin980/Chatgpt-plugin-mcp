# Termux MCP

Run an MCP (Model Context Protocol) server on Android and connect it to ChatGPT via OAuth 2.1.

## What This Project Does

**Termux MCP** lets you connect your Android device to ChatGPT through a secure tunnel. ChatGPT can then:
- Execute commands on your Android device
- Read and write files in a sandboxed directory
- List and launch apps
- Access system information (CPU, disk, uptime)
- Run interactive sessions via tmux

All communication is protected by OAuth 2.1 authentication and runs in a restricted sandbox by default.

### Real-World Example

1. You start the Termux MCP server on your Android phone via Termux
2. The server generates a unique public tunnel URL (via Cloudflared)
3. You configure ChatGPT with this URL
4. ChatGPT requests access; you approve by entering a consent password
5. ChatGPT can now run tools like `read_file`, `write_file`, `list_dir`, or execute shell commands in an isolated session
6. All requests are logged in an audit file for review

### Key Features

- **OAuth 2.1 authentication** — User-configured, consent-based
- **Runs on Android via Termux** — Turns your phone into a server
- **Sandboxed file access** — Confined to `~/mcp-work` by default
- **Audit logging** — Every action is recorded and timestamped
- **Restricted mode** (default) — ChatGPT can only access allowed tools and directories
- **Unrestricted mode** (optional) — Full command execution (use with caution)
- **Easy install and management** — Single script, simple CLI commands

---

## ⚠️ Critical Security Notice (Read This First)

Security is a top concern when exposing services on a personal device. This section is intentionally at the top.

### Before You Install — Three Golden Rules

1. **Download and inspect the install script first**
    ```bash
    curl -fsSL -o termux-mcp-install.sh https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh
    less termux-mcp-install.sh   # review before running
    bash termux-mcp-install.sh
    ```
    Never use: `bash <(curl -sL https://...)`

2. **Keep secrets out of version control**
    - OAuth client secrets, tokens, API keys must never be committed
    - Store in files with `chmod 600` permissions
    - Use environment files or Android keystore

3. **Public tunnels expose to the internet**
    - Use short-lived tunnels; stop when not needed
    - Monitor audit logs regularly
    - Restrict OAuth scopes to what you actually need

### Security Checklist

| Task | Command | Why |
|------|---------|-----|
| **Secure work directory** | `chmod 700 ~/mcp-work` | Only your user can access |
| **Secure secret files** | `chmod 600 ~/.mcp_env` | Prevents other users from reading |
| **Secure entire tree** | `chmod -R go-rwx $MCP_WORK_DIR` | Removes all group/other permissions |
| **Review audit logs** | `termux-mcp audit` | Detect unauthorized access |
| **Stop when not using** | `termux-mcp stop` | Closes tunnel, reduces exposure |
| **Avoid root** | Run as unprivileged user | Limits damage if compromised |
| **Keep Termux updated** | `pkg update && pkg upgrade` | Patches security vulnerabilities |

---

## How It Works Under the Hood

### Architecture

```
ChatGPT (via plugin)
    ↓ (OAuth 2.1 + Bearer token)
Cloudflared Tunnel (public HTTPS)
    ↓ (reverse proxy)
Termux MCP Server (127.0.0.1:8000)
    ├─ OAuth endpoints (/authorize, /token, /register)
    ├─ MCP endpoint (/mcp)
    ├─ Rate limiting (per IP)
    ├─ Audit logging
    └─ Tool execution (isolated tmux session)
    ↓
Android Device (Termux)
    ├─ ~/mcp-work/ (sandboxed files)
    ├─ mcp-ai-home/ (isolated session home)
    └─ Restricted commands (no root access by default)
```

### The Install Script Does This

The `install.sh` script performs these steps automatically:

1. **Install dependencies**: Node.js (LTS), Cloudflared (tunneling), tmux (session management)
2. **Set up directory structure**:
    ```
    ~/termux-mcp/           ← MCP server code and configs
    ~/mcp-work/             ← Default sandbox for file operations
    ~/mcp-ai-home/          ← Isolated home for ChatGPT sessions
    ```
3. **Generate OAuth consent password**: Stored in `~/.consent_password` (permissions 600)
4. **Create server code**: Embeds `server.mjs` (HTTP + OAuth + MCP tools) and `stdio-server.mjs` (STDIO mode)
5. **Install CLI commands**: `termux-mcp`, `termux-mcp-stdio` in `$PREFIX/bin`
6. **Set permissions**: Makes scripts executable, work directory restrictive

### How OAuth Works

1. **Client registration** — ChatGPT registers itself with the MCP server, gets a `client_id`
2. **Authorization request** — ChatGPT redirects you to `/authorize` with a code challenge (PKCE)
3. **User approval** — You enter your consent password to approve access
4. **Authorization code** — Server redirects back to ChatGPT with a time-limited code
5. **Token exchange** — ChatGPT exchanges the code for an access token (Bearer token)
6. **Authenticated requests** — ChatGPT uses the token to call MCP tools; server validates on each request

Each token expires after 30 minutes. ChatGPT must request a new token to continue.

### Sandbox Isolation

- **File operations** are confined to `~/mcp-work/`; paths outside are rejected
- **Allowed file extensions** (default): `.txt`, `.md`, `.json`, `.csv`, `.log`, `.yaml`, `.yml`, `.toml`, `.ini`, `.conf`, `.html`, `.css`, `.xml`, `.svg`
- **File size limit** (default): 128 KB per write
- **Shebang protection**: Scripts starting with `#!` are rejected
- **Session isolation** (restricted mode): ChatGPT runs in a dedicated tmux session with its own home directory, isolated from your main shell environment

### Available Tools

| Tool | What It Does | Restricted Mode | Unrestricted Mode |
|------|---|---|---|
| `whoami` | Show current user | ✓ | ✓ |
| `pwd` | Show work directory | ✓ | ✓ |
| `date` | Show system time | ✓ | ✓ |
| `system_info` | CPU, uptime, disk | ✓ | ✓ |
| `list_apps` | List installed Android apps | ✓ | ✓ |
| `open_app` | Launch an app by package name | ✓ | ✓ |
| `list_dir` | List files in `~/mcp-work/` | ✓ | ✓ |
| `read_file` | Read file in `~/mcp-work/` | ✓ | ✓ |
| `write_file` | Write/create file in `~/mcp-work/` | ✓ | ✓ |
| `append_file` | Append to file in `~/mcp-work/` | ✓ | ✓ |
| `tmux` (isolated) | Run commands in isolated session | ✓ | ✓ |
| `tmux` (any session) | Access other tmux sessions | ✗ | ✓ |

---

## Prerequisites

Before you begin, ensure you have:
- An Android device with Termux installed ([Download Termux](https://termux.dev))
- A stable internet connection
- A ChatGPT account with plugin access
- Basic familiarity with command-line interfaces
- ~200 MB free storage for Node.js and dependencies

---

## Installation

### Step 1: Download and Inspect the Install Script

```bash
curl -fsSL -o termux-mcp-install.sh https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh
less termux-mcp-install.sh   # review the script for suspicious or destructive commands
```

Look for any commands that seem destructive or suspicious. If you are satisfied, proceed to Step 2.

### Step 2: Run the Install Script

```bash
bash termux-mcp-install.sh
```

This script will:
- Update and upgrade Termux packages
- Install Node.js, Cloudflared (tunnel), and tmux
- Download and configure the MCP server code
- Create the required `~/mcp-work` and `~/mcp-ai-home` directories
- Generate a consent password for OAuth approval
- Install CLI commands (`termux-mcp`, `termux-mcp-stdio`)

### Step 3: Secure the Work Directory

```bash
chmod 700 "$HOME/mcp-work"
```

This ensures only your user can read, write, or execute files in the work directory.

### Quick Install (Less Safe; Only if You Trust the Source)

If you have reviewed the script and trust the source, you can pipe directly:

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
```

**⚠️ Note**: This bypasses the review step and runs code immediately. Only use if you have confirmed the script is safe.

---

## Secrets and Environment Variables

### Storing Credentials Safely

- **Do NOT commit secrets** to the repository or push them to public branches.
- **Keep secrets in restricted files**: `chmod 600 /path/to/secret`
- **Preferred secure storage**:
  - Android keystore
  - Termux `termux-keystore` (if available)
  - Dedicated password manager
  - Encrypted files (beyond scope of this project)

### Loading Environment Variables Securely

Create a secure secrets file:

```bash
# ~/.mcp_env (keep this file secret!)
export MCP_PORT=8000
export MCP_WORK_DIR="$HOME/mcp-work"
export OAUTH_CLIENT_ID="your-client-id"
export OAUTH_CLIENT_SECRET="your-client-secret"
```

Set restrictive permissions:
```bash
chmod 600 ~/.mcp_env
```

Load it explicitly when starting the server:
```bash
source ~/.mcp_env
termux-mcp
```

**Why?** Exporting secrets into long-lived shell sessions or shell profiles exposes them to:
- Process inspection (`ps aux`)
- Shell history files
- Other users on shared systems

---

## OAuth and Plugin Configuration

- **Client secrets are passwords** — Treat them with the same security as passwords
- **Minimal scopes required** — Request only the scopes your plugin needs, not everything available
- **Short-lived tokens** — This server uses 30-minute access tokens; implement token rotation if needed
- **Revoke immediately** — If you suspect a compromise, revoke plugin access in ChatGPT settings and regenerate credentials

---

## Tunnels and Network Exposure

Public tunnels make your MCP service reachable from the internet — this is convenient but increases risk.

### Safe Tunnel Practices

- **Prefer authenticated tunnels** — Add an additional layer: basic auth, JWT validation, or IP allowlists in front of MCP
- **Use short-lived tunnels** — Create tunnels only when actively using ChatGPT; stop them when done
- **Monitor activity** — Review audit logs for unusual access patterns
- **Run a reverse proxy** (if possible) — Use Nginx or similar to terminate TLS, enforce authentication, and rate-limit before traffic reaches MCP

### Cloudflared Tunnel (Default)

The install script uses Cloudflared to create a public tunnel:

```bash
# View the current tunnel URL and check status
cat ~/termux-mcp/.last_url

# View recent audit activity
termux-mcp audit

# Stop the tunnel
termux-mcp stop
```

Each tunnel is unique and ephemeral. When you stop the server, the URL is no longer accessible.

---

## Hardening the Runtime

1. **Run unprivileged** — Never run the MCP server as `root` or with `sudo`
2. **Strict directory permissions**:
    ```bash
    chmod 700 "$MCP_WORK_DIR"
    chmod -R go-rwx "$MCP_WORK_DIR"
    ```
3. **Limit file access** — Do not point `MCP_WORK_DIR` at sensitive locations (e.g., `/data/data/...` or your home directory)
4. **Keep Termux updated**:
    ```bash
    pkg update && pkg upgrade
    ```
5. **Device-level protection**:
    - Enable screen lock and device encryption
    - Keep Android OS updated
    - Review SELinux policies if available

---

## Logging and Monitoring

- **Audit logs** — Every MCP request is logged to `~/termux-mcp/audit.log`
- **Avoid logging secrets** — Tokens, passwords, and private keys must never appear in logs
- **Rotate logs regularly** — Clean up old logs to prevent disk space issues
- **Monitor for suspicious activity**:
  ```bash
  termux-mcp audit        # view last 50 entries
  tail -f ~/termux-mcp/audit.log   # stream in real-time
  ```

---

## Usage

### Starting the Server (Restricted Mode — Default)

```bash
termux-mcp
```

The server will:
- Initialize the MCP server on `127.0.0.1:8000`
- Create a public tunnel via Cloudflared
- Generate a unique tunnel URL (e.g., `https://xxxxx.trycloudflare.com`)
- Log all activity to the audit file
- Wait for incoming ChatGPT connections

Output:
```
============================================
✓ Termux MCP running (restricted)
============================================
MCP URL:  https://xxxxx.trycloudflare.com/mcp
Auth:     OAuth + consent password
Password: abc123def456
```

### Starting the Server (Unrestricted Mode)

```bash
termux-mcp unrestricted
```

**⚠️ Warning**: Unrestricted mode allows ChatGPT to run arbitrary commands and access any tmux session. Use only if you fully understand the risks.

### Stopping the Server

```bash
termux-mcp stop
```

This gracefully stops the MCP server and closes all tunnels. The tunnel URL becomes inaccessible.

### Viewing Server Status

```bash
cat ~/termux-mcp/.last_url      # show the tunnel URL
ps aux | grep node              # check if server is running
```

### Viewing Audit Logs

```bash
termux-mcp audit                # show last 50 entries
tail -n 100 ~/termux-mcp/audit.log   # show last 100 entries
tail -f ~/termux-mcp/audit.log  # stream entries in real-time
```

### Retrieving the Consent Password

```bash
termux-mcp password
```

Or view directly:
```bash
cat ~/termux-mcp/.consent_password
```

---

## Configuration

### Environment Variables

You can configure the server behavior by setting environment variables. Keep these in a secure file (see "Secrets and Environment Variables" above).

```bash
# Optional: Set custom port (default: 8000)
export MCP_PORT=8000

# Optional: Set custom work directory (default: ~/mcp-work)
export MCP_WORK_DIR=~/mcp-work

# Optional: Enable debug logging (don't enable in production)
export MCP_DEBUG=true

# Optional: Unrestricted mode (1 = unrestricted, 0 = restricted)
export MCP_ALLOW_UNRESTRICTED=0

# Optional: Set public URL (useful behind proxies)
export PUBLIC_URL="https://your-domain.com"
```

### ChatGPT Plugin Setup

1. In ChatGPT, go to **Settings → Plugins** (or similar, depending on your version)
2. Click **Add a new plugin** or **Create Plugin**
3. Configure the following:
    - **Name**: Termux MCP
    - **MCP Server URL**: Use the tunnel URL from `termux-mcp` output (e.g., `https://xxxxx.trycloudflare.com/mcp`)
    - **Authentication Method**: OAuth 2.1
    - **Authorization URL**: `https://xxxxx.trycloudflare.com/authorize`
    - **Token URL**: `https://xxxxx.trycloudflare.com/token`
4. Leave **Client ID** and **Client Secret** blank (they are auto-generated by the server)
5. Click **Authorize** or similar
6. You'll be redirected to the approval page. Enter the consent password (from `termux-mcp password`)
7. Click **Approve**

**Permissions**: Grant only the permissions your plugin needs. Avoid blanket access.

---

## Uninstallation

### Safer Uninstall Workflow

1. Stop the server and close tunnels:
    ```bash
    termux-mcp stop
    ```

2. Revoke OAuth tokens and remove plugin access in ChatGPT settings.

3. Remove local files carefully (verify paths before deleting):
    ```bash
    rm -rf "$HOME/mcp-work"
    rm -rf "$HOME/termux-mcp"
    ```

4. (Optional) Remove the global commands:
    ```bash
    rm "$PREFIX/bin/termux-mcp"
    rm "$PREFIX/bin/termux-mcp-stdio"
    ```

### Quick Uninstall

If using a provided uninstall script, review it first:

```bash
curl -fsSL -o termux-mcp-uninstall.sh https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/uninstall.sh
less termux-mcp-uninstall.sh
bash termux-mcp-uninstall.sh
```

---

## Recommended Secure Defaults

| Setting | Value | Rationale |
|---------|-------|-----------|
| **MCP_WORK_DIR** | `~/mcp-work` with permissions `700` | Isolates files; prevents other users from accessing |
| **Secret files** | Permissions `600` (read/write owner only) | Only you can read credentials |
| **Tunnel usage** | Ephemeral and authenticated | Reduces exposure window and unauthorized access |
| **OAuth scopes** | Least privilege (only needed ones) | Limits damage if token is compromised |
| **Run as** | Unprivileged user (not root) | Minimizes blast radius if server is compromised |
| **Updates** | Regular `pkg update && pkg upgrade` | Patches security vulnerabilities |
| **File extensions** | Restricted list (.txt, .md, .json, etc.) | Prevents executable code injection |
| **File size limit** | 128 KB per write | Prevents denial-of-service attacks |

---

## Contributing

Contributions are welcome. When submitting code or scripts:
- Avoid committing secrets or credentials of any kind
- Add clear documentation for security implications of changes
- Sign or provide checksums for release artifacts when possible
- Test locally before submitting pull requests

---

## Security Contact

If you discover a security vulnerability, please:
1. **Do NOT** post sensitive details publicly
2. Open an issue labeled "security" or contact the repository owner directly
3. Allow time for a fix before public disclosure

---

## License

MIT License

Copyright (c) 2024 Calvin980

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
