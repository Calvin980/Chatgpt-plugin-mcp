# Termux MCP — Connect ChatGPT to Your Android Device

Run an MCP (Model Context Protocol) server on Android via Termux and connect it securely to ChatGPT using OAuth 2.1. Control your phone directly from ChatGPT conversations.

## What This Project Does

**Termux MCP** turns your Android device into a remote computing resource that ChatGPT can access safely and securely. ChatGPT can:

- 🔧 **Execute shell commands** in an isolated session (sandboxed by default)
- 📁 **Read and write files** in a restricted directory
- 📱 **List and launch apps** by package name
- 📊 **Access system information** (CPU, uptime, disk, memory)
- 🖥️ **Run interactive sessions** via tmux (terminal multiplexer)

All communication is encrypted (HTTPS via Cloudflared) and protected by **OAuth 2.1 authentication** with a consent password.

### Real-World Example

1. You start the Termux MCP server on your Android phone via Termux
2. The server generates a unique public tunnel URL (via Cloudflared)
3. You configure ChatGPT with this URL and authorize it
4. ChatGPT can now use tools like `read_file`, `write_file`, `list_dir`, or execute commands
5. All requests are logged in an audit file for review

---

## ⚠️ Critical Security Notice (Read This First!)

**Security is paramount** when exposing a personal device to the internet. Please read this before installation.

### Three Golden Rules

1. **Download and inspect the install script first**  
   Never use: `bash <(curl -sL https://...)`  
   Always review:
   ```bash
   curl -fsSL -o termux-mcp-install.sh https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh
   less termux-mcp-install.sh   # review before running
   bash termux-mcp-install.sh
   ```

2. **Keep secrets out of version control**
   - OAuth client secrets, tokens, API keys must never be committed
   - Store in files with `chmod 600` permissions
   - Use environment files (see Secrets section)

3. **Public tunnels expose to the internet**
   - Use short-lived tunnels; stop when not needed
   - Monitor audit logs regularly
   - Restrict OAuth scopes to what you actually need

### Quick Security Checklist

| Task | Command | Why |
|------|---------|-----|
| **Secure work directory** | `chmod 700 ~/mcp-work` | Only your user can access |
| **Secure secret files** | `chmod 600 ~/.mcp_env` | Prevents other users from reading |
| **Review audit logs** | `termux-mcp audit` | Detect unauthorized access |
| **Stop when not using** | `termux-mcp stop` | Closes tunnel, reduces exposure |
| **Avoid root** | Run as unprivileged user | Limits damage if compromised |
| **Keep Termux updated** | `pkg update && pkg upgrade` | Patches security vulnerabilities |

---

## Key Features

- **OAuth 2.1 authentication** — User-configured, consent-based approval
- **Runs on Android via Termux** — Turns your phone into a remote server
- **Sandboxed file access** — Confined to `~/mcp-work` by default
- **Audit logging** — Every action is recorded with timestamp
- **Restricted mode (default)** — ChatGPT can only access allowed tools and directories
- **Unrestricted mode (optional)** — Full command execution (use with caution!)
- **Easy install and management** — Single script, simple CLI commands
- **Built on Model Context Protocol (MCP)** — Standard-based AI integration
- **PKCE-protected OAuth** — Industry-standard security for public clients

---

## Tech Stack

| Component | Purpose | Language |
|-----------|---------|----------|
| **server.mjs** | HTTP + OAuth + MCP tools server | JavaScript (Node.js) |
| **stdio-server.mjs** | STDIO mode for direct MCP integration | JavaScript (Node.js) |
| **install.sh** | Setup script (installs dependencies) | Bash Shell |
| **start.sh** | Start server with tunnel management | Bash Shell |
| **Dependencies** | `@modelcontextprotocol/sdk`, `express`, `jose`, `zod` | npm modules |

**Language Composition:** 74.4% JavaScript, 25.6% Shell

---

## Prerequisites

Before you begin, ensure you have:

- ✅ An Android device with **Termux** installed ([Download Termux](https://termux.dev))
- ✅ A stable internet connection
- ✅ A ChatGPT account with plugin access
- ✅ Basic comfort with command-line interfaces
- ✅ ~200 MB free storage for Node.js and dependencies

---

## Installation

### Step 1: Download and Inspect

```bash
curl -fsSL -o termux-mcp-install.sh https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh
less termux-mcp-install.sh   # review the script
```

### Step 2: Run Install Script

```bash
bash termux-mcp-install.sh
```

This will:
- Update and upgrade Termux packages
- Install Node.js, Cloudflared (tunnel), and tmux
- Download and configure the MCP server code
- Create required directories (`~/mcp-work`, `~/mcp-ai-home`)
- Generate a consent password for OAuth approval
- Install CLI commands (`termux-mcp`, `termux-mcp-stdio`)

### Step 3: Secure the Work Directory

```bash
chmod 700 "$HOME/mcp-work"
```

---

## Quick Start

### Start Server (Restricted Mode — Recommended)

```bash
termux-mcp
```

Output:
```
============================================
✓ Termux MCP running (restricted)
============================================
MCP URL:  https://xxxxx.trycloudflare.com/mcp
Auth:     OAuth + consent password
Password: abc123def456
```

### Common Commands

```bash
termux-mcp                    # start (restricted mode)
termux-mcp unrestricted       # start (full access — careful!)
termux-mcp stop               # stop server
termux-mcp password           # show consent password
termux-mcp audit              # view last 50 log entries
termux-mcp-stdio              # local STDIO mode (no tunnel)
```

---

## How It Works

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
    └─ Restricted commands (no root by default)
```

### What the Install Script Does

1. **Install dependencies**: Node.js (LTS), Cloudflared, tmux
2. **Set up directories**:
   ```
   ~/termux-mcp/           ← MCP server code and configs
   ~/mcp-work/             ← Default sandbox for file operations
   ~/mcp-ai-home/          ← Isolated home for ChatGPT sessions
   ```
3. **Generate OAuth consent password** (stored in `~/.consent_password`, permissions 600)
4. **Create server code** (embeds `server.mjs` and `stdio-server.mjs`)
5. **Install CLI commands** (`termux-mcp`, `termux-mcp-stdio` in `$PREFIX/bin`)
6. **Set permissions** (makes scripts executable, work directory restrictive)

### Available Tools

| Tool | Purpose | Restricted | Unrestricted |
|------|---------|:-:|:-:|
| `whoami` | Show current user | ✓ | ✓ |
| `pwd` | Show work directory | ✓ | ✓ |
| `date` | Show system time | ✓ | ✓ |
| `system_info` | CPU, uptime, disk | ✓ | ✓ |
| `list_apps` | List installed apps | ✓ | ✓ |
| `open_app` | Launch an app | ✓ | ✓ |
| `list_dir` | List files in `~/mcp-work/` | ✓ | ✓ |
| `read_file` | Read file in `~/mcp-work/` | ✓ | ✓ |
| `write_file` | Write/create file in `~/mcp-work/` | ✓ | ✓ |
| `append_file` | Append to file in `~/mcp-work/` | ✓ | ✓ |
| `tmux` (isolated) | Run commands in isolated session | ✓ | ✓ |
| `tmux` (any session) | Access other tmux sessions | ✗ | ✓ |

### Sandbox Isolation (Restricted Mode)

- **File operations** confined to `~/mcp-work/` (paths outside are rejected)
- **Allowed file extensions** (by default): `.txt`, `.md`, `.json`, `.csv`, `.log`, `.yaml`, `.yml`, `.toml`, `.ini`, `.conf`, `.html`, `.css`, `.xml`, `.svg`
- **File size limit**: 128 KB per write operation
- **Shebang protection**: Scripts starting with `#!` are rejected
- **Session isolation**: ChatGPT runs in its own tmux session (`mcp-ai`) with isolated home directory (`~/mcp-ai-home`)

### OAuth 2.1 Flow

1. **Client registration** — ChatGPT registers with MCP server, gets a `client_id`
2. **Authorization request** — ChatGPT redirects you to `/authorize` with PKCE challenge
3. **User approval** — You enter your consent password to approve access
4. **Authorization code** — Server issues a time-limited code
5. **Token exchange** — ChatGPT exchanges code for an access token (Bearer token)
6. **Authenticated requests** — ChatGPT uses the token; server validates each request

**Token lifetime**: 30 minutes (then ChatGPT must request a new token)

---

## Configuration

### Environment Variables

Create a secure file `~/.mcp_env`:

```bash
# ~/.mcp_env (keep this file secret!)
export MCP_PORT=8000
export MCP_WORK_DIR="$HOME/mcp-work"
export MCP_DEBUG=false
export MCP_ALLOW_UNRESTRICTED=0
export PUBLIC_URL="https://your-domain.com"  # if behind a proxy
```

Set restrictive permissions:
```bash
chmod 600 ~/.mcp_env
```

Load it when starting:
```bash
source ~/.mcp_env
termux-mcp
```

### ChatGPT Plugin Setup

1. In ChatGPT, go to **Settings → Plugins** (or similar)
2. Click **Add a new plugin** or **Create Plugin**
3. Configure:
   - **Name**: Termux MCP
   - **MCP Server URL**: `https://xxxxx.trycloudflare.com/mcp` (from server output)
   - **Authentication Method**: OAuth 2.1
   - **Authorization URL**: `https://xxxxx.trycloudflare.com/authorize`
   - **Token URL**: `https://xxxxx.trycloudflare.com/token`
4. Leave **Client ID** and **Client Secret** blank (auto-generated)
5. Click **Authorize**, enter consent password from `termux-mcp password`
6. Click **Approve**

---

## Secrets and Environment Variables

### Storing Credentials Safely

- **Do NOT commit secrets** to the repository
- **Keep secrets in restricted files**: `chmod 600 /path/to/secret`
- **Preferred storage**:
  - Termux `termux-keystore` (if available)
  - Encrypted files
  - Dedicated password manager
  - Android Keystore (advanced)

### Why Environment Variables Can Be Unsafe

Exporting secrets into long-lived shell sessions exposes them to:
- Process inspection (`ps aux`)
- Shell history files
- Other users on shared systems

**Better approach**: Load from a secure file when starting the server, then unset the variables.

---

## Tunnels and Network Exposure

### Safe Practices

- **Use short-lived tunnels** — Create only when actively using ChatGPT; stop when done
- **Monitor audit logs** — Check `termux-mcp audit` regularly for unusual activity
- **Prefer authenticated tunnels** — Add extra authentication layers if possible
- **Run reverse proxy** (optional) — Use Nginx to terminate TLS and rate-limit before MCP

### Cloudflared Tunnel (Default)

```bash
# View current tunnel URL
cat ~/termux-mcp/.last_url

# View audit activity
termux-mcp audit

# Stop the tunnel
termux-mcp stop
```

Each tunnel is unique and ephemeral. When you stop the server, the URL is no longer accessible.

---

## Logging and Monitoring

- **Audit logs** — Every MCP request logged to `~/termux-mcp/audit.log`
- **Avoid logging secrets** — Tokens, passwords, and private keys never appear in logs
- **Rotate logs regularly** — Clean old logs to prevent disk space issues

### View Logs

```bash
termux-mcp audit              # last 50 entries
tail -f ~/termux-mcp/audit.log   # stream in real-time
ls -lh ~/termux-mcp/audit.log    # check file size
```

### Rotate Logs

```bash
# Backup and clear
cp ~/termux-mcp/audit.log ~/termux-mcp/audit.log.backup
truncate -s 0 ~/termux-mcp/audit.log
```

---

## Hardening the Runtime

1. **Run unprivileged** — Never use `root` or `sudo`
2. **Strict permissions**:
   ```bash
   chmod 700 "$MCP_WORK_DIR"
   chmod -R go-rwx "$MCP_WORK_DIR"
   ```
3. **Limit file access** — Don't point `MCP_WORK_DIR` at sensitive locations
4. **Keep Termux updated**:
   ```bash
   pkg update && pkg upgrade
   ```
5. **Device-level protection**:
   - Enable screen lock and encryption
   - Keep Android OS updated
   - Review SELinux policies if available

---

## Uninstallation

### Safe Uninstall

1. Stop the server:
   ```bash
   termux-mcp stop
   ```

2. Revoke OAuth tokens in ChatGPT settings

3. Remove local files:
   ```bash
   rm -rf "$HOME/mcp-work"
   rm -rf "$HOME/termux-mcp"
   ```

4. (Optional) Remove CLI commands:
   ```bash
   rm "$PREFIX/bin/termux-mcp"
   rm "$PREFIX/bin/termux-mcp-stdio"
   ```

---

## Troubleshooting

### Server Won't Start

**Problem**: `termux-mcp` command not found or server fails to start.

**Solutions**:
```bash
ls -la ~/termux-mcp/        # check if installed
which termux-mcp            # check if in PATH
node --version              # verify Node.js installed
pkg update && pkg upgrade   # update packages
bash termux-mcp-install.sh  # reinstall
```

### Cloudflared Tunnel Not Connecting

**Problem**: Tunnel URL shows error or ChatGPT cannot reach the server.

**Solutions**:
```bash
ping google.com                    # check internet
ps aux | grep cloudflared          # verify cloudflared running
cat ~/termux-mcp/.last_url         # check URL
termux-mcp stop && termux-mcp      # restart
```

### OAuth Authorization Fails

**Problem**: ChatGPT cannot authorize or consent password is rejected.

**Solutions**:
```bash
termux-mcp password          # retrieve password (case-sensitive!)
termux-mcp audit             # check authorization logs
rm ~/.consent_password       # regenerate password
termux-mcp stop && termux-mcp  # restart with new password
```

### File Operations Not Working

**Problem**: ChatGPT cannot read/write files; permission errors.

**Solutions**:
```bash
ls -ld ~/mcp-work                 # verify directory exists
chmod 700 ~/mcp-work              # fix permissions
ls -la ~/mcp-work/                # verify files inside
ls -lah ~/mcp-work/your-file      # check file size (max 128 KB)
tail -f ~/termux-mcp/audit.log    # check error details
```

### Commands Timeout or Hang

**Problem**: MCP commands hang or timeout; no response.

**Solutions**:
```bash
ps aux | grep node              # check server running
netstat -tulpn | grep 8000      # verify listening
top -n 1                        # check CPU/memory
termux-mcp stop && termux-mcp   # restart
```

### Audit Logs Growing Too Large

**Problem**: Audit log consuming excessive disk space.

**Solutions**:
```bash
ls -lh ~/termux-mcp/audit.log                # check size
cp ~/termux-mcp/audit.log ~/termux-mcp/audit.log.backup
truncate -s 0 ~/termux-mcp/audit.log         # clear
```

### Device Performance Degradation

**Problem**: Phone becomes slow or unresponsive.

**Solutions**:
```bash
termux-mcp stop               # stop when not in use
top -n 1                      # monitor resources
termux-mcp                    # use restricted mode (less resources)
```

### ChatGPT Plugin Works Intermittently

**Problem**: Sometimes commands succeed, sometimes fail.

**Solutions**:
```bash
ping -c 5 google.com                        # check network
ps aux | grep node                          # verify server running
ps aux | grep cloudflared                   # verify tunnel running
termux-mcp audit                            # check for rate limiting (429 errors)
termux-mcp stop && sleep 2 && termux-mcp    # restart
```

---

## Recommended Secure Defaults

| Setting | Value | Rationale |
|---------|-------|-----------|
| **MCP_WORK_DIR** | `~/mcp-work` (permissions `700`) | Isolates files; prevents unauthorized access |
| **Secret files** | Permissions `600` (owner read/write only) | Only you can read credentials |
| **Tunnel usage** | Ephemeral and authenticated | Reduces exposure window |
| **OAuth scopes** | Least privilege (only needed) | Limits damage if token compromised |
| **Run as** | Unprivileged user (not root) | Minimizes blast radius if compromised |
| **Updates** | Regular `pkg update && pkg upgrade` | Patches security vulnerabilities |
| **File extensions** | Restricted list (.txt, .md, .json, etc.) | Prevents executable code injection |
| **File size limit** | 128 KB per write | Prevents denial-of-service attacks |
| **Token lifetime** | 30 minutes | Forces regular re-authentication |

---

## Contributing

Contributions are welcome! When submitting code or scripts:

- Avoid committing secrets or credentials
- Add clear documentation for security implications
- Sign or provide checksums for release artifacts
- Test locally before submitting pull requests
- Follow existing code style (see `server.mjs` and shell scripts)

---

## Security Contact

If you discover a security vulnerability:

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
