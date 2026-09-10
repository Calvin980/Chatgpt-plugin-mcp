<div align="center">

# 🧠 Termux MCP

**Turn your Android phone into an MCP server ChatGPT can talk to.**

A lightweight, self-hosted [Model Context Protocol](https://modelcontextprotocol.io) server that runs entirely inside [Termux](https://termux.dev) and connects to ChatGPT as a custom connector over a free Cloudflare tunnel.

[![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Android-3DDC84?style=flat-square&logo=android&logoColor=white)](https://termux.dev)
[![Runtime](https://img.shields.io/badge/runtime-Node.js%20LTS-339933?style=flat-square&logo=nodedotjs&logoColor=white)](https://nodejs.org)
[![Protocol](https://img.shields.io/badge/protocol-MCP-000000?style=flat-square)](https://modelcontextprotocol.io)
[![Footprint](https://img.shields.io/badge/footprint-%3C400%20MB-blue?style=flat-square)](#-disk-usage)
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
- [Enabling unrestricted shell](#-enabling-unrestricted-shell)
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

**Termux MCP** lets ChatGPT use your Android device as a remote tool. It runs a small **MCP server** inside Termux, exposes it to the internet through a **free Cloudflare quick tunnel**, and lets you register it in ChatGPT as a **custom connector**.

Once connected, ChatGPT can:

- Run shell commands inside a sandboxed folder
- Read and write files
- List directories
- …and anything else you add as a tool

No servers. No VPS. No monthly cost. Just your phone and a terminal.

> 🧪 **Status**: experimental. MCP is young, ChatGPT’s connector UI is still evolving, and quick tunnels are ephemeral by design. Treat this as a playground, not production.

---

## ✨ Features

- **📦 Tiny footprint** — under 400 MB including Node.js, cloudflared, and dependencies
- **⚡ One-command install** — `bash <(curl ...)` and you’re done
- **🚀 One-command start** — just run `termux-mcp`
- **🔐 Secret URL path** — random 32-char path segment baked in on install
- **🎫 Optional bearer token** — for clients that support custom headers
- **🧱 Sandboxed filesystem** — all file tools confined to `~/mcp-work`
- **✅ Command allowlist** — only safe commands run by default
- **🌐 No Cloudflare account needed** — uses `trycloudflare.com` quick tunnels
- **🖥️ Runs in tmux** — server + tunnel survive you closing Termux
- **🧩 Extensible** — add your own MCP tools in a few lines of JS

---

## 📋 Requirements

| Requirement | Details |
|-------------|---------|
| **Device** | Android with [Termux](https://f-droid.org/packages/com.termux/) installed (from F-Droid, **not** Play Store) |
| **ChatGPT** | Plus, Pro, Team, Business, or Enterprise plan with **Developer mode** enabled |
| **Client** | ChatGPT **web or desktop** — the mobile app usually cannot add custom MCP connectors |
| **Network** | Any internet connection (the tunnel is outbound-only) |

> 💡 If you don’t see **Settings → Connectors → Advanced → Developer mode** in ChatGPT, your account doesn’t support MCP connectors yet. Nothing in this repo will change that.

---

## 🚀 Quick start

### 1. Install

In Termux:

```bash
bash <(curl -sL https://raw.githubusercontent.com/YOURUSER/termux-mcp/main/install.sh)
