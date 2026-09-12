#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp

if [ "$1" = "stop" ]; then
  tmux kill-session -t mcp-server 2>/dev/null
  tmux kill-session -t mcp-tunnel 2>/dev/null
  termux-wake-unlock 2>/dev/null
  echo "MCP stopped."
  exit 0
fi

if [ "$1" = "audit" ]; then
  tail -n 50 ~/termux-mcp/audit.log 2>/dev/null || echo "(no audit log yet)"
  exit 0
fi

if [ "$1" = "password" ]; then
  cat ~/termux-mcp/.consent_password 2>/dev/null || echo "(no password set)"
  exit 0
fi

MODE="restricted"
[ "$1" = "unrestricted" ] && MODE="unrestricted"

mkdir -p ~/mcp-work ~/mcp-ai-home
tmux kill-session -t mcp-server 2>/dev/null
tmux kill-session -t mcp-tunnel 2>/dev/null
rm -f tunnel.log
tmux new-session -d -s mcp-tunnel 'cloudflared tunnel --url http://127.0.0.1:8000 > ~/termux-mcp/tunnel.log 2>&1'

URL=""
for i in $(seq 1 30); do
  URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' tunnel.log 2>/dev/null | head -n1)
  [ -n "$URL" ] && break
  sleep 1
done

[ -z "$URL" ] && { echo "Failed to get tunnel URL. Check ~/termux-mcp/tunnel.log"; exit 1; }

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
echo "MCP URL:  $URL/mcp"
echo "Auth:     OAuth + consent password"
echo "Password: $(cat ~/termux-mcp/.consent_password)"
echo ""
echo "In ChatGPT: leave Client ID and Secret blank."
echo "On the approve page: enter the password above."
echo ""
echo "Other commands:"
echo "  termux-mcp stop       kill everything"
echo "  termux-mcp audit      show last 50 audit entries"
echo "  termux-mcp password   show the consent password"
echo "=============================================="
