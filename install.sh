#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main"

echo ""
echo "=============================================="
echo "  Termux MCP Installer (Tailscale Funnel)"
echo "=============================================="
echo ""
printf "Run mirror setup? [y/N]: "
read -r MIRROR_ANSWER

case "$MIRROR_ANSWER" in
  y|Y|yes|YES|Yes)
    echo ""
    echo "Setting up faster mirrors..."
    bash <(curl -sL https://raw.githubusercontent.com/rugved-danej/termux-best-mirror/main/install.sh) 2>&1 | grep -v "termux-api\|Termux:API" || true
    echo ""
    echo "Applying mirrors..."
    termux-best-mirror 2>/dev/null || echo "Mirror command not found, continuing."
    echo ""
    ;;
esac

echo "Updating packages..."
pkg update -y && pkg upgrade -y

echo "Installing dependencies..."
pkg install -y nodejs-lts tmux jq || pkg install -y nodejs tmux jq

if ! command -v tailscale >/dev/null 2>&1; then
  echo ""
  echo "Installing Tailscale (patched for Termux)..."
  curl -fsSL https://raw.githubusercontent.com/bropines/tailscale-termux-cli/main/remote-install.sh | bash 2>&1 | grep -v "termux-api\|Termux:API" || true
  echo ""
fi

if command -v tailscaled-start >/dev/null 2>&1; then
  echo "Starting Tailscale daemon..."
  tailscaled-start >/dev/null 2>&1 || true
  sleep 3
fi

mkdir -p ~/termux-mcp ~/mcp-work ~/mcp-ai-home
cd ~/termux-mcp

echo "Initializing npm project..."
npm init -y >/dev/null
npm install @modelcontextprotocol/sdk express zod jose --save-exact >/dev/null

echo "Downloading files..."
for f in server.mjs config.mjs audit.mjs state.mjs oauth.mjs tools.mjs http.mjs lib.mjs test.mjs test-http.mjs stdio-server.mjs start.sh; do
  curl -fsSL "$REPO/$f" -o "$f" || echo "  (failed: $f)"
done
curl -fsSL "$REPO/config.json.example" -o config.json.example 2>/dev/null || true
curl -fsSL "$REPO/test-stdio.sh" -o test-stdio.sh 2>/dev/null || true
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
  echo "=============================================="
  echo ""
fi

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
    echo "=============================================="
    echo ""

    # Generate recovery codes
    echo "Generating 10 recovery codes..."
    node -e "
      const crypto = require('crypto');
      const fs = require('fs');
      const codes = [];
      const map = {};
      for (let i = 0; i < 10; i++) {
        const code = crypto.randomBytes(5).toString('hex').replace(/(.{4})/g, '\$1-').replace(/-\$/, '');
        codes.push(code);
        const hash = crypto.createHash('sha256').update(code).digest('hex');
        map[hash] = { created: new Date().toISOString() };
      }
      fs.writeFileSync('.totp_recovery', JSON.stringify(map, null, 2), { mode: 0o600 });
      console.log('');
      console.log('==============================================');
      console.log('  RECOVERY CODES (each usable once)');
      console.log('');
      codes.forEach(c => console.log('    ' + c));
      console.log('');
      console.log('  Store these somewhere safe.');
      console.log('  Use one if you lose your authenticator.');
      console.log('==============================================');
      console.log('');
    "
  fi
fi

echo ""
printf "Enable device approval dialog? [y/N]: "
read -r WANT_DIALOG
if [ "$WANT_DIALOG" = "y" ] || [ "$WANT_DIALOG" = "Y" ]; then
  pkg install -y termux-api || true
  touch .use_dialog
  echo "Device approval enabled."
fi

echo ""
printf "Enable push notifications via ntfy? [y/N]: "
read -r WANT_NTFY
if [ "$WANT_NTFY" = "y" ] || [ "$WANT_NTFY" = "Y" ]; then
  printf "ntfy topic: "
  read -r NTFY_TOPIC
  if [ -n "$NTFY_TOPIC" ]; then
    echo "$NTFY_TOPIC" > .ntfy_topic
    chmod 600 .ntfy_topic
    echo "Saved. Subscribe to '$NTFY_TOPIC' in the ntfy app."
    curl -s -d "Termux MCP installed" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1
  fi
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
echo "Running tests..."
node --test test.mjs 2>&1 | tail -5 || true
MCP_TEST=1 MCP_DATA_DIR="/tmp/termux-mcp-install-test-$$" node --test test-http.mjs 2>&1 | tail -5 || true
rm -rf /tmp/termux-mcp-install-test-* 2>/dev/null

echo ""
echo "=============================================="
echo "  Installation complete."
echo "=============================================="
echo ""

if tailscale status >/dev/null 2>&1; then
  echo "Tailscale running. Enable Funnel:"
  echo "  https://login.tailscale.com/admin/dns"
  echo ""
  echo "Then: termux-mcp"
else
  echo "Run: tailscale up"
  echo "Then enable Funnel at https://login.tailscale.com/admin/dns"
  echo "Then: termux-mcp"
fi
echo ""
