# Termux MCP

Run an MCP (Model Context Protocol) server on Android and connect it to ChatGPT via OAuth 2.1.

## Overview

Termux MCP enables you to integrate your Android device with ChatGPT by running a Model Context Protocol server on Termux. This allows ChatGPT to interact with your Android environment through a public tunnel.

Security is a key concern when exposing services on a personal device. This README now includes explicit security guidance and safer installation steps to reduce the risk of credential leaks, remote compromise, or accidental data exposure.

**Key Features:**
- OAuth 2.1 authentication (configured by the user)
- Runs on Android via Termux
- File access confined to `~/mcp-work` directory by default
- Easy installation and management
- Public tunnel connectivity for remote access (use with care)

## Important security summary (read first)

- Do not run code you don't understand. Inspect install/uninstall scripts before executing them.
- Avoid piping remote scripts directly into `bash` or `sh`. Instead, download, inspect, and then run.
- Keep OAuth client IDs, client secrets, tokens, and other credentials out of version control and world-readable files.
- Use strict filesystem permissions for the work directory and any files that contain secrets: `chmod 700 ~/mcp-work` and `chmod 600` for secret files.
- Public tunnels expose services to the internet. Use short-lived tunnels, restrict scopes and permissions, and monitor activity.
- Run the MCP server under a dedicated, unprivileged user or account when possible.

## Prerequisites

Before you begin, ensure you have:
- An Android device with Termux installed ([Download Termux](https://termux.dev))
- A stable internet connection
- A ChatGPT account with plugin access
- Basic familiarity with command-line interfaces

## Installation

### Safer install workflow (recommended)

1. Download the install script to review it first:

```bash
curl -fsSL -o termux-mcp-install.sh https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh
less termux-mcp-install.sh   # review the script for suspicious or destructive commands
# If you are satisfied, run it explicitly
bash termux-mcp-install.sh
```

2. Verify checksums or signatures if provided by the project. If you trust a release tag, prefer installing from a release tarball with a signed checksum.

> Avoid: `bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)`
>
> Reason: piping remote code directly to a shell runs the code before you can review or verify it.

### Quick Install (less safe; only use if you trust the source and reviewed the script)

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
```

This script will:
- Download and configure the MCP server
- Set up necessary dependencies
- Configure environment variables
- Create the required `~/mcp-work` directory

After installation, ensure the work directory has restrictive permissions:

```bash
chmod 700 "$HOME/mcp-work"
```

## Secrets and environment variables

- Do NOT commit secrets (OAuth client secrets, tokens, API keys) to the repository.
- Keep secrets in files with strict permissions: `chmod 600 /path/to/secret`.
- Use secure storage where available (Android keystore, Termux `termux-keystore` if available, or a password manager).
- When exporting environment variables, prefer adding them to a file readable only by your account, e.g. `~/.mcp_env` with `chmod 600 ~/.mcp_env`, and load it from a shell profile only when needed.

Example:

```bash
# ~/.mcp_env (permissions 600)
export MCP_PORT=3000
export MCP_WORK_DIR="$HOME/mcp-work"
```

Load it when starting the server explicitly rather than leaving secrets exposed in long-lived shell sessions.

## OAuth and plugin configuration

- Register OAuth credentials securely in your ChatGPT plugin configuration. Treat client secrets like passwords.
- Use the minimal scopes required for the plugin's functionality.
- Prefer short-lived access tokens and implement token rotation where possible.
- Revoke plugin access immediately if you suspect a compromise.

## Tunnels and network exposure

Public tunnels make your service reachable from the internet — this is convenient but increases risk.

Recommendations:
- Prefer authenticated tunnels or add an additional layer of authentication (basic auth, JWT, or IP allowlist) in front of the MCP endpoint.
- Use short-lived or ephemeral tunnels when possible.
- Monitor connections and revoke tunnels when not in use.
- If you can, run a reverse proxy that terminates TLS and enforces authentication instead of exposing the MCP server directly.

## Hardening the runtime

- Run the MCP server as an unprivileged user and avoid running as `root` or with escalated privileges.
- Set strict permissions on the work directory and any files the server reads/writes: `chmod -R go-rwx $MCP_WORK_DIR`.
- Limit which files and directories the MCP server can access. Do not point `MCP_WORK_DIR` at sensitive locations.
- Keep Termux and all packages up to date: `pkg update && pkg upgrade`.
- Consider using Android-level protections (screen lock, device encryption, SELinux policies) and keep the device OS updated.

## Logging and monitoring

- Keep logs available for auditing, but avoid logging secrets (tokens, passwords, private keys).
- Rotate logs and ensure they are not world-readable.
- Monitor for unusual activity and enable any available alerting.

## Uninstallation (safe cleanup)

### Safer uninstall workflow

1. Stop the server and close any tunnels.

```bash
termux-mcp stop
```

2. Revoke OAuth tokens and remove plugin access in ChatGPT settings.

3. Remove local files with care; make sure you do not accidentally delete unrelated data. Example:

```bash
rm -rf "$HOME/mcp-work"      # only after confirming the path
```

4. If you used the quick uninstall script, inspect it before running it, same as install.

### Quick Uninstall

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/uninstall.sh)
```

## Recommended secure defaults

- MCP_WORK_DIR: `~/mcp-work` with permissions 700
- Secrets: files with permissions 600, or secure keystore
- Tunnel usage: ephemeral and authenticated
- OAuth scopes: least privilege
- Run: unprivileged account

## Usage

### Starting the Server

To start the MCP server and create a tunnel connection:

```bash
termux-mcp
```

The server will:
- Initialize the MCP server
- Generate a public tunnel URL (use with caution)
- Display connection information
- Wait for incoming ChatGPT connections

### Stopping the Server

To gracefully stop the server and close the tunnel:

```bash
termux-mcp stop
```

### Viewing Server Status

Check if the server is running and view current tunnel information:

```bash
termux-mcp status
```

## Configuration

### Environment Variables

You can configure the server behavior using environment variables. Keep these in a secure file with restrictive permissions.

```bash
# Optional: Set custom port (default: 3000)
export MCP_PORT=3000

# Optional: Set custom work directory (default: ~/mcp-work)
export MCP_WORK_DIR=~/mcp-work

# Optional: Enable debug logging (don't enable in production unless you need to troubleshoot)
export MCP_DEBUG=true
```

### ChatGPT Plugin Setup

1. In ChatGPT, go to Settings → Plugins
2. Add a new custom plugin
3. Configure the OAuth 2.1 callback URL
4. Enter the tunnel URL provided by `termux-mcp`
5. Authorize the plugin to access your MCP server

When setting up the plugin, use minimal scopes and avoid granting any permission that is not needed.

## Contributing

Contributions are welcome. When submitting code or scripts:
- Avoid committing secrets.
- Add clear documentation for security implications of changes.
- Sign or provide checksums for release artifacts when possible.

## Security contact

If you discover a security vulnerability, please open an issue labeled "security" or contact the repository owner directly. Do not post sensitive data publicly.

## License

(keep existing license info here)
