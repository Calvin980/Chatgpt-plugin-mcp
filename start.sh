#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp

TUNNEL_CONFIG=~/termux-mcp/.tunnel_config

# Subcommands
case "$1" in
  stop)
    tmux kill-session -t mcp-server 2>/dev/null
    tmux kill-session -t mcp-tunnel 2>/dev/null
    termux-wake-unlock 2>/dev/null
    echo "MCP stopped."
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
  tunnel)
    if [ -f "$TUNNEL_CONFIG" ]; then
      echo "Saved named tunnel:"
      cat "$TUNNEL_CONFIG"
    else
      echo "(no named tunnel configured)"
    fi
    exit 0
    ;;
  forget-tunnel)
    rm -f "$TUNNEL_CONFIG"
    echo "Forgot saved named tunnel. (The Cloudflare tunnel itself still exists.)"
    exit 0
    ;;
esac

MODE="restricted"
[ "$1" = "unrestricted" ] && MODE="unrestricted"

TUNNEL_MODE="${TUNNEL:-}"

if [ -z "$TUNNEL_MODE" ]; then
  HAS_NAMED=0
  NAMED_HOST=""
  if [ -f "$TUNNEL_CONFIG" ]; then
    HAS_NAMED=1
    NAMED_HOST=$(grep '^hostname=' "$TUNNEL_CONFIG" | cut -d= -f2-)
  fi

  echo ""
  echo "=============================================="
  echo "  Termux MCP"
  echo "=============================================="
  echo ""
  echo "  1) Random URL (Cloudflare Quick Tunnel)"
  echo "     Free. No setup. URL changes every restart."
  echo ""
  if [ "$HAS_NAMED" = "1" ]; then
    echo "  2) Use saved named tunnel"
    echo "     https://$NAMED_HOST (stable URL)"
    echo ""
  else
    echo "  2) Use saved named tunnel"
    echo "     (none configured yet)"
    echo ""
  fi
  echo "  3) Set up a new named tunnel"
  echo "     Requires a domain on Cloudflare."
  echo "     Stable URL that never changes."
  echo ""
  echo "  0) Cancel"
  echo ""
  printf "Pick [1/2/3/0]: "
  read -r CHOICE

  case "$CHOICE" in
    1) TUNNEL_MODE="quick" ;;
    2)
      if [ "$HAS_NAMED" != "1" ]; then
        echo "No saved tunnel. Pick 1 or 3."
        exit 1
      fi
      TUNNEL_MODE="named"
      ;;
    3) TUNNEL_MODE="setup" ;;
    0) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
fi

if [ "$TUNNEL_MODE" = "setup" ]; then
  if [ ! -f ~/.cloudflared/cert.pem ]; then
    echo ""
    echo "You need to log in to Cloudflare first."
    echo ""
    echo "Run this in a separate Termux session:"
    echo ""
    echo "    cloudflared tunnel login"
    echo ""
    echo "It will open a browser. Authorize the domain, then"
    echo "come back here and run: termux-mcp"
    echo ""
    exit 1
  fi

  printf "Tunnel name (letters, numbers, dash, underscore): "
  read -r TUNNEL_NAME
  if ! echo "$TUNNEL_NAME" | grep -qE '^[a-zA-Z0-9_-]{1,40}$'; then
    echo "Invalid name."
    exit 1
  fi

  printf "Hostname (e.g. mcp.yourdomain.com): "
  read -r TUNNEL_HOST
  if ! echo "$TUNNEL_HOST" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
    echo "Invalid hostname."
    exit 1
  fi

  echo ""
  echo "Creating tunnel: $TUNNEL_NAME"
  if cloudflared tunnel list 2>/dev/null | grep -q " $TUNNEL_NAME "; then
    echo "  (already exists, reusing)"
  else
    cloudflared tunnel create "$TUNNEL_NAME" || { echo "Failed to create tunnel."; exit 1; }
  fi

  echo "Routing DNS: $TUNNEL_HOST -> $TUNNEL_NAME"
  cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_HOST" 2>&1 | grep -v "already configured" || true

  cat > "$TUNNEL_CONFIG" <<EOF
name=$TUNNEL_NAME
hostname=$TUNNEL_HOST
EOF
  chmod 600 "$TUNNEL_CONFIG"

  echo ""
  echo "Saved."
  echo ""
  TUNNEL_MODE="named"
fi

mkdir -p ~/mcp-work ~/mcp-ai-home
tmux kill-session -t mcp-server 2>/dev/null
tmux kill-session -t mcp-tunnel 2>/dev/null
rm -f tunnel.log

if [ "$TUNNEL_MODE" = "named" ]; then
  TUNNEL_NAME=$(grep '^name=' "$TUNNEL_CONFIG" | cut -d= -f2-)
  URL="https://$(grep '^hostname=' "$TUNNEL_CONFIG" | cut -d= -f2-)"

  echo ""
  echo "Starting named tunnel: $TUNNEL_NAME"
  tmux new-session -d -s mcp-tunnel "cloudflared tunnel run $TUNNEL_NAME > ~/termux-mcp/tunnel.log 2>&1"

  READY=0
  for i in $(seq 1 30); do
    if grep -q "Registered tunnel connection" ~/termux-mcp/tunnel.log 2>/dev/null; then
      READY=1
      break
    fi
    sleep 1
  done

  if [ "$READY" != "1" ]; then
    echo "Tunnel did not register. Check ~/termux-mcp/tunnel.log"
    exit 1
  fi
else
  echo ""
  echo "Starting quick tunnel..."
  tmux new-session -d -s mcp-tunnel 'cloudflared tunnel --url http://127.0.0.1:8000 > ~/termux-mcp/tunnel.log 2>&1'

  URL=""
  for i in $(seq 1 30); do
    URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' tunnel.log 2>/dev/null | head -n1)
    [ -n "$URL" ] && break
    sleep 1
  done

  if [ -z "$URL" ]; then
    echo "Failed to get tunnel URL. Check ~/termux-mcp/tunnel.log"
    exit 1
  fi
fi

export MCP_ALLOW_UNRESTRICTED=$([ "$MODE" = "unrestricted" ] && echo 1 || echo 0)
tmux new-session -d -s mcp-server "PUBLIC_URL='$URL' MCP_ALLOW_UNRESTRICTED=$MCP_ALLOW_UNRESTRICTED node /data/data/com.termux/files/home/termux-mcp/server.mjs"
sleep 2
echo "$URL" > ~/termux-mcp/.last_url

echo ""
echo "=============================================="
if [ "$MODE" = "unrestricted" ]; then
  echo "⚠️  Termux MCP — UNRESTRICTED MODE"
else
  echo "✓ Termux MCP running (restricted)"
fi
echo "=============================================="
echo "MCP URL:   $URL/mcp"
echo "Tunnel:    $TUNNEL_MODE"
echo "Auth:      OAuth + consent password"
echo "Password:  $(cat ~/termux-mcp/.consent_password 2>/dev/null || echo '(none)')"
echo ""
echo "In ChatGPT: leave Client ID and Secret blank."
echo "On the approve page: enter the password above."
echo ""
echo "Commands:"
echo "  termux-mcp stop            kill everything"
echo "  termux-mcp audit           show recent activity"
echo "  termux-mcp password        show consent password"
echo "  termux-mcp tunnel          show saved named tunnel"
echo "  termux-mcp forget-tunnel   forget the saved tunnel"
echo "=============================================="
