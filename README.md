<div align="center">

<img src="https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/assets/banner.png" alt="Termux MCP banner" width="100%" />

# 🧠 Termux MCP

**Turn your Android phone into a secure, self-hosted MCP server that ChatGPT can drive.**

A lightweight [Model Context Protocol](https://modelcontextprotocol.io) server running inside [Termux](https://termux.dev), protected by **OAuth 2.1 + PKCE**, exposed through a free Cloudflare tunnel, and registered in ChatGPT as a custom connector.

<br />

[![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://termux.dev)
[![Runtime](https://img.shields.io/badge/runtime-Node.js%20LTS-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)](https://nodejs.org)
[![Protocol](https://img.shields.io/badge/protocol-MCP-000000?style=for-the-badge)](https://modelcontextprotocol.io)
[![Auth](https://img.shields.io/badge/auth-OAuth%202.1-4A90E2?style=for-the-badge)](https://oauth.net/2.1/)

[![Footprint](https://img.shields.io/badge/footprint-%3C500%20MB-blue?style=flat-square)](#-disk-usage)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](#-license)
[![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square)](#-contributing)
[![Stars](https://img.shields.io/github/stars/Calvin980/Chatgpt-plugin-mcp?style=flat-square)](https://github.com/Calvin980/Chatgpt-plugin-mcp/stargazers)

<br />

[**Quick start**](#-quick-start) · [**Connect to ChatGPT**](#-connect-to-chatgpt) · [**Security**](#-security-model) · [**FAQ**](#-faq) · [**Troubleshooting**](#-troubleshooting)

</div>

---

## 📖 Table of contents

<details>
<summary>Click to expand</summary>

- [What is this?](#-what-is-this)
- [Why Termux MCP?](#-why-termux-mcp)
- [Features](#-features)
- [Requirements](#-requirements)
- [Quick start](#-quick-start)
- [Connect to ChatGPT](#-connect-to-chatgpt)
- [Available tools](#-available-tools)
- [Example prompts](#-example-prompts)
- [Security model](#-security-model)
- [Advanced configuration](#-advanced-configuration)
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
- [Changelog](#-changelog)
- [License](#-license)
- [Credits](#-credits)

</details>

---

## 🤔 What is this?

**Termux MCP** turns your Android phone into a private tool server that ChatGPT can drive. It runs a small **MCP server** inside Termux, protects it with **OAuth 2.1**, exposes it through a **free Cloudflare quick tunnel**, and registers it in ChatGPT as a **custom connector**.

Once connected, ChatGPT can:

- Run shell commands inside a sandboxed folder
- Read, write, and list files
- Fetch URLs
- …and anything else you add as a tool

No VPS. No monthly bill. No code pushed to a cloud. Just your phone and a terminal.

> 🧪 **Status**: experimental. MCP is young, ChatGPT’s connector UI is still evolving, and quick tunnels are ephemeral by design. Treat this as a playground, not production.

---

## 💡 Why Termux MCP?

There are plenty of MCP servers. Here's what makes this one different:

| | Termux MCP | Typical MCP server |
|---|---|---|
| **Runs on** | Android phone | VPS / laptop / cloud |
| **Cost** | $0 | $5–20/mo |
| **Auth** | OAuth 2.1 + PKCE | Often none, or static bearer |
| **Footprint** | <500 MB | Varies |
| **Setup time** | ~5 minutes | 15–60 minutes |
| **Requires a server** | ❌ | ✅ |
| **Data leaves your device** | Only when you ask | Varies |

The pitch: **the phone in your pocket is a perfectly good server** for personal-scale automation. This repo makes it safe enough to use.

---

## ✨ Features

- **📦 Small footprint** — under 500 MB including Node.js, cloudflared, and dependencies
- **🔐 OAuth 2.1 with PKCE** — the auth standard ChatGPT expects
- **⚡ One-command install** — `bash <(curl ...)` and you’re done
- **🚀 One-command start** — just run `termux-mcp`
- **🧱 Sandboxed filesystem** — file tools confined to `~/mcp-work`
- **✅ Command allowlist** — only safe commands run by default
- **🌐 No Cloudflare account needed** — uses `trycloudflare.com` quick tunnels
- **🖥️ Runs in tmux** — survives Termux being backgrounded
- **🧩 Extensible** — add your own MCP tools in a few lines of JS
- **🏠 STDIO mode** — same tools, no network exposure, for local clients
- **🔄 Rotatable secrets** — regenerate OAuth credentials with one command
- **📱 Mobile-first** — designed and tested on Android

---

## 📋 Requirements

| Requirement | Details |
|-------------|---------|
| **Device** | Android with [Termux](https://f-droid.org/packages/com.termux/) installed from **F-Droid**, not the Play Store |
| **ChatGPT** | Plus, Pro, Team, Business, or Enterprise — with **Developer mode** enabled |
| **Client** | ChatGPT **web** — the native mobile app does **not** support custom connectors, but `chatgpt.com` in a mobile browser works |
| **Network** | Any internet connection (the tunnel is outbound-only) |
| **Storage** | ~500 MB free |
| **Knowledge** | Ability to copy-paste commands into a terminal |

> 💡 If you don’t see **Settings → Connectors → Advanced → Developer mode** in ChatGPT, your account doesn’t support MCP connectors yet. Nothing in this repo will change that.

---

## 🚀 Quick start

### 1. Install

In Termux:

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
