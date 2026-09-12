#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "Uninstalling Termux MCP..."

# Stop running sessions
echo "Stopping tmux sessions..."
tmux kill-session -t mcp-server 2>/dev/null || true
tmux kill-session -t mcp-tunnel 2>/dev/null || true
tmux kill-session -t mcp-ai 2>/dev/null || true

# Release wake lock
termux-wake-unlock 2>/dev/null || true

# Remove the server directory (includes .consent_password, audit.log, tunnel.log, node_modules)
if [ -d ~/termux-mcp ]; then
  echo "Removing ~/termux-mcp..."
  rm -rf ~/termux-mcp
fi

# Remove the sandbox and isolated home
if [ -d ~/mcp-work ]; then
  echo "Removing ~/mcp-work..."
  rm -rf ~/mcp-work
fi

if [ -d ~/mcp-ai-home ]; then
  echo "Removing ~/mcp-ai-home..."
  rm -rf ~/mcp-ai-home
fi

# Remove the commands
if [ -f $PREFIX/bin/termux-mcp ]; then
  echo "Removing termux-mcp command..."
  rm -f $PREFIX/bin/termux-mcp
fi

if [ -f $PREFIX/bin/termux-mcp-stdio ]; then
  echo "Removing termux-mcp-stdio command..."
  rm -f $PREFIX/bin/termux-mcp-stdio
fi

echo ""
echo "=============================================="
echo "Uninstall complete."
echo "=============================================="
echo ""
echo "Removed:"
echo "  ~/termux-mcp/       (server, keys, password, audit log)"
echo "  ~/mcp-work/         (sandbox files)"
echo "  ~/mcp-ai-home/      (isolated session home)"
echo "  \$PREFIX/bin/termux-mcp"
echo "  \$PREFIX/bin/termux-mcp-stdio"
echo ""
echo "Packages were NOT removed. To remove them too:"
echo "  pkg uninstall nodejs-lts cloudflared tmux"
echo ""
echo "Also delete the connector in ChatGPT:"
echo "  Settings -> Connectors -> Termux -> Delete"
echo "=============================================="
