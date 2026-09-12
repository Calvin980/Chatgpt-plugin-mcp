# Termux MCP

Run an MCP server on an Android phone and connect it to ChatGPT.

This runs a small Node.js server inside Termux, exposes it over HTTPS with a Cloudflare Quick Tunnel, and authenticates ChatGPT with OAuth 2.1. Once connected, ChatGPT gets a small set of read-only and narrowly-scoped tools on your phone. There is no shell tool.

It works. It's also a hobby project — read the [Security](#security) section before you leave it running.

---

## Table of contents

- [What it does](#what-it-does)
- [What it doesn't do](#what-it-doesnt-do)
- [Requirements](#requirements)
- [Install](#install)
- [Connect to ChatGPT](#connect-to-chatgpt)
- [Commands](#commands)
- [Tools](#tools)
- [Restricted vs unrestricted](#restricted-vs-unrestricted)
- [Security](#security)
- [Common problems](#common-problems)
- [FAQ](#faq)
- [The URL changes every restart](#the-url-changes-every-restart)
- [Local mode](#local-mode-no-tunnel)
- [How it works](#how-it-works)
- [Uninstall](#uninstall)

---

## What it does

| | |
|---|---|
| **Runtime** | Node.js inside Termux |
| **Transport** | MCP Streamable HTTP |
| **Auth** | OAuth 2.1 + PKCE + DCR + `private_key_jwt` |
| **Exposure** | Cloudflare Quick Tunnel (no account needed) |
| **Tools** | 11, all narrow. No shell. |
| **Cost** | $0 |
| **Data** | Stays on your phone unless you ask it to leave |

---

## What it doesn't do

| Limitation | Why |
|---|---|
| Same URL across restarts | Cloudflare Quick Tunnels rotate every start |
| ChatGPT mobile app | Custom connectors are browser-only |
| General shell | No `run_command` tool. By design. |
| Replace a real server | It's a toy that happens to be useful |
| Rate limiting | You have to add it yourself |
| Audit logging | You have to add it yourself |

---

## Requirements

| Requirement | Details |
|---|---|
| **Device** | Android with [Termux from F-Droid](https://f-droid.org/packages/com.termux/) (not Play Store) |
| **ChatGPT** | Plus, Pro, Team, Business, or Enterprise |
| **Developer mode** | Enabled under Settings → Connectors → Advanced |
| **Client** | A browser. `chatgpt.com` in mobile Chrome/Firefox works |
| **Storage** | ~500 MB free |

> If you don't see **Settings → Connectors → Advanced → Developer mode**, your account doesn't support custom connectors yet. Nothing here will change that.

---

## Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)- ChatGPT Plus, Pro, Team, Business, or Enterprise with **Developer mode** enabled
- A browser — `chatgpt.com` on mobile browser works; the native app does not
- ~500 MB free storage

---

## Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
