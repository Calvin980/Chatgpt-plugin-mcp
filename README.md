# Termux MCP

Run an MCP (Model Context Protocol) server on Android and connect it to ChatGPT via OAuth 2.1.

## Overview

Termux MCP enables you to integrate your Android device with ChatGPT by running a Model Context Protocol server on Termux. This allows ChatGPT to interact with your Android environment securely through a secure tunnel.

**Key Features:**
- Secure OAuth 2.1 authentication
- Runs on Android via Termux
- File access confined to `~/mcp-work` directory
- Easy installation and management
- Public tunnel connectivity for remote access

## Prerequisites

Before you begin, ensure you have:
- An Android device with Termux installed ([Download Termux](https://termux.dev))
- A stable internet connection
- A ChatGPT account with plugin access
- Basic familiarity with command-line interfaces

## Installation

### Quick Install

Run the installation script:

```bash
bash <(curl -sL https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main/install.sh)
```

This script will:
- Download and configure the MCP server
- Set up necessary dependencies
- Configure environment variables
- Create the required `~/mcp-work` directory

### Manual Installation

If you prefer manual setup, follow these steps:

1. Clone the repository:
   ```bash
   git clone https://github.com/Calvin980/Chatgpt-plugin-mcp.git
   cd Chatgpt-plugin-mcp
   ```

2. Install dependencies (as required by your system)

3. Configure OAuth 2.1 credentials in your ChatGPT plugin settings

## Usage

### Starting the Server

To start the MCP server and create a tunnel connection:

```bash
termux-mcp
```

The server will:
- Initialize the MCP server
- Generate a public tunnel URL
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

You can configure the server behavior using environment variables:

```bash
# Optional: Set custom port (default: 3000)
export MCP_PORT=3000

# Optional: Set custom work directory (default: ~/mcp-work)
export MCP_WORK_DIR=~/mcp-work

# Optional: Enable debug logging
export MCP_DEBUG=true
```

### ChatGPT Plugin Setup

1. In ChatGPT, go to Settings → Plugins
2. Add a new custom plugin
3. Configure the OAuth 2.1 callback URL
4. Enter the tunnel URL provided by `termux-mcp`
5. Authorize the plugin to access your MCP server

## Security

⚠️ **Important: Read this section carefully before deployment**

### Security Considerations

- **Tunnel URL is Public**: While the server is running, the tunnel URL is publicly accessible on the internet. Anyone with the URL can attempt to connect.

- **OAuth 2.1 Protection**: Access is protected by OAuth 2.1 authentication. Only users who authorize the connection can interact with the server.

- **No Shell Access**: The MCP server does NOT provide direct shell/terminal access. Commands are limited to defined MCP protocols.

- **File Access Restrictions**: All file operations are strictly confined to the `~/mcp-work` directory. The server cannot access files outside this directory, protecting sensitive data.

- **Always Stop When Done**: Stop the tunnel when you're finished using it:
  ```bash
  termux-mcp stop
  ```

### Best Practices

1. **Don't Leave Running Unattended**: Only run the server when actively using ChatGPT integration
2. **Use Strong Authentication**: Ensure your ChatGPT account has strong authentication
3. **Monitor Activity**: Periodically check for unauthorized access attempts
4. **Rotate Credentials**: Periodically update OAuth tokens and credentials
5. **Separate Work Directory**: Keep sensitive files outside `~/mcp-work`
6. **Network Security**: Consider using a VPN if running on public networks

### Threat Model

| Threat | Mitigation |
|--------|-----------|
| Unauthorized access | OAuth 2.1 authentication |
| Data exfiltration | File access limited to `~/mcp-work` |
| Shell injection | No shell/terminal access provided |
| MITM attacks | HTTPS tunnel with certificate validation |
| Token theft | Short-lived OAuth tokens, refresh tokens stored securely |

## Troubleshooting

### Common Issues

#### "Command not found: termux-mcp"
- Ensure the installation completed successfully
- Verify the installation directory is in your PATH
- Try running: `source ~/.bashrc`

#### "Connection refused"
- Check that the server is running: `termux-mcp status`
- Verify the tunnel URL is correct
- Check your internet connection

#### "OAuth authentication failed"
- Verify your ChatGPT OAuth credentials
- Check that the callback URL matches your tunnel URL
- Ensure OAuth tokens haven't expired

#### "Permission denied accessing files"
- Verify files are in the `~/mcp-work` directory
- Check file permissions: `ls -la ~/mcp-work`
- Ensure the MCP process has read/write permissions

### Debug Mode

Enable detailed logging for troubleshooting:

```bash
export MCP_DEBUG=true
termux-mcp
```

## Advanced Usage

### Custom Work Directory

To use a different work directory:

```bash
export MCP_WORK_DIR=/path/to/custom/dir
termux-mcp
```

### Running in Background

To run the server in the background using `nohup`:

```bash
nohup termux-mcp > ~/mcp-server.log 2>&1 &
```

### Integration with Termux Services

Create a persistent service (requires `termux-services` package):

```bash
# Install termux-services
pkg install termux-services

# Create service file
mkdir -p ~/.config/termux-services/mcp
```

## Architecture

The Termux MCP system consists of three main components:

1. **MCP Server**: Runs on Android/Termux, implements the Model Context Protocol
2. **OAuth 2.1 Layer**: Provides secure authentication between ChatGPT and the server
3. **Public Tunnel**: Exposes the server to the internet with secure routing

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Support

For issues and questions:

- Open an issue on [GitHub Issues](https://github.com/Calvin980/Chatgpt-plugin-mcp/issues)
- Check existing issues for solutions
- Provide detailed error messages and logs when reporting bugs

## License

This project is licensed under the MIT License - see below for details.

```
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
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
```

## Disclaimer

This tool provides access to your Android device from ChatGPT. Users are responsible for:
- Ensuring proper security measures are in place
- Understanding the risks of exposing a device to the internet
- Regularly updating the software
- Monitoring for unauthorized access
- Complying with applicable laws and regulations

## Roadmap

Planned features for future releases:

- [ ] Web-based dashboard for server management
- [ ] Advanced logging and analytics
- [ ] Multi-user support with role-based access
- [ ] Custom command definitions
- [ ] Rate limiting and request throttling
- [ ] Support for additional authentication methods

## Related Resources

- [Model Context Protocol Documentation](https://modelcontextprotocol.io/)
- [ChatGPT Plugin Documentation](https://platform.openai.com/docs/plugins)
- [Termux Documentation](https://termux.dev/en/)
- [OAuth 2.1 Specification](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-09)

---

**Last Updated**: September 11, 2026 at 10:30 AM
**Maintainer**: Calvin980
