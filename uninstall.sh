#!/data/data/com.termux/files/usr/bin/bash

echo ""
echo "=============================================="
echo "  Termux MCP Uninstaller"
echo "=============================================="
echo ""

echo "Stopping tmux sessions..."
for s in mcp-server mcp-tunnel mcp-ai; do
  if tmux has-session -t "$s" 2>/dev/null; then
    tmux kill-session -t "$s"
    echo "  killed: $s"
  fi
done

termux-wake-unlock 2>/dev/null || true

echo ""
echo "Removing files..."

remove_path() {
  local target="$1"
  local label="$2"
  if [ -e "$target" ]; then
    rm -rf "$target"
    if [ -e "$target" ]; then
      echo "  FAILED: $label ($target)"
      return 1
    else
      echo "  removed: $label"
    fi
  else
    echo "  already absent: $label"
  fi
  return 0
}

FAIL=0

remove_path ~/termux-mcp "~/termux-mcp" || FAIL=1
remove_path ~/mcp-work "~/mcp-work" || FAIL=1
remove_path ~/mcp-ai-home "~/mcp-ai-home" || FAIL=1
remove_path "$PREFIX/bin/termux-mcp" "termux-mcp command" || FAIL=1
remove_path "$PREFIX/bin/termux-mcp-stdio" "termux-mcp-stdio command" || FAIL=1

REMAINING_SESSIONS=$(tmux ls 2>/dev/null | grep -E '^(mcp-server|mcp-tunnel|mcp-ai):' || true)

echo ""
echo "=============================================="
if [ "$FAIL" -eq 0 ] && [ -z "$REMAINING_SESSIONS" ]; then
  echo "  Uninstall verified. Everything is gone."
else
  echo "  Uninstall incomplete."
  [ "$FAIL" -ne 0 ] && echo "  Some files could not be removed."
  [ -n "$REMAINING_SESSIONS" ] && echo "  Sessions still running: $REMAINING_SESSIONS"
fi
echo "=============================================="
echo ""

echo "Verification:"
LEFT=0
for p in ~/termux-mcp ~/mcp-work ~/mcp-ai-home "$PREFIX/bin/termux-mcp" "$PREFIX/bin/termux-mcp-stdio"; do
  if [ -e "$p" ]; then
    echo "  STILL EXISTS: $p"
    LEFT=1
  fi
done
[ "$LEFT" -eq 0 ] && echo "  (nothing left - all clean)"
echo ""

echo "Packages (nodejs-lts, cloudflared, tmux) were NOT removed."
echo "To remove them: pkg uninstall nodejs-lts cloudflared tmux"
echo ""
echo "Don't forget: delete the Termux connector in ChatGPT settings."
echo ""
