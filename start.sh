#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp

# ============================================================
# Config
# ============================================================

REPO="https://raw.githubusercontent.com/Calvin980/Chatgpt-plugin-mcp/main"
DATA_DIR="$HOME/termux-mcp"

# ============================================================
# Helpers
# ============================================================

get_dns_name() {
  tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null | sed 's/\.$//'
}

get_url() {
  local dns
  dns=$(get_dns_name)
  [ -z "$dns" ] || [ "$dns" = "null" ] && return 1
  echo "https://$dns"
}

get_mcp_url() {
  local u
  u=$(get_url) || return 1
  echo "$u/mcp"
}

server_running() {
  tmux has-session -t mcp-server 2>/dev/null
}

ai_running() {
  tmux has-session -t mcp-ai 2>/dev/null
}

server_mode() {
  if server_running; then
    local line
    line=$(tmux capture-pane -t mcp-server -p 2>/dev/null | grep -o 'mode=[A-Za-z]*' | head -1)
    case "$line" in
      mode=UNRESTRICTED) echo "unrestricted" ;;
      mode=restricted) echo "restricted" ;;
      *) echo "unknown" ;;
    esac
  else
    echo "stopped"
  fi
}

funnel_active() {
  tailscale funnel status 2>/dev/null | grep -q "Funnel on"
}

serve_configured() {
  tailscale funnel status 2>/dev/null | grep -q "proxy http://127.0.0.1:8000"
}

is_unlocked() {
  [ -f "$DATA_DIR/.unlocked_until" ] || return 1
  local until
  until=$(cat "$DATA_DIR/.unlocked_until" 2>/dev/null)
  [ -z "$until" ] && return 1
  [ "$(date +%s%3N)" -lt "$until" ] 2>/dev/null
}

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq..."
    pkg install -y jq >/dev/null 2>&1
  fi
}

ensure_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale is not installed."
    echo "Install: curl -fsSL https://raw.githubusercontent.com/bropines/tailscale-termux-cli/main/remote-install.sh | bash"
    return 1
  fi
  if ! tailscale status >/dev/null 2>&1; then
    echo "Starting Tailscale daemon..."
    command -v tailscaled-start >/dev/null 2>&1 && tailscaled-start >/dev/null 2>&1
    sleep 3
    if ! tailscale status >/dev/null 2>&1; then
      echo "Could not start Tailscale daemon."
      echo "Run: tailscaled-start && tailscale up"
      return 1
    fi
  fi
  return 0
}

ensure_funnel() {
  if ! serve_configured; then
    echo "Configuring Funnel on port 8000..."
    tailscale funnel --bg 8000 >/dev/null 2>&1
    sleep 2
  fi
  if ! funnel_active; then
    echo "Warning: Funnel may not be active."
    echo "Enable it: https://login.tailscale.com/admin/access-controls"
    echo ""
  fi
}

require_tailscale() {
  ensure_jq
  ensure_tailscale || exit 1
}

prompt_yn() {
  printf "%s [y/N]: " "$1"
  read -r ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================
# Auth factor management
# ============================================================

gen_consent_password() {
  head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16 > "$DATA_DIR/.consent_password"
  chmod 600 "$DATA_DIR/.consent_password"
}

gen_totp_secret() {
  head -c 20 /dev/urandom | base32 | head -c 32 | tr -d '=' > "$DATA_DIR/.totp_secret"
  chmod 600 "$DATA_DIR/.totp_secret"
}

# ============================================================
# Core actions
# ============================================================

cmd_start_server() {
  local mode="${1:-restricted}"

  require_tailscale
  ensure_funnel

  mkdir -p ~/mcp-work ~/mcp-ai-home
  tmux kill-session -t mcp-server 2>/dev/null
  tmux kill-session -t mcp-ai 2>/dev/null

  local url
  url=$(get_url) || { echo "Could not read Tailscale DNS name."; return 1; }

  local unrestricted=0
  [ "$mode" = "unrestricted" ] && unrestricted=1

  tmux new-session -d -s mcp-server \
    "PUBLIC_URL='$url' MCP_ALLOW_UNRESTRICTED=$unrestricted node $DATA_DIR/server.mjs"
  sleep 2
  echo "$url" > "$DATA_DIR/.last_url"

  echo ""
  echo "=============================================="
  if [ "$mode" = "unrestricted" ]; then
    echo "  Termux MCP - UNRESTRICTED MODE"
  else
    echo "  Termux MCP running (restricted)"
  fi
  echo "=============================================="
  echo "MCP URL:   $url/mcp"
  echo "Tunnel:    tailscale funnel"
  echo "Auth:      OAuth + password"
  [ -f "$DATA_DIR/.totp_secret" ] && echo "           + TOTP"
  [ -f "$DATA_DIR/.use_dialog" ] && echo "           + Device dialog"
  echo "Password:  $(cat "$DATA_DIR/.consent_password" 2>/dev/null || echo '(none)')"
  echo ""
  echo "Open in ChatGPT: leave Client ID and Secret blank."
  echo "=============================================="
}

cmd_stop() {
  tmux kill-session -t mcp-server 2>/dev/null
  tmux kill-session -t mcp-ai 2>/dev/null
  termux-wake-unlock 2>/dev/null
  echo "MCP stopped."
}

cmd_shutdown() {
  cmd_stop
  echo "Removing Funnel..."
  tailscale funnel reset >/dev/null 2>&1
  echo ""
  echo "=============================================="
  echo "  Shutdown complete"
  echo "=============================================="
  echo "The URL is now unreachable."
  echo ""
  echo "To bring it back:"
  echo "  termux-mcp        (menu) → 1 or 2"
  echo "=============================================="
}

cmd_shutdown_all() {
  cmd_stop
  echo "Removing Funnel..."
  tailscale funnel reset >/dev/null 2>&1
  echo "Stopping Tailscale daemon..."
  tailscaled-stop >/dev/null 2>&1
  echo ""
  echo "=============================================="
  echo "  Full shutdown complete"
  echo "=============================================="
  echo "Server stopped, Funnel removed, Tailscale daemon stopped."
  echo ""
  echo "To restore:"
  echo "  tailscaled-start"
  echo "  termux-mcp"
  echo "=============================================="
}

cmd_panic() {
  echo "Killing everything..."
  tmux kill-session -t mcp-server 2>/dev/null
  tmux kill-session -t mcp-ai 2>/dev/null
  termux-wake-unlock 2>/dev/null
  rm -f "$DATA_DIR/.unlocked_until"
  tailscale funnel reset >/dev/null 2>&1
  echo "Server killed, Funnel removed, unlock cleared."
}

cmd_unlock() {
  local min="${1:-5}"
  if ! echo "$min" | grep -qE '^[0-9]+$'; then
    echo "Usage: termux-mcp unlock [minutes]"
    return 1
  fi
  local until_ms
  until_ms=$(( ($(date +%s) + min * 60) * 1000 ))
  echo "$until_ms" > "$DATA_DIR/.unlocked_until"
  echo "Unlocked for $min minute(s)."
}

cmd_lock() {
  rm -f "$DATA_DIR/.unlocked_until"
  echo "Locked."
}

cmd_restart_mode() {
  local mode="$1"
  cmd_stop
  sleep 1
  cmd_start_server "$mode"
}

# ============================================================
# Sessions & Logs
# ============================================================

cmd_sessions() {
  echo ""
  echo "Active tmux sessions:"
  echo ""
  tmux ls 2>&1 || echo "(no sessions)"
  echo ""
  echo "Legend:"
  echo "  mcp-server  — the Node process"
  echo "  mcp-ai      — the AI's isolated workspace"
  echo ""
}

cmd_attach_ai() {
  if ! ai_running; then
    echo "The mcp-ai session isn't running."
    echo "Start the server and use the AI, or create it manually."
    return 1
  fi
  echo "Attaching to mcp-ai..."
  echo "Detach with: Ctrl+B then D"
  sleep 1
  tmux attach -t mcp-ai
}

cmd_attach_server() {
  if ! server_running; then
    echo "The mcp-server session isn't running."
    echo "Start it first: termux-mcp start"
    return 1
  fi
  echo "Attaching to mcp-server..."
  echo "Detach with: Ctrl+B then D"
  sleep 1
  tmux attach -t mcp-server
}

cmd_show_server_log() {
  if ! server_running; then
    echo "Server isn't running."
    return 1
  fi
  echo ""
  echo "Last 40 lines of the server log:"
  echo "=============================================="
  tmux capture-pane -t mcp-server -p 2>/dev/null | tail -40
}

cmd_tail_server() {
  if ! server_running; then
    echo "Server isn't running."
    return 1
  fi
  echo "Following server output. Press Ctrl+C to stop."
  echo ""
  while true; do
    tmux capture-pane -t mcp-server -p 2>/dev/null | tail -30
    sleep 1
    clear
  done
}

cmd_show_ai_screen() {
  if ! ai_running; then
    echo "The mcp-ai session isn't running."
    return 1
  fi
  echo ""
  echo "Current screen of mcp-ai (what the AI sees):"
  echo "=============================================="
  tmux capture-pane -t mcp-ai -p 2>/dev/null | tail -30
}

cmd_watch_ai() {
  if ! ai_running; then
    echo "The mcp-ai session isn't running."
    return 1
  fi
  echo "Watching mcp-ai (read-only). Press Ctrl+C to stop."
  sleep 1
  while true; do
    clear
    echo "=== mcp-ai (live) ==="
    tmux capture-pane -t mcp-ai -p 2>/dev/null | tail -40
    sleep 1
  done
}

# ============================================================
# URL / Tailscale commands
# ============================================================

cmd_url() {
  require_tailscale
  local u
  u=$(get_url) || { echo "(no URL — run: tailscale up)"; return 1; }
  echo "$u/mcp"
}

cmd_open_url() {
  require_tailscale
  local u
  u=$(get_url) || { echo "No URL."; return 1; }
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$u/mcp"
    echo "Opened: $u/mcp"
  else
    echo "$u/mcp"
    echo "(termux-open-url not available — install termux-api)"
  fi
}

cmd_copy_url() {
  require_tailscale
  local u
  u=$(get_url) || { echo "No URL."; return 1; }
  if command -v termux-clipboard-set >/dev/null 2>&1; then
    termux-clipboard-set "$u/mcp"
    echo "Copied to clipboard: $u/mcp"
  else
    echo "$u/mcp"
    echo "(termux-clipboard-set not available — install termux-api)"
  fi
}

cmd_qr_url() {
  require_tailscale
  local u
  u=$(get_url) || { echo "No URL."; return 1; }
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "Installing qrencode..."
    pkg install -y qrencode >/dev/null 2>&1
  fi
  qrencode -t ANSIUTF8 "$u/mcp"
}

cmd_qr_totp() {
  if [ ! -f "$DATA_DIR/.totp_secret" ]; then
    echo "No TOTP secret configured."
    return 1
  fi
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "Installing qrencode..."
    pkg install -y qrencode >/dev/null 2>&1
  fi
  local secret
  secret=$(cat "$DATA_DIR/.totp_secret")
  local otpauth="otpauth://totp/TermuxMCP?secret=$secret&issuer=Termux&algorithm=SHA1&digits=6&period=30"
  echo ""
  echo "Scan with Aegis / any authenticator app:"
  echo ""
  qrencode -t ANSIUTF8 "$otpauth"
  echo ""
  echo "Or enter manually:"
  echo "  Account:  Termux MCP"
  echo "  Secret:   $secret"
  echo "  Type:     TOTP"
  echo "  Algo:     SHA1"
  echo "  Digits:   6"
  echo "  Period:   30"
}

cmd_qr_all() {
  echo ""
  echo "=== URL QR ==="
  echo ""
  cmd_qr_url
  echo ""
  echo "=== TOTP QR ==="
  echo ""
  cmd_qr_totp
}

cmd_test_url() {
  require_tailscale
  local u
  u=$(get_url) || { echo "No URL."; return 1; }
  echo ""
  echo "Testing: $u/.well-known/oauth-authorization-server"
  echo ""
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$u/.well-known/oauth-authorization-server" 2>/dev/null)
  case "$code" in
    200)
      echo "  [OK] URL is reachable and serving OAuth metadata"
      ;;
    000)
      echo "  [FAIL] Could not connect. Is the server running?"
      echo "         Start it: termux-mcp start"
      ;;
    401|403)
      echo "  [OK] Reachable, but requires auth (code $code)"
      ;;
    404)
      echo "  [FAIL] Endpoint not found (code 404). Server may be misconfigured."
      ;;
    *)
      echo "  [??] Unexpected response code: $code"
      ;;
  esac
  echo ""
}

cmd_rename() {
  require_tailscale
  local new_name="$1"

  if [ -z "$new_name" ]; then
    printf "New machine name (letters, numbers, dash): "
    read -r new_name
  fi

  if ! echo "$new_name" | grep -qE '^[a-zA-Z0-9-]{1,40}$'; then
    echo "Invalid name. Use letters, numbers, and dashes only."
    return 1
  fi

  local old_url
  old_url=$(get_url) || old_url="(unknown)"

  echo ""
  echo "Renaming machine to: $new_name"
  echo "Old URL: $old_url"
  echo ""

  tailscale up --hostname="$new_name" 2>&1 | tail -3

  sleep 3

  local new_url
  new_url=$(get_url) || new_url="(unknown)"

  echo ""
  echo "New URL: $new_url"

  if [ "$old_url" != "$new_url" ]; then
    echo ""
    echo "URL changed. Re-applying Funnel on port 8000..."
    tailscale funnel reset >/dev/null 2>&1
    tailscale funnel --bg 8000 >/dev/null 2>&1
    echo ""
    echo "Update the connector URL in ChatGPT to:"
    echo "  $new_url/mcp"
  fi
}

cmd_rename_tailnet() {
  echo ""
  echo "Tailnet names cannot be changed from the CLI."
  echo ""
  echo "Open the admin console:"
  echo "  https://login.tailscale.com/admin/dns"
  echo ""
  echo "Look for 'Tailnet name' and click Rename."
  echo ""
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "https://login.tailscale.com/admin/dns"
  fi
}

cmd_funnel() {
  require_tailscale
  local action="$1"
  case "$action" in
    on)
      tailscale funnel reset >/dev/null 2>&1
      tailscale funnel --bg 8000
      echo ""
      tailscale funnel status
      ;;
    off)
      tailscale funnel reset
      echo "Funnel disabled. URL is now unreachable."
      ;;
    ""|status)
      tailscale funnel status
      ;;
    *)
      echo "Usage: termux-mcp funnel [on|off|status]"
      ;;
  esac
}

cmd_ts_status() {
  require_tailscale
  tailscale status
}

# ============================================================
# Auth commands
# ============================================================

cmd_factors() {
  echo ""
  echo "Auth factors:"
  [ -f "$DATA_DIR/.consent_password" ] && echo "  [x] Password" || echo "  [ ] Password"
  [ -f "$DATA_DIR/.totp_secret" ] && echo "  [x] TOTP" || echo "  [ ] TOTP"
  [ -f "$DATA_DIR/.use_dialog" ] && echo "  [x] Device dialog" || echo "  [ ] Device dialog"
  echo ""
}

cmd_password() {
  cat "$DATA_DIR/.consent_password" 2>/dev/null || echo "(no password set)"
}

cmd_totp() {
  cat "$DATA_DIR/.totp_secret" 2>/dev/null || echo "(no TOTP secret set)"
}

cmd_totp_code() {
  local secret
  secret=$(cat "$DATA_DIR/.totp_secret" 2>/dev/null)
  if [ -z "$secret" ]; then
    echo "(no TOTP secret set)"
    return 1
  fi
  oathtool --totp -b "$secret"
}

cmd_reset_password() {
  if ! prompt_yn "Generate a new consent password?"; then
    echo "Cancelled."
    return 1
  fi
  gen_consent_password
  echo ""
  echo "New consent password: $(cat "$DATA_DIR/.consent_password")"
  echo ""
  echo "Restart the server to apply: termux-mcp restart"
}

cmd_reset_totp() {
  if ! prompt_yn "Generate a new TOTP secret? (you'll need to re-add it to your authenticator)"; then
    echo "Cancelled."
    return 1
  fi
  gen_totp_secret
  echo ""
  echo "New TOTP secret: $(cat "$DATA_DIR/.totp_secret")"
  echo ""
  cmd_qr_totp
  echo ""
  echo "Restart the server to apply: termux-mcp restart"
}

cmd_toggle_dialog() {
  if [ -f "$DATA_DIR/.use_dialog" ]; then
    rm -f "$DATA_DIR/.use_dialog"
    echo "Device dialog disabled."
  else
    pkg install -y termux-api >/dev/null 2>&1
    touch "$DATA_DIR/.use_dialog"
    echo "Device dialog enabled."
    echo "Requires the Termux:API app from F-Droid."
  fi
  echo "Restart the server to apply: termux-mcp restart"
}

cmd_revoke_clients() {
  echo ""
  echo "This forces all connected AI clients to re-authenticate."
  echo "ChatGPT and Claude will need to redo the OAuth flow."
  echo ""
  if ! prompt_yn "Revoke all registered clients?"; then
    echo "Cancelled."
    return 1
  fi
  cmd_stop
  sleep 1
  cmd_start_server restricted
  echo ""
  echo "All OAuth clients have been wiped (they were in memory)."
  echo "Reconnect from ChatGPT/Claude now."
}

# ============================================================
# Logs & diagnostics
# ============================================================

cmd_audit() {
  tail -n 50 "$DATA_DIR/audit.log" 2>/dev/null || echo "(no audit log yet)"
}

cmd_tail_audit() {
  tail -f "$DATA_DIR/audit.log" 2>/dev/null || echo "(no audit log yet)"
}

cmd_audit_stats() {
  if [ ! -f "$DATA_DIR/audit.log" ]; then
    echo "(no audit log yet)"
    return 1
  fi
  echo ""
  echo "Audit log statistics:"
  echo "=============================================="
  echo "Total entries:    $(wc -l < "$DATA_DIR/audit.log")"
  echo "File size:        $(du -h "$DATA_DIR/audit.log" | cut -f1)"
  echo ""
  echo "Events by type:"
  grep -o '"event":"[^"]*"' "$DATA_DIR/audit.log" 2>/dev/null | sort | uniq -c | sort -rn | head -20
  echo ""
  echo "Unique clients:"
  grep -o '"client_id":"[^"]*"' "$DATA_DIR/audit.log" 2>/dev/null | sort -u | wc -l
  echo ""
}

cmd_clear_audit() {
  if [ ! -f "$DATA_DIR/audit.log" ]; then
    echo "No audit log to clear."
    return 1
  fi
  local size
  size=$(wc -l < "$DATA_DIR/audit.log")
  if ! prompt_yn "Delete the audit log ($size entries)?"; then
    echo "Cancelled."
    return 1
  fi
  rm -f "$DATA_DIR/audit.log"
  echo "Audit log cleared."
}

cmd_export_audit() {
  if [ ! -f "$DATA_DIR/audit.log" ]; then
    echo "No audit log to export."
    return 1
  fi
  local dest="$HOME/termux-mcp-audit-$(date +%Y%m%d-%H%M%S).log"
  cp "$DATA_DIR/audit.log" "$dest"
  echo "Exported to: $dest"
}

cmd_test() {
  cd "$DATA_DIR"
  node --test test.mjs
}

cmd_info() {
  echo ""
  echo "=== Termux MCP system info ==="
  echo ""
  echo "Server status:  $(server_running && echo running || echo stopped)"
  echo "Mode:           $(server_mode)"
  echo "AI session:     $(ai_running && echo running || echo not running)"

  local url
  url=$(get_url 2>/dev/null)
  if [ -n "$url" ]; then
    echo "MCP URL:        $url/mcp"
  else
    echo "MCP URL:        (unavailable)"
  fi

  echo "Funnel:         $(funnel_active && echo on || echo off)"
  echo "Unlock:         $(is_unlocked && echo active || echo locked)"

  echo ""
  echo "--- Auth ---"
  [ -f "$DATA_DIR/.consent_password" ] && echo "Password:       enabled" || echo "Password:       disabled"
  [ -f "$DATA_DIR/.totp_secret" ] && echo "TOTP:           enabled" || echo "TOTP:           disabled"
  [ -f "$DATA_DIR/.use_dialog" ] && echo "Dialog:         enabled" || echo "Dialog:         disabled"

  echo ""
  echo "--- System ---"
  echo "Node:           $(node -v 2>/dev/null || echo missing)"
  echo "Tailscale:      $(tailscale version 2>/dev/null | head -1 || echo missing)"
  echo "Uptime:         $(uptime | sed 's/.*up //; s/,.*load/ | load/')"
  echo "Disk (home):    $(df -h $HOME | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
  echo "Audit size:     $(du -h "$DATA_DIR/audit.log" 2>/dev/null | cut -f1 || echo 0)"
  echo ""
}

cmd_health() {
  echo ""
  echo "=== Health check ==="
  echo ""

  local issues=0

  # Node
  if command -v node >/dev/null 2>&1; then
    echo "[OK]   Node: $(node -v)"
  else
    echo "[FAIL] Node not installed"
    issues=$((issues+1))
  fi

  # jq
  if command -v jq >/dev/null 2>&1; then
    echo "[OK]   jq installed"
  else
    echo "[WARN] jq not installed"
    issues=$((issues+1))
  fi

  # Tailscale CLI
  if command -v tailscale >/dev/null 2>&1; then
    echo "[OK]   Tailscale CLI installed"
  else
    echo "[FAIL] Tailscale CLI not installed"
    issues=$((issues+1))
  fi

  # Daemon
  if tailscale status >/dev/null 2>&1; then
    echo "[OK]   Tailscale daemon running"
  else
    echo "[FAIL] Tailscale daemon not running"
    issues=$((issues+1))
  fi

  # Funnel
  if funnel_active; then
    echo "[OK]   Funnel on"
  else
    echo "[WARN] Funnel not active"
    issues=$((issues+1))
  fi

  # Server
  if server_running; then
    echo "[OK]   Server running ($(server_mode))"
  else
    echo "[INFO] Server stopped"
  fi

  # URL reachable
  local u
  u=$(get_url 2>/dev/null)
  if [ -n "$u" ] && server_running; then
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$u/.well-known/oauth-authorization-server" 2>/dev/null)
    if [ "$code" = "200" ]; then
      echo "[OK]   URL reachable and serving OAuth"
    else
      echo "[WARN] URL returned code $code"
      issues=$((issues+1))
    fi
  fi

  # Auth factors
  local factors=0
  [ -f "$DATA_DIR/.consent_password" ] && factors=$((factors+1))
  [ -f "$DATA_DIR/.totp_secret" ] && factors=$((factors+1))
  [ -f "$DATA_DIR/.use_dialog" ] && factors=$((factors+1))
  if [ "$factors" -ge 2 ]; then
    echo "[OK]   $factors auth factors enabled"
  else
    echo "[WARN] Only $factors auth factor(s) enabled"
  fi

  echo ""
  if [ "$issues" -eq 0 ]; then
    echo "All systems nominal."
  else
    echo "$issues issue(s) found."
  fi
  echo ""
}

# ============================================================
# Maintenance
# ============================================================

cmd_update() {
  echo "Downloading latest files from GitHub..."
  local failed=0
  for f in server.mjs lib.mjs test.mjs stdio-server.mjs start.sh; do
    if curl -fsSL "$REPO/$f" -o "$DATA_DIR/$f"; then
      echo "  updated: $f"
    else
      echo "  failed:  $f"
      failed=1
    fi
  done
  chmod +x "$DATA_DIR/start.sh"
  echo ""
  if [ "$failed" -eq 0 ]; then
    echo "Update complete."
    echo "Restart to apply: termux-mcp restart"
  else
    echo "Update completed with errors."
  fi
}

cmd_check_update() {
  echo "Checking for updates..."
  local changed=0
  for f in server.mjs lib.mjs test.mjs stdio-server.mjs start.sh; do
    local local_hash remote_hash
    local_hash=$(sha256sum "$DATA_DIR/$f" 2>/dev/null | cut -d' ' -f1)
    remote_hash=$(curl -fsSL "$REPO/$f" 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ "$local_hash" != "$remote_hash" ]; then
      echo "  update available: $f"
      changed=$((changed+1))
    fi
  done
  echo ""
  if [ "$changed" -eq 0 ]; then
    echo "Everything is up to date."
  else
    echo "$changed file(s) have updates."
    echo "Run: termux-mcp update"
  fi
}

cmd_reinstall_deps() {
  echo "Reinstalling dependencies..."
  pkg install -y nodejs-lts tmux jq oathtool termux-api qrencode 2>/dev/null || \
    pkg install -y nodejs tmux jq oathtool termux-api qrencode
  echo ""
  cd "$DATA_DIR"
  npm install @modelcontextprotocol/sdk express zod jose --save-exact
  echo ""
  echo "Done."
}

cmd_backup() {
  local dest="$1"
  if [ -z "$dest" ]; then
    dest="$HOME/termux-mcp-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  fi
  local files=""
  for f in .consent_password .totp_secret .use_dialog .owner_email; do
    [ -f "$DATA_DIR/$f" ] && files="$files $f"
  done
  if [ -z "$files" ]; then
    echo "Nothing to back up."
    return 1
  fi
  (cd "$DATA_DIR" && tar czf "$dest" $files)
  echo "Backup saved to: $dest"
  echo ""
  echo "Keep this file somewhere safe. It contains your"
  echo "consent password and TOTP secret in plaintext."
}

cmd_restore() {
  local src="$1"
  if [ -z "$src" ]; then
    printf "Backup file to restore from: "
    read -r src
  fi
  if [ ! -f "$src" ]; then
    echo "File not found: $src"
    return 1
  fi
  tar xzf "$src" -C "$DATA_DIR"
  chmod 600 "$DATA_DIR/.consent_password" 2>/dev/null
  chmod 600 "$DATA_DIR/.totp_secret" 2>/dev/null
  echo "Restored from: $src"
  echo "Restart to apply: termux-mcp restart"
}

cmd_disk() {
  echo ""
  echo "Disk usage:"
  echo ""
  echo "Termux home:  $(du -sh $HOME 2>/dev/null | cut -f1)"
  echo "  termux-mcp: $(du -sh $DATA_DIR 2>/dev/null | cut -f1)"
  echo "  mcp-work:   $(du -sh ~/mcp-work 2>/dev/null | cut -f1)"
  echo "  mcp-ai-home:$(du -sh ~/mcp-ai-home 2>/dev/null | cut -f1)"
  echo "  node_modules:$(du -sh $DATA_DIR/node_modules 2>/dev/null | cut -f1)"
  echo ""
  df -h $HOME | tail -1
  echo ""
}

# ============================================================
# Command list
# ============================================================

cmd_list() {
  cat <<'EOF'

Termux MCP — all commands
============================================================

SERVER
  termux-mcp start              Start in restricted mode
  termux-mcp unrestricted       Start in unrestricted mode
  termux-mcp stop               Stop the server
  termux-mcp restart            Stop, then start (restricted)
  termux-mcp restart-unrestricted  Stop, then start (unrestricted)
  termux-mcp shutdown           Stop server + remove Funnel (URL dies)
  termux-mcp shutdown-all       Stop everything including Tailscale daemon
  termux-mcp unlock [n]         Allow mutating tools for n minutes (default 5)
  termux-mcp lock               Lock mutating tools immediately
  termux-mcp panic              Kill all + remove Funnel + clear unlock

SESSIONS & LOGS
  termux-mcp sessions           List active tmux sessions
  termux-mcp attach-ai          Attach to mcp-ai (watch AI type)
  termux-mcp attach-server      Attach to mcp-server (live log)
  termux-mcp show-server-log    Show last 40 lines of server log
  termux-mcp tail-server        Follow server output live
  termux-mcp show-ai-screen     Snapshot of what the AI sees
  termux-mcp watch-ai           Read-only live view of mcp-ai

URL & TAILSCALE
  termux-mcp url                Print MCP URL
  termux-mcp open               Open MCP URL in browser
  termux-mcp copy               Copy MCP URL to clipboard
  termux-mcp qr-url             Show MCP URL as QR code
  termux-mcp qr-all             Show URL and TOTP QRs together
  termux-mcp test-url           Test if URL is reachable
  termux-mcp rename [name]      Rename machine (changes URL subdomain)
  termux-mcp rename-tailnet     Open console to rename tailnet
  termux-mcp funnel             Show Funnel status
  termux-mcp funnel on          Enable Funnel on port 8000
  termux-mcp funnel off         Disable Funnel
  termux-mcp ts                 Tailscale status

AUTH
  termux-mcp factors            Show which auth factors are on
  termux-mcp password           Print the consent password
  termux-mcp totp               Print the TOTP secret
  termux-mcp totp-code          Print current valid TOTP code
  termux-mcp qr-totp            Show TOTP secret as QR code
  termux-mcp reset-password     Generate a new password
  termux-mcp reset-totp         Generate a new TOTP secret
  termux-mcp toggle-dialog      Enable/disable the device dialog
  termux-mcp revoke-clients     Force all AI clients to re-authenticate

LOGS & DIAGNOSTICS
  termux-mcp audit              Show last 50 audit entries
  termux-mcp audit-stats        Summary of audit log
  termux-mcp tail               Follow audit log live
  termux-mcp export-audit       Save audit log to a file
  termux-mcp clear-audit        Delete the audit log
  termux-mcp health             Full health check
  termux-mcp info               Show system info
  termux-mcp disk               Show disk usage
  termux-mcp test               Run the test suite

MAINTENANCE
  termux-mcp update             Pull latest files from GitHub
  termux-mcp check-update       Check if updates are available
  termux-mcp reinstall-deps     Reinstall missing packages
  termux-mcp backup [path]      Backup password + TOTP
  termux-mcp restore [path]     Restore from backup

OTHER
  termux-mcp                    Interactive menu
  termux-mcp list               Show this list
  termux-mcp help               Show this list

============================================================
EOF
}

# ============================================================
# Interactive menu
# ============================================================

print_header() {
  local status mode url funnel unlock
  status=$(server_running && echo "running" || echo "stopped")
  mode=$(server_mode)
  url=$(get_url 2>/dev/null || echo "—")
  funnel=$(funnel_active && echo "on" || echo "off")
  unlock=$(is_unlocked && echo "UNLOCKED" || echo "locked")

  echo ""
  echo "=============================================="
  echo "  Termux MCP"
  echo "=============================================="
  echo "  Status:  $status ($mode)"
  echo "  Funnel:  $funnel"
  echo "  Lock:    $unlock"
  echo "  URL:     $url/mcp"
  echo "=============================================="
}

print_menu() {
  echo ""
  echo "  --- Server ---"
  echo "   1) Start (restricted)"
  echo "   2) Start (unrestricted)"
  echo "   3) Stop"
  echo "   4) Restart (restricted)"
  echo "   5) Restart (unrestricted)"
  echo "   6) Unlock mutating tools (5 min)"
  echo "   7) Lock mutating tools"
  echo "   8) Shutdown (stop + remove Funnel)"
  echo "   9) Shutdown all (also stops Tailscale daemon)"
  echo "  10) Panic (emergency kill)"
  echo ""
  echo "  --- Sessions & Logs ---"
  echo "  11) List tmux sessions"
  echo "  12) Attach to mcp-ai (watch AI)"
  echo "  13) Attach to mcp-server (live log)"
  echo "  14) Show server log (last 40 lines)"
  echo "  15) Follow server log"
  echo "  16) Show AI screen (snapshot)"
  echo "  17) Watch AI (read-only live)"
  echo ""
  echo "  --- URL & Tailscale ---"
  echo "  18) Show MCP URL"
  echo "  19) Open MCP URL in browser"
  echo "  20) Copy MCP URL to clipboard"
  echo "  21) Show URL QR code"
  echo "  22) Show URL + TOTP QRs"
  echo "  23) Test if URL is reachable"
  echo "  24) Rename machine (changes URL)"
  echo "  25) Rename tailnet (opens console)"
  echo "  26) Funnel status"
  echo "  27) Enable funnel"
  echo "  28) Disable funnel"
  echo "  29) Tailscale status"
  echo ""
  echo "  --- Auth ---"
  echo "  30) Show auth factors"
  echo "  31) Show consent password"
  echo "  32) Show TOTP secret"
  echo "  33) Show current TOTP code"
  echo "  34) Show TOTP QR code"
  echo "  35) Reset password"
  echo "  36) Reset TOTP"
  echo "  37) Toggle device dialog"
  echo "  38) Revoke all AI clients"
  echo ""
  echo "  --- Logs & Diagnostics ---"
  echo "  39) Audit log (last 50)"
  echo "  40) Audit log stats"
  echo "  41) Follow audit log"
  echo "  42) Export audit log"
  echo "  43) Clear audit log"
  echo "  44) Health check"
  echo "  45) System info"
  echo "  46) Disk usage"
  echo "  47) Run test suite"
  echo ""
  echo "  --- Maintenance ---"
  echo "  48) Update files from GitHub"
  echo "  49) Check for updates"
  echo "  50) Reinstall dependencies"
  echo "  51) Backup config"
  echo "  52) Restore config"
  echo ""
  echo "  53) Show all commands"
  echo "   0) Exit"
  echo ""
}

menu_choice() {
  case "$1" in
    1)  cmd_start_server restricted ;;
    2)  cmd_start_server unrestricted ;;
    3)  cmd_stop ;;
    4)  cmd_restart_mode restricted ;;
    5)  cmd_restart_mode unrestricted ;;
    6)  cmd_unlock 5 ;;
    7)  cmd_lock ;;
    8)  cmd_shutdown ;;
    9)  cmd_shutdown_all ;;
    10) cmd_panic ;;
    11) cmd_sessions ;;
    12) cmd_attach_ai ;;
    13) cmd_attach_server ;;
    14) cmd_show_server_log ;;
    15) echo "Press Ctrl+C to stop."; cmd_tail_server ;;
    16) cmd_show_ai_screen ;;
    17) echo "Press Ctrl+C to stop."; cmd_watch_ai ;;
    18) cmd_url ;;
    19) cmd_open_url ;;
    20) cmd_copy_url ;;
    21) cmd_qr_url ;;
    22) cmd_qr_all ;;
    23) cmd_test_url ;;
    24) cmd_rename ;;
    25) cmd_rename_tailnet ;;
    26) cmd_funnel status ;;
    27) cmd_funnel on ;;
    28) cmd_funnel off ;;
    29) cmd_ts_status ;;
    30) cmd_factors ;;
    31) cmd_password ;;
    32) cmd_totp ;;
    33) cmd_totp_code ;;
    34) cmd_qr_totp ;;
    35) cmd_reset_password ;;
    36) cmd_reset_totp ;;
    37) cmd_toggle_dialog ;;
    38) cmd_revoke_clients ;;
    39) cmd_audit ;;
    40) cmd_audit_stats ;;
    41) echo "Press Ctrl+C to stop following."; cmd_tail_audit ;;
    42) cmd_export_audit ;;
    43) cmd_clear_audit ;;
    44) cmd_health ;;
    45) cmd_info ;;
    46) cmd_disk ;;
    47) cmd_test ;;
    48) cmd_update ;;
    49) cmd_check_update ;;
    50) cmd_reinstall_deps ;;
    51) cmd_backup ;;
    52) cmd_restore ;;
    53) cmd_list ;;
    0)  echo "Bye."; exit 0 ;;
    *)  echo "Invalid choice." ;;
  esac
}

show_menu() {
  while true; do
    clear
    print_header
    print_menu
    printf "  Pick: "
    read -r choice
    echo ""
    menu_choice "$choice"
    echo ""
    printf "  Press Enter to continue..."
    read -r _
  done
}

# ============================================================
# Help
# ============================================================

show_help() {
  cmd_list
}

# ============================================================
# Dispatch
# ============================================================

case "$1" in
  ""|menu)          show_menu ;;
  help|-h|--help)   show_help ;;
  list|commands)    cmd_list ;;

  # Server
  start|restricted)       cmd_start_server restricted ;;
  unrestricted)           cmd_start_server unrestricted ;;
  stop)                   cmd_stop ;;
  restart)                cmd_restart_mode restricted ;;
  restart-unrestricted)   cmd_restart_mode unrestricted ;;
  shutdown)               cmd_shutdown ;;
  shutdown-all)           cmd_shutdown_all ;;
  panic)                  cmd_panic ;;
  unlock)                 cmd_unlock "$2" ;;
  lock)                   cmd_lock ;;

  # Sessions & logs
  sessions)               cmd_sessions ;;
  attach-ai)              cmd_attach_ai ;;
  attach-server)          cmd_attach_server ;;
  show-server-log)        cmd_show_server_log ;;
  tail-server)            cmd_tail_server ;;
  show-ai-screen)         cmd_show_ai_screen ;;
  watch-ai)               cmd_watch_ai ;;

  # URL & Tailscale
  url)                    cmd_url ;;
  open)                   cmd_open_url ;;
  copy)                   cmd_copy_url ;;
  qr-url)                 cmd_qr_url ;;
  qr-all)                 cmd_qr_all ;;
  test-url)               cmd_test_url ;;
  rename)                 cmd_rename "$2" ;;
  rename-tailnet)         cmd_rename_tailnet ;;
  funnel)                 cmd_funnel "$2" ;;
  ts|tailscale)           cmd_ts_status ;;

  # Auth
  factors)                cmd_factors ;;
  password)               cmd_password ;;
  totp)                   cmd_totp ;;
  totp-code)              cmd_totp_code ;;
  qr-totp)                cmd_qr_totp ;;
  reset-password)         cmd_reset_password ;;
  reset-totp)             cmd_reset_totp ;;
  toggle-dialog)          cmd_toggle_dialog ;;
  revoke-clients)         cmd_revoke_clients ;;

  # Logs & diagnostics
  audit)                  cmd_audit ;;
  audit-stats)            cmd_audit_stats ;;
  tail)                   cmd_tail_audit ;;
  export-audit)           cmd_export_audit ;;
  clear-audit)            cmd_clear_audit ;;
  health)                 cmd_health ;;
  info)                   cmd_info ;;
  disk)                   cmd_disk ;;
  test)                   cmd_test ;;

  # Maintenance
  update)                 cmd_update ;;
  check-update)           cmd_check_update ;;
  reinstall-deps)         cmd_reinstall_deps ;;
  backup)                 cmd_backup "$2" ;;
  restore)                cmd_restore "$2" ;;

  *)
    echo "Unknown command: $1"
    echo "Run 'termux-mcp list' for the full list."
    exit 1
    ;;
esac
