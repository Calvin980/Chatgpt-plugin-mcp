# Termux MCP

Run an MCP server on Android and connect it to ChatGPT via OAuth 2.1.

Install with `bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)`, then run `termux-mcp` to start and `termux-mcp stop` to stop.

Read the [Security](#security) section before leaving it running.

## Security

The tunnel URL is public while it's up. OAuth 2.1 gates access, there is no shell tool, and file tools are confined to `~/mcp-work`. Stop the tunnel when you're done.

## License

MIT
