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
    bash <(curl -sL https://raw.githubusercontent.com/rugved-danej/termux-best-mirror/main/install.sh) || true
    echo ""
    echo "Applying mirrors..."
    termux-best-mirror 2>/dev/null || echo "Mirror command not found, continuing."
    echo ""
    ;;
  *)
    echo "Skipping mirror setup."
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

# ---------- Factor 1: Consent password ----------
if [ ! -f .consent_password ]; then
  head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16 > .consent_password
  chmod 600 .consent_password
  echo ""
  echo "=============================================="
  echo "  CONSENT PASSWORD: $(cat .consent_password)"
  echo ""
  echo "  Write this down."
  echo "=============================================="
  echo ""
fi

# ---------- Factor 2: TOTP ----------
echo ""
printf "Enable TOTP as a second factor? [y/N]: "
read -r WANT_TOTP
if [ "$WANT_TOTP" = "y" ] || [ "$WANT_TOTP" = "Y" ]; then
  pkg install -y oathtool || true
  if [ ! -f .totp_secret ]; then
    SECRET=$(head -c 20 /dev/urandom | base32 | head -c 32 | tr -d '=')
    echo "$SECRET" > .totp_secret
    chmod 600 .totp_secret
    echo ""
    echo "=============================================="
    echo "  TOTP SECRET: $SECRET"
    echo ""
    echo "  Add to authenticator app:"
    echo "    Account:  Termux MCP"
    echo "    Secret:   $SECRET"
    echo "    Type:     Time-based (TOTP)"
    echo "    Digits:   6"
    echo "    Period:   30"
    echo "    Algo:     SHA1"
    echo ""
    echo "  Write it down."
    echo "=============================================="
    echo ""
  else
    echo "TOTP already configured."
  fi
fi

# ---------- Factor 3: Device dialog ----------
echo ""
printf "Enable device approval dialog? [y/N]: "
read -r WANT_DIALOG
if [ "$WANT_DIALOG" = "y" ] || [ "$WANT_DIALOG" = "Y" ]; then
  pkg install -y termux-api || true
  touch .use_dialog
  echo ""
  echo "Device approval enabled."
  echo "You must install the Termux:API app from F-Droid."
  echo ""
fi

# ---------- Command wrappers ----------
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
echo "  termux-mcp panic              emergency kill"
echo "  termux-mcp unlock [n]         allow mutating tools"
echo "  termux-mcp lock               lock immediately"
echo "  termux-mcp factors            show active auth factors"
echo "  termux-mcp audit              show recent activity"
echo "  termux-mcp password           show consent password"
echo "  termux-mcp-stdio              local STDIO mode"
echo ""
echo "Get started:"
echo "  termux-mcp"
echo ""
