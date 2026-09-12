#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main"

echo "Installing Termux MCP..."
pkg update -y && pkg upgrade -y
pkg install -y nodejs-lts cloudflared tmux || pkg install -y nodejs cloudflared tmux

mkdir -p ~/termux-mcp ~/mcp-work ~/mcp-ai-home
cd ~/termux-mcp

npm init -y >/dev/null
npm install @modelcontextprotocol/sdk express zod jose --save-exact >/dev/null

echo "Downloading files..."
curl -fsSL "$REPO/server.mjs"       -o server.mjs
curl -fsSL "$REPO/stdio-server.mjs" -o stdio-server.mjs
curl -fsSL "$REPO/start.sh"         -o start.sh
curl -fsSL "$REPO/test-stdio.sh"    -o test-stdio.sh 2>/dev/null || true
chmod +x start.sh

if [ ! -f .consent_password ]; then
  head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16 > .consent_password
  chmod 600 .consent_password
  echo ""
  echo "=============================================="
  echo "CONSENT PASSWORD: $(cat .consent_password)"
  echo "Write this down."
  echo "=============================================="
  echo ""
fi

cat > $PREFIX/bin/termux-mcp <<'CMDEOF'
#!/data/data/com.termux/files/usr/bin/bash
bash ~/termux-mcp/start.sh "$@"
CMDEOF
chmod +x $PREFIX/bin/termux-mcp

cat > $PREFIX/bin/termux-mcp-stdio <<'CMDEOF'
#!/data/data/com.termux/files/usr/bin/bash
exec node ~/termux-mcp/stdio-server.mjs
CMDEOF
chmod +x $PREFIX/bin/termux-mcp-stdio

echo ""
echo "Done."
echo "  termux-mcp              start"
echo "  termux-mcp stop         stop"
echo "  termux-mcp audit        show activity"
echo "  termux-mcp password     show consent password"
