# Termux MCP

Run an MCP server on your Android phone and connect it to ChatGPT.

This is a small project that turns Termux into a tool server ChatGPT can call. It uses OAuth 2.1 so ChatGPT can authenticate, and Cloudflare Quick Tunnels so you don't need a domain or a VPS.

It works. It's also rough around the edges and not something you should leave running unattended.

---

## What it does

- Runs an MCP server inside Termux
- Exposes it over HTTPS via Cloudflare Quick Tunnel
- Authenticates ChatGPT with OAuth 2.1 + PKCE + Dynamic Client Registration
- Gives ChatGPT four tools: run a shell command, read a file, write a file, list a directory
- Everything runs on your phone. No VPS, no cloud account, no cost.

## What it doesn't do

- Keep the same URL across restarts (Cloudflare Quick Tunnels rotate)
- Sandbox commands in any meaningful way (see [Security](#security))
- Work with the ChatGPT mobile app (browser only, and you need a paid plan with Developer mode)
- Replace a real server. This is a toy that happens to be useful.

---

## Requirements

- Android with Termux from F-Droid (not the Play Store version)
- ChatGPT Plus, Pro, Team, Business, or Enterprise
- Developer mode enabled in ChatGPT settings
- A browser (custom connectors don't work in the ChatGPT mobile app)

---

## Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
