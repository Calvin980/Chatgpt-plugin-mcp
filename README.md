# Termux MCP

**An MCP server that runs on your phone.**

Termux + Node.js + a Cloudflare tunnel + OAuth 2.1 = ChatGPT gets a small, guarded set of tools on the device in your pocket. No VPS. No cloud account. No monthly bill.

There is no shell tool. That's the point.

> It works. It's also a hobby project — read [Security](#security) before you leave it running.

---

## What it does

- Runs an MCP server inside [Termux](https://termux.dev)
- Exposes it over HTTPS via a Cloudflare Quick Tunnel — no account, no domain
- Authenticates ChatGPT with **OAuth 2.1 + PKCE + Dynamic Client Registration + `private_key_jwt`**
- Hands ChatGPT eleven narrow tools: read files, write text with guards, list and launch apps, read system info, and drive a **sandboxed tmux session** that is separate from your own
- Two modes: **restricted** (default) and **unrestricted**

## What it doesn't do

- Keep the same URL across restarts. Quick tunnels rotate. See [The URL changes every restart](#the-url-changes-every-restart).
- Work with the ChatGPT mobile app. Custom connectors are browser-only.
- Give ChatGPT a general shell. There is no `run_command`. By design.
- Pretend to be production infrastructure. It's a toy that happens to be useful.

---

## Why "no shell tool" is the whole idea

Most MCP setups hand the model a `run_command` tool and hope for the best. That's a shell. A shell is `python3 -c "..."` away from full device control. You spend your time building allowlists that don't work, because `git -c core.sshCommand="..."` and `node -e "..."` all start with allowed words.

This project doesn't do that.

Instead of one dangerous tool, there are eleven boring ones. Each does exactly one thing. Each has a guard. If ChatGPT gets prompt-injected, the worst it can do is write a text file inside `~/mcp-work` or type into a tmux session it isn't allowed to reach.

That trade — flexibility for a smaller attack surface — is the entire point of the design.

---

## Requirements

- Android with [Termux from F-Droid](https://f-droid.org/packages/com.termux/) (not the Play Store build)
- ChatGPT Plus, Pro, Team, Business, or Enterprise with **Developer mode** enabled
- A browser — `chatgpt.com` on mobile browser works; the native app does not
- ~500 MB free storage

---

## Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
