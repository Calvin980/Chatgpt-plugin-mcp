<div align="center">

# 🧠 Termux MCP

**Turn your Android phone into a secure MCP server that ChatGPT can talk to.**

A lightweight, self-hosted [Model Context Protocol](https://modelcontextprotocol.io) server that runs entirely inside [Termux](https://termux.dev) and connects to ChatGPT as a custom connector — with **OAuth 2.1** authentication and a free Cloudflare tunnel.

[![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Android-3DDC84?style=flat-square&logo=android&logoColor=white)](https://termux.dev)
[![Runtime](https://img.shields.io/badge/runtime-Node.js%20LTS-339933?style=flat-square&logo=nodedotjs&logoColor=white)](https://nodejs.org)
[![Protocol](https://img.shields.io/badge/protocol-MCP-000000?style=flat-square)](https://modelcontextprotocol.io)
[![Auth](https://img.shields.io/badge/auth-OAuth%202.1-4A90E2?style=flat-square)](https://oauth.net/2.1/)
[![Footprint](https://img.shields.io/badge/footprint-%3C500%20MB-blue?style=flat-square)](#-disk-usage)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](#-license)

</div>

---

## 📖 Table of contents

- [What is this?](#-what-is-this)
- [Features](#-features)
- [Requirements](#-requirements)
- [Quick start](#-quick-start)
- [Connect to ChatGPT](#-connect-to-chatgpt)
- [Available tools](#-available-tools)
- [Example prompts](#-example-prompts)
- [Security model](#-security-model)
- [Local STDIO mode](#-local-stdio-mode)
- [Managing the server](#-managing-the-server)
- [Disk usage](#-disk-usage)
- [How it works](#-how-it-works)
- [File layout](#-file-layout)
- [Troubleshooting](#-troubleshooting)
- [FAQ](#-faq)
- [Uninstall](#-uninstall)
- [Roadmap](#-roadmap)
- [Contributing](#-contributing)
- [License](#-license)

---

## 🤔 What is this?

**Termux MCP** turns your Android phone into a private tool server that ChatGPT can drive. It runs a small **MCP server** inside Termux, protects it with **OAuth 2.1**, exposes it through a **free Cloudflare quick tunnel**, and registers it in ChatGPT as a **custom connector**.

Once connected, ChatGPT can:

- Run shell commands inside a sandboxed folder
- Read, write, and list files
- …and anything else you add as a tool

No VPS. No monthly bill. No code pushed to a cloud. Just your phone and a terminal.

> 🧪 **Status**: experimental. MCP is young, ChatGPT’s connector UI is still evolving, and quick tunnels are ephemeral by design. Treat this as a playground, not production.

---

## ✨ Features

- **📦 Small footprint** — under 500 MB including Node.js, cloudflared, and dependencies
- **🔐 OAuth 2.1 with PKCE** — the auth standard ChatGPT expects
- **⚡ One-command install** — `bash <(curl ...)` and you’re done
- **🚀 One-command start** — just run `termux-mcp`
- **🧱 Sandboxed filesystem** — file tools confined to `~/mcp-work`
- **✅ Command allowlist** — only safe commands run by default
- **🌐 No Cloudflare account needed** — uses `trycloudflare.com` quick tunnels
- **🖥️ Runs in tmux** — server + tunnel survive Termux being backgrounded
- **🧩 Extensible** — add your own MCP tools in a few lines of JS
- **🏠 STDIO mode** — same tools, no network exposure, for local clients

---

## 📋 Requirements

| Requirement | Details |
|-------------|---------|
| **Device** | Android with [Termux](https://f-droid.org/packages/com.termux/) installed (from F-Droid, **not** the Play Store) |
| **ChatGPT** | Plus, Pro, Team, Business, or Enterprise plan with **Developer mode** enabled |
| **Client** | ChatGPT **web** — the native mobile app does **not** support custom connectors, but `chatgpt.com` in a mobile browser works |
| **Network** | Any internet connection (the tunnel is outbound-only) |

> 💡 If you don’t see **Settings → Connectors → Advanced → Developer mode** in ChatGPT, your account doesn’t support MCP connectors yet. Nothing in this repo will change that.

---

## 🚀 Quick start

### 1. Install

In Termux:

```bash
bash <(curl -sL https://raw.githubusercontent.com/YOURUSER/termux-mcp/main/install.sh)
