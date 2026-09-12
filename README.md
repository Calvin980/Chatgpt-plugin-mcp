# Termux MCP

Run an MCP (Model Context Protocol) server on Android and connect it to ChatGPT via OAuth 2.1.

## Overview

Termux MCP enables you to integrate your Android device with ChatGPT by running a Model Context Protocol server on Termux. This allows ChatGPT to interact with your Android environment through a secure OAuth 2.1 tunnel.

**Key Features:**
- OAuth 2.1 authentication (configured by the user)
- Runs on Android via Termux
- File access confined to `~/mcp-work` directory by default
- Easy installation and management
- Public tunnel connectivity for remote access (use with care)

---

## ⚠️ Critical Security Notice (Read First)

Security is a top concern when exposing services on a personal device. **Do not skip this section.**

### Before You Install

- **Inspect scripts before running**: Download, review, and verify the install script—never pipe remote scripts directly into bash.
- **Never commit secrets**: OAuth credentials, tokens, API keys must never be in version control.
- **File permissions matter**: Use `chmod 700 ~/mcp-work` and `chmod 600` for files containing secrets.
- **Public tunnels = internet exposure**: Short-lived tunnels, restricted scopes, and monitoring are essential.
- **Run unprivileged**: Avoid running the MCP server as root or with escalated privileges.

### Key Security Principles

| Concern | Best Practice |
|---------|---|
| **Code Review** | Download install script first: `curl -fsSL -o termux-mcp-install.sh https://...` then review with `less termux-mcp-install.sh` before running |
| **Credentials** | Store in files with `chmod 600`; never export to long-lived shell sessions; use Android keystore if available |
| **OAuth Scopes** | Use least privilege: only request scopes your plugin actually needs |
| **Tunnel Access** | Prefer authenticated tunnels; add IP allowlists or JWT auth in front of MCP endpoint |
| **Permissions** | `chmod 700 ~/mcp-work` (directory), `chmod 600` (secret files), `chmod -R go-rwx $MCP_WORK_DIR` (entire tree) |
| **Monitoring** | Keep audit logs; rotate logs regularly; avoid logging secrets |

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

### Step 1: Download and Inspect the Install Script (Recommended)

```bash
curl -fsSL -o termux-mcp-install.sh https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh
less termux-mcp-install.sh   # review the script for suspicious or destructive commands
```

If you are satisfied with the script, proceed to Step 2.

### Step 2: Run the Install Script

```bash
bash termux-mcp-install.sh
```

This script will:
- Update and upgrade Termux packages
- Install Node.js, Cloudflared (tunnel), and tmux
- Download and configure the MCP server code
- Create the required `~/mcp-work` directory
- Generate a consent password for OAuth approval

### Step 3: Secure the Work Directory

```bash
chmod 700 "$HOME/mcp-work"
```

This ensures only your user can read, write, or execute files in the work directory.

### Quick Install (Less Safe)

If you trust the source and have reviewed the script above, you can pipe directly:

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
```

**⚠️ Note**: This bypasses the review step and runs code immediately. Use only if you have confirmed the script is safe.

---

## Secrets and Environment Variables

### Storing Credentials Safely

- Do NOT commit secrets to the repository or push them to public branches.
- Keep secrets in files with strict permissions: `chmod 600 /path/to/secret`.
- Use secure storage where available:
  - Android keystore
  - Termux `termux-keystore` (if available)
  - A dedicated password manager

### Loading Environment Variables Securely

Create a secure secrets file:

```bash
# ~/.mcp_env (permissions 600)
export MCP_PORT=3000
export MCP_WORK_DIR="$HOME/mcp-work"
export OAUTH_CLIENT_ID="your-client-id"
export OAUTH_CLIENT_SECRET="your-client-secret"
```

Set permissions:
```bash
chmod 600 ~/.mcp_env
```

Load it when starting the server:
```bash
source ~/.mcp_env
termux-mcp
```

**Why?** Exporting secrets into long-lived shell sessions or shell profiles exposes them to process inspection and history files.

---

## OAuth and Plugin Configuration

- **Register securely**: Store OAuth client secrets like passwords—never in plain text files readable by others.
- **Minimal scopes**: Request only the scopes your plugin needs, not everything available.
- **Short-lived tokens**: Prefer access tokens with short TTL and implement token rotation.
- **Revoke immediately**: If you suspect a compromise, revoke plugin access in ChatGPT settings.

---

## Tunnels and Network Exposure

Public tunnels make your MCP service reachable from the internet — convenient but higher risk.

### Safe Tunnel Practices

- **Prefer authenticated tunnels** or add an additional layer (basic auth, JWT, or IP allowlist).
- **Use short-lived tunnels**: Create tunnels only when needed; revoke when done.
- **Monitor connections**: Review audit logs for unusual activity.
- **Reverse proxy**: If possible, run a reverse proxy (e.g., Nginx) that terminates TLS and enforces authentication instead of exposing MCP directly.

### Cloudflared Tunnel

The install script uses Cloudflared to create a public tunnel. Each tunnel URL is unique and time-limited.

```bash
# View the tunnel URL and status
termux-mcp status

# Stop the tunnel
termux-mcp stop

# View recent activity
termux-mcp audit
```

---

## Hardening the Runtime

1. **Run unprivileged**: Never run as `root` or with `sudo`.
2. **Strict directory permissions**:
   ```bash
   chmod 700 "$MCP_WORK_DIR"
   chmod -R go-rwx "$MCP_WORK_DIR"
   ```
3. **Limit file access**: Do not point `MCP_WORK_DIR` at sensitive locations (e.g., `/data/data/...` or your home directory).
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

- **Enable audit logs**: The server creates an audit log at `~/termux-mcp/audit.log`.
- **Avoid logging secrets**: Tokens, passwords, and private keys must never appear in logs.
- **Rotate logs**: Clean up old logs regularly to prevent disk space issues.
- **Monitor regularly**: Check audit logs for unusual activity:
  ```bash
  termux-mcp audit
  ```

---

## Usage

### Starting the Server (Restricted Mode)

```bash
termux-mcp
```

The server will:
- Initialize the MCP server
- Create a public tunnel via Cloudflared
- Generate a unique tunnel URL
- Display connection information
- Wait for incoming ChatGPT connections
- Log all activity to the audit file

### Starting the Server (Unrestricted Mode)

```bash
termux-mcp unrestricted
```

**⚠️ Warning**: Unrestricted mode allows ChatGPT to run arbitrary commands. Use only if you trust the source and understand the risks.

### Stopping the Server

```bash
termux-mcp stop
```

This gracefully stops the MCP server and closes all tunnels.

### Viewing Server Status

```bash
termux-mcp status
```

### Viewing Audit Logs

```bash
termux-mcp audit
```

Shows the last 50 audit entries.

### Retrieving the Consent Password

```bash
termux-mcp password
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
```

### ChatGPT Plugin Setup

1. In ChatGPT, go to **Settings → Plugins → My Plugins** (or similar, depending on your version).
2. Click **Add a new custom plugin** or **Create Plugin**.
3. Configure the following:
   - **Name**: Termux MCP
   - **MCP Server URL**: Use the tunnel URL from `termux-mcp` (e.g., `https://xxxxx.trycloudflare.com/mcp`)
   - **Authentication**: OAuth 2.1
   - **OAuth Callback URL**: Your plugin's configured callback
4. Leave **Client ID** and **Secret** blank (they are auto-generated by the server).
5. On the approval page, enter the consent password (from `termux-mcp password`).

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

4. (Optional) Remove the global command:
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

---

## Contributing

Contributions are welcome. When submitting code or scripts:
- Avoid committing secrets or credentials of any kind.
- Add clear documentation for security implications of changes.
- Sign or provide checksums for release artifacts when possible.
- Test locally before submitting pull requests.

---

## Security Contact

If you discover a security vulnerability, please:
1. **Do NOT** post sensitive details publicly.
2. Open an issue labeled "security" or contact the repository owner directly.
3. Allow time for a fix before disclosure.

---

## License

(keep existing license info here)
