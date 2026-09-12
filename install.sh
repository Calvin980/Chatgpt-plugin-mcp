#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main"

echo ""
echo "=============================================="
echo "  Termux MCP Installer"
echo "=============================================="
echo ""
echo "Before installing, we can speed up package"
echo "downloads by switching to faster Termux mirrors."
echo ""
echo "This runs a third-party script from:"
echo "  github.com/rugved-danej/termux-best-mirror"
echo ""
printf "Run mirror setup? [y/N]: "
read -r MIRROR_ANSWER

case "$MIRROR_ANSWER" in
  y|Y|yes|YES|Yes)
    echo ""
    echo "Setting up faster mirrors..."
    bash <(curl -sL https://raw.githubusercontent.com/rugved-danej/termux-best-mirror/main/install.sh)
    echo ""
    echo "Applying mirrors..."
    termux-best-mirror
    echo ""
    echo "Mirrors configured."
    echo ""
    ;;
  *)
    echo "Skipping mirror setup. Using default mirrors."
    echo ""
    ;;
esac

echo "Updating packages..."
pkg update -y && pkg upgrade -y

echo "Installing dependencies..."
pkg install -y nodejs-lts cloudflared tmux || pkg install -y nodejs cloudflared tmux

mkdir -p ~/termux-mcp ~/mcp-work ~/mcp-ai-home
cd ~/termux-mcp

echo "Initializing npm project..."
npm init -y >/dev/null
npm install @modelcontextprotocol/sdk express zod jose --save-exact >/dev/null

echo "Downloading server files..."
curl -fsSL "$REPO/server.mjs"       -o server.mjs
curl -fsSL "$REPO/stdio-server.mjs" -o stdio-server.mjs
curl -fsSL "$REPO/start.sh"         -o start.sh
curl -fsSL "$REPO/test-stdio.sh"    -o test-stdio.sh 2>/dev/null || true
chmod +x start.sh
[ -f test-stdio.sh ] && chmod +x test-stdio.sh

if [ ! -f .consent_password ]; then
  head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16 > .consent_password
  chmod 600 .consent_password
  echo ""
  echo "=============================================="
  echo "  CONSENT PASSWORD: $(cat .consent_password)"
  echo ""
  echo "  Write this down."
  echo "  You'll need it to approve the connector"
  echo "  in ChatGPT."
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
echo "=============================================="
echo "  Installation complete."
echo "=============================================="
echo ""
echo "Commands:"
echo "  termux-mcp                    start (restricted)"
echo "  termux-mcp unrestricted       start (full access)"
echo "  termux-mcp stop               stop"
echo "  termux-mcp unlock [n]         allow mutating tools"
echo "  termux-mcp lock               lock immediately"
echo "  termux-mcp panic              emergency kill"
echo "  termux-mcp audit              show recent activity"
echo "  termux-mcp password           show consent password"
echo "  termux-mcp-stdio              local STDIO mode"
echo ""
echo "Get started:"
echo "  termux-mcp"
echo ""
