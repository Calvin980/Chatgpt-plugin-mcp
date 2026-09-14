#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp

case "$1" in
  stop)
    tmux kill-session -t mcp-server 2>/dev/null
    tmux kill-session -t mcp-ai 2>/dev/null
    termux-wake-unlock 2>/dev/null
    echo "MCP stopped."
    exit 0
    ;;

  panic)
    echo "Killing everything..."
    tmux kill-session -t mcp-server 2>/dev/null
    tmux kill-session -t mcp-ai 2>/dev/null
    termux-wake-unlock 2>/dev/null
    rm -f ~/termux-mcp/.unlocked_until
    echo "All sessions killed."
    exit 0
    ;;

  audit)
    tail -n 50 ~/termux-mcp/audit.log 2>/dev/null || echo "(no audit log yet)"
    exit 0
    ;;

  password)
    cat ~/termux-mcp/.consent_password 2>/dev/null || echo "(no password set)"
    exit 0
    ;;

  factors)
    echo ""
    echo "Auth factors:"
    [ -f ~/termux-mcp/.consent_password ] && echo "  [x] Password" || echo "  [ ] Password"
    [ -f ~/termux-mcp/.totp_secret ] && echo "  [x] TOTP" || echo "  [ ] TOTP"
    [ -f ~/termux-mcp/.use_dialog ] && echo "  [x] Device dialog" || echo "  [ ] Device dialog"
    echo ""
    exit 0
    ;;

  unlock)
    MIN="${2:-5}"
    if ! echo "$MIN" | grep -qE '^[0-9]+$'; then
      echo "Usage: termux-mcp unlock [minutes]"
      exit 1
    fi
    UNTIL_MS=$(( ($(date +%s) + MIN * 60) * 1000 ))
    echo "$UNTIL_MS" > ~/termux-mcp/.unlocked_until
    echo "Unlocked for $MIN minute(s)."
    exit 0
    ;;

  lock)
    rm -f ~/termux-mcp/.unlocked_until
    echo "Locked."
    exit 0
    ;;

  test)
    cd ~/termux-mcp
    node --test test.mjs
    exit $?
    ;;

  funnel)
    tailscale funnel status
    exit 0
    ;;

  url)
    if [ -f ~/termux-mcp/.last_url ]; then
      echo "$(cat ~/termux-mcp/.last_url)/mcp"
    else
      echo "(no URL yet - start with: termux-mcp)"
    fi
    exit 0
    ;;
esac

MODE="restricted"
[ "$1" = "unrestricted" ] && MODE="unrestricted"

# Check Tailscale is installed
if ! command -v tailscale >/dev/null 2>&1; then
  echo "Tailscale is not installed."
  echo "Install it with:"
  echo "  curl -fsSL https://raw.githubusercontent.com/bropines/tailscale-termux-cli/main/remote-install.sh | bash"
  exit 1
fi

# Check Tailscale daemon is running
if ! tailscale status >/dev/null 2>&1; then
  echo "Tailscale is not running."
  echo ""
  echo "Start it with:"
  echo "  tailscale up"
  echo ""
  echo "If the daemon is not running:"
  echo "  tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 &"
  echo "  sleep 3"
  echo "  tailscale up"
  exit 1
fi

# Check jq is installed
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is not installed. Installing..."
  pkg install -y jq || { echo "Failed to install jq. Run: pkg install jq"; exit 1; }
fi

mkdir -p ~/mcp-work ~/mcp-ai-home
tmux kill-session -t mcp-server 2>/dev/null
tmux kill-session -t mcp-ai 2>/dev/null

# Get the permanent Tailscale Funnel URL
DNS_NAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' | sed 's/\.$//')
if [ -z "$DNS_NAME" ] || [ "$DNS_NAME" = "null" ]; then
  echo "Could not read Tailscale DNS name."
  echo "Check: tailscale status"
  exit 1
fi
URL="https://$DNS_NAME"

echo ""
echo "Starting Tailscale Funnel on port 8000..."
tailscale funnel 8000 >/dev/null 2>&1
sleep 1

# Verify Funnel status
if ! tailscale funnel status 2>/dev/null | grep -q "$DNS_NAME"; then
  echo "Warning: Funnel may not be active. Check with: termux-mcp funnel"
  echo ""
fi

export MCP_ALLOW_UNRESTRICTED=$([ "$MODE" = "unrestricted" ] && echo 1 || echo 0)
tmux new-session -d -s mcp-server "PUBLIC_URL='$URL' MCP_ALLOW_UNRESTRICTED=$MCP_ALLOW_UNRESTRICTED node /data/data/com.termux/files/home/termux-mcp/server.mjs"
sleep 2
echo "$URL" > ~/termux-mcp/.last_url

echo ""
echo "=============================================="
if [ "$MODE" = "unrestricted" ]; then
  echo "  Termux MCP - UNRESTRICTED MODE"
else
  echo "  Termux MCP running (restricted)"
fi
echo "=============================================="
echo "MCP URL:   $URL/mcp"
echo "Tunnel:    tailscale funnel"
echo "Auth:      OAuth + consent password"
[ -f ~/termux-mcp/.totp_secret ] && echo "           + TOTP"
[ -f ~/termux-mcp/.use_dialog ] && echo "           + Device dialog"
echo "Password:  $(cat ~/termux-mcp/.consent_password 2>/dev/null || echo '(none)')"
echo ""
echo "In ChatGPT: leave Client ID and Secret blank."
echo ""
echo "Commands:"
echo "  termux-mcp stop         kill everything"
echo "  termux-mcp panic        kill + clear unlock"
echo "  termux-mcp unlock [n]   allow mutating tools for n minutes"
echo "  termux-mcp lock         lock immediately"
echo "  termux-mcp factors      show active auth factors"
echo "  termux-mcp audit        show recent activity"
echo "  termux-mcp password     show consent password"
echo "  termux-mcp funnel       show funnel status"
echo "  termux-mcp url          print MCP URL"
echo "  termux-mcp test         run test suite"
echo "=============================================="
