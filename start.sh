#!/data/data/com.termux/files/usr/bin/bash
cd ~/termux-mcp

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

server_running() { tmux has-session -t mcp-server 2>/dev/null; }
ai_running() { tmux has-session -t mcp-ai 2>/dev/null; }

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

funnel_active() { tailscale funnel status 2>/dev/null | grep -q "Funnel on"; }
serve_configured() { tailscale funnel status 2>/dev/null | grep -q "proxy http://127.0.0.1:8000"; }

is_unlocked() {
  [ -f "$DATA_DIR/.unlocked_until" ] || return 1
  local until now_ms
  until=$(cat "$DATA_DIR/.unlocked_until" 2>/dev/null)
  [ -z "$until" ] && return 1
  now_ms=$(( $(date +%s) * 1000 ))
  [ "$now_ms" -lt "$until" ]
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

pause() {
  echo ""
  printf "  Press Enter to continue..."
  read -r _
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

gen_recovery_codes() {
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
    fs.writeFileSync('$DATA_DIR/.totp_recovery', JSON.stringify(map, null, 2), { mode: 0o600 });
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

  if ! tmux has-session -t mcp-server 2>/dev/null; then
    echo ""
    echo "ERROR: Server process died immediately."
    echo "Last output:"
    tmux capture-pane -t mcp-server -p 2>/dev/null | tail -20
    exit 1
  fi

  if ! curl -s -o /dev/null --max-time 3 "http://127.0.0.1:8000/.well-known/oauth-authorization-server" 2>/dev/null; then
    echo ""
    echo "ERROR: Server started but isn't responding on port 8000."
    echo "Last output:"
    tmux capture-pane -t mcp-server -p 2>/dev/null | tail -20
    exit 1
  fi

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
  echo "To bring it back: termux-mcp"
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
}

cmd_attach_ai() {
  if ! ai_running; then
    echo "The mcp-ai session isn't running."
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
# URL / Tailscale
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
    echo "(install termux-api to open in browser)"
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
  fi
}

cmd_qr_url() {
  require_tailscale
  local u
  u=$(get_url) || { echo "No URL."; return 1; }
  if ! command -v qrencode >/dev/null 2>&1; then
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
    pkg install -y qrencode >/dev/null 2>&1
  fi
  local secret
  secret=$(cat "$DATA_DIR/.totp_secret")
  local otpauth="otpauth://totp/TermuxMCP?secret=$secret&issuer=Termux&algorithm=SHA1&digits=6&period=30"
  echo ""
  echo "Scan with Aegis / any authenticator app:"
  echo ""
  qrencode -t ANSIUTF8 "$otpauth"
}

cmd_qr_all() {
  echo ""
  echo "=== URL QR ==="
  cmd_qr_url
  echo ""
  echo "=== TOTP QR ==="
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
    200) echo "  [OK] URL is reachable and serving OAuth metadata" ;;
    000) echo "  [FAIL] Could not connect. Is the server running?" ;;
    401|403) echo "  [OK] Reachable, requires auth (code $code)" ;;
    404) echo "  [FAIL] Endpoint not found (code 404)" ;;
    *) echo "  [??] Unexpected response code: $code" ;;
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
    echo "Invalid name."
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
    echo "URL changed. Re-applying Funnel..."
    tailscale funnel reset >/dev/null 2>&1
    tailscale funnel --bg 8000 >/dev/null 2>&1
    echo ""
    echo "Update the ChatGPT connector URL to:"
    echo "  $new_url/mcp"
  fi
}

cmd_rename_tailnet() {
  echo ""
  echo "Tailnet names must be changed in the admin console:"
  echo "  https://login.tailscale.com/admin/dns"
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
  local recovery="0"
  if [ -f "$DATA_DIR/.totp_recovery" ]; then
    recovery=$(node -e "try { const j = require('$DATA_DIR/.totp_recovery'); console.log(Object.keys(j).length); } catch { console.log('0'); }" 2>/dev/null || echo 0)
  fi
  echo "Recovery codes remaining: $recovery"
  echo ""
}

cmd_password() { cat "$DATA_DIR/.consent_password" 2>/dev/null || echo "(no password set)"; }
cmd_totp() { cat "$DATA_DIR/.totp_secret" 2>/dev/null || echo "(no TOTP secret set)"; }

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
  echo "Restart: termux-mcp restart"
}

cmd_reset_totp() {
  if ! prompt_yn "Generate a new TOTP secret?"; then
    echo "Cancelled."
    return 1
  fi
  gen_totp_secret
  echo ""
  echo "New TOTP secret: $(cat "$DATA_DIR/.totp_secret")"
  echo ""
  cmd_qr_totp
  echo ""
  if prompt_yn "Also generate new recovery codes?"; then
    gen_recovery_codes
  fi
  echo "Restart: termux-mcp restart"
}

cmd_toggle_dialog() {
  if [ -f "$DATA_DIR/.use_dialog" ]; then
    rm -f "$DATA_DIR/.use_dialog"
    echo "Device dialog disabled."
  else
    pkg install -y termux-api >/dev/null 2>&1
    touch "$DATA_DIR/.use_dialog"
    echo "Device dialog enabled."
  fi
  echo "Restart: termux-mcp restart"
}

cmd_revoke_clients() {
  echo ""
  echo "This wipes all registered clients and tokens."
  echo "Every AI client must re-authenticate."
  echo ""
  if ! prompt_yn "Revoke everything?"; then
    echo "Cancelled."
    return 1
  fi
  cmd_stop
  rm -f "$DATA_DIR/state/clients.json" "$DATA_DIR/state/tokens.json" "$DATA_DIR/state/refresh_tokens.json"
  sleep 1
  cmd_start_server restricted
  echo ""
  echo "All OAuth state wiped. Reconnect from ChatGPT."
}

cmd_revoke_client() {
  local client_id="$1"

  if [ -z "$client_id" ]; then
    echo ""
    echo "Registered clients:"
    echo ""
    if [ -f "$DATA_DIR/state/clients.json" ]; then
      node -e "
        try {
          const j = require('$DATA_DIR/state/clients.json');
          Object.keys(j).forEach(id => {
            const name = j[id].client_name || '(unnamed)';
            console.log('  ' + id + '  ' + name);
          });
        } catch { console.log('  (none)'); }
      " 2>/dev/null
    else
      echo "  (none)"
    fi
    echo ""
    printf "Client ID to revoke (or 'cancel'): "
    read -r client_id
  fi

  [ "$client_id" = "cancel" ] && { echo "Cancelled."; return 0; }
  [ -z "$client_id" ] && { echo "No client ID."; return 1; }

  if ! prompt_yn "Revoke all tokens for $client_id?"; then
    echo "Cancelled."
    return 1
  fi

  # Kill tokens by editing state files
  node -e "
    const fs = require('fs');
    const cid = '$client_id';
    for (const file of ['tokens.json', 'refresh_tokens.json']) {
      const path = '$DATA_DIR/state/' + file;
      try {
        const j = JSON.parse(fs.readFileSync(path, 'utf8'));
        let removed = 0;
        for (const k of Object.keys(j)) {
          if (j[k].client_id === cid) { delete j[k]; removed++; }
        }
        fs.writeFileSync(path, JSON.stringify(j, null, 2));
        console.log('  ' + file + ': removed ' + removed);
      } catch (e) { console.log('  ' + file + ': ' + e.message); }
    }
  "
  echo ""
  echo "Restart to apply: termux-mcp restart"
}

cmd_recovery_init() {
  if [ -f "$DATA_DIR/.totp_recovery" ]; then
    local count
    count=$(node -e "try { const j = require('$DATA_DIR/.totp_recovery'); console.log(Object.keys(j).length); } catch { console.log('0'); }" 2>/dev/null || echo 0)
    echo ""
    echo "You currently have $count recovery codes remaining."
    if ! prompt_yn "Generate a fresh set of 10 (invalidates old codes)?"; then
      echo "Cancelled."
      return 1
    fi
  fi

  gen_recovery_codes
}

cmd_recovery_show() {
  if [ ! -f "$DATA_DIR/.totp_recovery" ]; then
    echo "No recovery codes configured."
    return 1
  fi
  local count
  count=$(node -e "try { const j = require('$DATA_DIR/.totp_recovery'); console.log(Object.keys(j).length); } catch { console.log('0'); }" 2>/dev/null || echo 0)
  echo ""
  echo "Recovery codes remaining: $count"
  echo ""
  echo "(Codes themselves are stored as hashes and cannot be displayed.)"
  echo "If you've lost the printed list:"
  echo "  termux-mcp recovery-init   (generates new codes)"
}

cmd_notify() {
  local topic="$1"
  local file="$DATA_DIR/.ntfy_topic"

  if [ -z "$topic" ]; then
    if [ -f "$file" ]; then
      echo "ntfy topic: $(cat "$file")"
    else
      echo "(no ntfy topic configured)"
    fi
    echo ""
    echo "Usage: termux-mcp notify <topic>"
    echo "       termux-mcp notify off"
    return 0
  fi

  if [ "$topic" = "off" ] || [ "$topic" = "none" ]; then
    rm -f "$file"
    echo "Notifications disabled."
    return 0
  fi

  echo "$topic" > "$file"
  chmod 600 "$file"
  echo "Notifications enabled on topic: $topic"
  curl -s -d "Termux MCP notifications enabled" "https://ntfy.sh/$topic" >/dev/null 2>&1
}

# ============================================================
# Logs & Diagnostics
# ============================================================

cmd_audit() { tail -n 50 "$DATA_DIR/audit.log" 2>/dev/null || echo "(no audit log yet)"; }
cmd_tail_audit() { tail -f "$DATA_DIR/audit.log" 2>/dev/null || echo "(no audit log yet)"; }

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
}

cmd_audit_analyze() {
  local days="${1:-7}"
  cd "$DATA_DIR"
  node -e "
    import('./audit.mjs').then(async ({ analyzeAudit }) => {
      const r = await analyzeAudit({ days: $days });
      if (r.error) { console.log(r.error); return; }
      console.log('');
      console.log('=== Audit analyzer (last $days days) ===');
      console.log('');
      console.log('Total entries:      ' + r.entries);
      console.log('Unique clients:     ' + r.unique_clients);
      console.log('Failed auth count:  ' + r.failed_auth_count);
      console.log('Commands logged:    ' + r.commands_count);
      console.log('Honeypot hits:      ' + r.honeypot_count);
      console.log('');
      console.log('Top events:');
      r.events.forEach(([k, n]) => console.log('  ' + String(n).padStart(5) + '  ' + k));
      console.log('');
      console.log('Top tools:');
      r.tools.forEach(([k, n]) => console.log('  ' + String(n).padStart(5) + '  ' + k));
      console.log('');
      if (r.commands_recent.length) {
        console.log('Recent commands:');
        r.commands_recent.forEach(c => console.log('  [' + c.ts.slice(11,19) + '] ' + c.command));
        console.log('');
      }
      if (r.failed_auth_recent.length) {
        console.log('Recent failed auth:');
        r.failed_auth_recent.forEach(f => console.log('  [' + f.ts.slice(11,19) + '] ' + f.event));
        console.log('');
      }
      if (r.honeypot_recent.length) {
        console.log('Recent honeypot hits:');
        r.honeypot_recent.forEach(h => console.log('  [' + h.ts.slice(11,19) + '] ' + h.tool));
        console.log('');
      }
    }).catch(e => console.error('Error:', e.message));
  "
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

cmd_test_http() {
  cd "$DATA_DIR"
  MCP_TEST=1 MCP_DATA_DIR="/tmp/termux-mcp-test-$$" node --test test-http.mjs
  rm -rf "/tmp/termux-mcp-test-$$"
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
  fi

  echo "Funnel:         $(funnel_active && echo on || echo off)"
  echo "Unlock:         $(is_unlocked && echo active || echo locked)"

  echo ""
  echo "--- Auth ---"
  [ -f "$DATA_DIR/.consent_password" ] && echo "Password:       enabled" || echo "Password:       disabled"
  [ -f "$DATA_DIR/.totp_secret" ] && echo "TOTP:           enabled" || echo "TOTP:           disabled"
  [ -f "$DATA_DIR/.use_dialog" ] && echo "Dialog:         enabled" || echo "Dialog:         disabled"

  echo ""
  echo "--- OAuth state ---"
  if [ -f "$DATA_DIR/state/clients.json" ]; then
    echo "Clients:        $(node -e "const j=require('$DATA_DIR/state/clients.json');console.log(Object.keys(j).length)" 2>/dev/null || echo 0)"
  fi
  if [ -f "$DATA_DIR/state/tokens.json" ]; then
    echo "Tokens:         $(node -e "const j=require('$DATA_DIR/state/tokens.json');console.log(Object.keys(j).length)" 2>/dev/null || echo 0)"
  fi
  if [ -f "$DATA_DIR/state/refresh_tokens.json" ]; then
    echo "Refresh tokens: $(node -e "const j=require('$DATA_DIR/state/refresh_tokens.json');console.log(Object.keys(j).length)" 2>/dev/null || echo 0)"
  fi

  echo ""
  echo "--- System ---"
  echo "Node:           $(node -v 2>/dev/null || echo missing)"
  echo "Uptime:         $(uptime | sed 's/.*up //; s/,.*load/ | load/')"
  echo "Disk (home):    $(df -h $HOME | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
  echo ""
}

cmd_health() {
  echo ""
  echo "=== Health check ==="
  echo ""

  local issues=0

  if command -v node >/dev/null 2>&1; then echo "[OK]   Node: $(node -v)"; else echo "[FAIL] Node not installed"; issues=$((issues+1)); fi
  if command -v jq >/dev/null 2>&1; then echo "[OK]   jq installed"; else echo "[WARN] jq not installed"; issues=$((issues+1)); fi
  if command -v tailscale >/dev/null 2>&1; then echo "[OK]   Tailscale CLI installed"; else echo "[FAIL] Tailscale not installed"; issues=$((issues+1)); fi
  if tailscale status >/dev/null 2>&1; then echo "[OK]   Tailscale daemon running"; else echo "[FAIL] Tailscale daemon not running"; issues=$((issues+1)); fi
  if funnel_active; then echo "[OK]   Funnel on"; else echo "[WARN] Funnel not active"; issues=$((issues+1)); fi
  if server_running; then echo "[OK]   Server running ($(server_mode))"; else echo "[INFO] Server stopped"; fi

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

cmd_disk() {
  echo ""
  echo "Disk usage:"
  echo ""
  echo "Termux home:   $(du -sh $HOME 2>/dev/null | cut -f1)"
  echo "  termux-mcp:  $(du -sh $DATA_DIR 2>/dev/null | cut -f1)"
  echo "  mcp-work:    $(du -sh ~/mcp-work 2>/dev/null | cut -f1)"
  echo "  mcp-ai-home: $(du -sh ~/mcp-ai-home 2>/dev/null | cut -f1)"
  echo "  node_modules:$(du -sh $DATA_DIR/node_modules 2>/dev/null | cut -f1)"
  echo "  state:       $(du -sh $DATA_DIR/state 2>/dev/null | cut -f1)"
  echo ""
  df -h $HOME | tail -1
  echo ""
}

# ============================================================
# Config
# ============================================================

cmd_config_show() {
  local file="$DATA_DIR/config.json"
  echo ""
  if [ ! -f "$file" ]; then
    echo "No config.json — using defaults."
    echo ""
    echo "Copy the example to customize:"
    echo "  cp ~/termux-mcp/config.json.example ~/termux-mcp/config.json"
    echo "  termux-mcp config-edit"
    echo ""
    return 0
  fi
  echo "Current config:"
  echo "=============================================="
  cat "$file"
  echo ""
  echo "=============================================="
}

cmd_config_edit() {
  local file="$DATA_DIR/config.json"
  if [ ! -f "$file" ]; then
    if [ -f "$DATA_DIR/config.json.example" ]; then
      cp "$DATA_DIR/config.json.example" "$file"
      echo "Created config.json from example."
    else
      echo "{}" > "$file"
      echo "Created empty config.json."
    fi
  fi

  if command -v nano >/dev/null 2>&1; then
    nano "$file"
  elif command -v vi >/dev/null 2>&1; then
    vi "$file"
  else
    echo "No editor found. Install: pkg install nano"
    return 1
  fi

  # Validate JSON
  if node -e "JSON.parse(require('fs').readFileSync('$file','utf8'))" 2>/dev/null; then
    echo "config.json is valid."
    echo "Restart to apply: termux-mcp restart"
  else
    echo "WARNING: config.json is not valid JSON. Fix it before restarting."
  fi
}

cmd_config_reset() {
  local file="$DATA_DIR/config.json"
  if [ ! -f "$file" ]; then
    echo "No config.json to remove."
    return 0
  fi
  if ! prompt_yn "Delete config.json and go back to defaults?"; then
    echo "Cancelled."
    return 1
  fi
  rm -f "$file"
  echo "Removed. Restart to apply: termux-mcp restart"
}

# ============================================================
# Maintenance
# ============================================================

cmd_update() {
  echo "Downloading latest files from GitHub..."
  local failed=0
  for f in server.mjs config.mjs audit.mjs state.mjs oauth.mjs tools.mjs http.mjs lib.mjs test.mjs test-http.mjs stdio-server.mjs start.sh config.json.example; do
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
    echo "Restart: termux-mcp restart"
  else
    echo "Update completed with errors."
  fi
}

cmd_check_update() {
  echo "Checking for updates..."
  local changed=0
  for f in server.mjs config.mjs audit.mjs state.mjs oauth.mjs tools.mjs http.mjs lib.mjs test.mjs test-http.mjs stdio-server.mjs start.sh; do
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
  for f in .consent_password .totp_secret .totp_recovery .use_dialog .owner_email .ntfy_topic config.json; do
    [ -f "$DATA_DIR/$f" ] && files="$files $f"
  done
  if [ -z "$files" ]; then
    echo "Nothing to back up."
    return 1
  fi
  (cd "$DATA_DIR" && tar czf "$dest" $files)
  echo "Backup saved to: $dest"
  echo ""
  echo "Contains your password, TOTP secret, recovery codes,"
  echo "and config. Keep it safe."
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
  chmod 600 "$DATA_DIR/.totp_recovery" 2>/dev/null
  echo "Restored from: $src"
  echo "Restart: termux-mcp restart"
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
  termux-mcp shutdown           Stop server + remove Funnel
  termux-mcp shutdown-all       Stop everything including Tailscale daemon
  termux-mcp unlock [n]         Allow mutating tools for n minutes
  termux-mcp lock               Lock mutating tools immediately
  termux-mcp panic              Kill all + remove Funnel + clear unlock

SESSIONS & LOGS
  termux-mcp sessions           List active tmux sessions
  termux-mcp attach-ai          Attach to mcp-ai
  termux-mcp attach-server      Attach to mcp-server
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
  termux-mcp factors            Show auth factors + recovery count
  termux-mcp password           Print the consent password
  termux-mcp totp               Print the TOTP secret
  termux-mcp totp-code          Print current valid TOTP code
  termux-mcp qr-totp            Show TOTP secret as QR code
  termux-mcp reset-password     Generate a new password
  termux-mcp reset-totp         Generate a new TOTP secret
  termux-mcp toggle-dialog      Enable/disable the device dialog
  termux-mcp recovery-init      Generate new recovery codes
  termux-mcp recovery-show      Show recovery code count
  termux-mcp revoke             Revoke all clients + tokens
  termux-mcp revoke-client      Revoke one client by ID
  termux-mcp notify             Show ntfy topic
  termux-mcp notify <topic>     Set ntfy topic
  termux-mcp notify off         Disable notifications

LOGS & DIAGNOSTICS
  termux-mcp audit              Show last 50 audit entries
  termux-mcp audit-stats        Quick event counts
  termux-mcp audit-analyze [d]  Detailed analysis (default 7 days)
  termux-mcp tail               Follow audit log live
  termux-mcp export-audit       Save audit log to a file
  termux-mcp clear-audit        Delete the audit log
  termux-mcp health             Full health check
  termux-mcp info               System info
  termux-mcp disk               Disk usage
  termux-mcp test               Run pure logic test suite
  termux-mcp test-http          Run HTTP test suite

CONFIG
  termux-mcp config-show        Show current config.json
  termux-mcp config-edit        Edit config.json
  termux-mcp config-reset       Delete config.json (back to defaults)

MAINTENANCE
  termux-mcp update             Pull latest files from GitHub
  termux-mcp check-update       Check if updates are available
  termux-mcp reinstall-deps     Reinstall missing packages
  termux-mcp backup [path]      Backup secrets + config
  termux-mcp restore [path]     Restore from backup

OTHER
  termux-mcp                    Interactive menu
  termux-mcp list               Show this list
  termux-mcp help               Show this list

============================================================
EOF
}

# ============================================================
# Interactive menu (with submenus)
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

menu_server() {
  while true; do
    clear
    print_header
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
    echo "   9) Shutdown all (also stops Tailscale)"
    echo "  10) Panic (emergency)"
    echo ""
    echo "   0) Back"
    echo ""
    printf "  Pick: "
    read -r c
    case "$c" in
      1) cmd_start_server restricted; pause ;;
      2) cmd_start_server unrestricted; pause ;;
      3) cmd_stop; pause ;;
      4) cmd_restart_mode restricted; pause ;;
      5) cmd_restart_mode unrestricted; pause ;;
      6) cmd_unlock 5; pause ;;
      7) cmd_lock; pause ;;
      8) cmd_shutdown; pause ;;
      9) cmd_shutdown_all; pause ;;
      10) cmd_panic; pause ;;
      0) return ;;
    esac
  done
}

menu_sessions() {
  while true; do
    clear
    print_header
    echo ""
    echo "  --- Sessions & Logs ---"
    echo "   1) List tmux sessions"
    echo "   2) Attach to mcp-ai (watch AI type)"
    echo "   3) Attach to mcp-server (live log)"
    echo "   4) Show server log (last 40 lines)"
    echo "   5) Follow server log"
    echo "   6) Show AI screen (snapshot)"
    echo "   7) Watch AI (read-only live)"
    echo ""
    echo "   0) Back"
    echo ""
    printf "  Pick: "
    read -r c
    case "$c" in
      1) cmd_sessions; pause ;;
      2) cmd_attach_ai; pause ;;
      3) cmd_attach_server; pause ;;
      4) cmd_show_server_log; pause ;;
      5) echo "Press Ctrl+C to stop."; cmd_tail_server; pause ;;
      6) cmd_show_ai_screen; pause ;;
      7) echo "Press Ctrl+C to stop."; cmd_watch_ai; pause ;;
      0) return ;;
    esac
  done
}

menu_url() {
  while true; do
    clear
    print_header
    echo ""
    echo "  --- URL & Tailscale ---"
    echo "   1) Show MCP URL"
    echo "   2) Open MCP URL in browser"
    echo "   3) Copy MCP URL to clipboard"
    echo "   4) Show URL QR code"
    echo "   5) Show URL + TOTP QRs"
    echo "   6) Test if URL is reachable"
    echo "   7) Rename machine (changes URL)"
    echo "   8) Rename tailnet (opens console)"
    echo "   9) Funnel status"
    echo "  10) Enable funnel"
    echo "  11) Disable funnel"
    echo "  12) Tailscale status"
    echo ""
    echo "   0) Back"
    echo ""
    printf "  Pick: "
    read -r c
    case "$c" in
      1) cmd_url; pause ;;
      2) cmd_open_url; pause ;;
      3) cmd_copy_url; pause ;;
      4) cmd_qr_url; pause ;;
      5) cmd_qr_all; pause ;;
      6) cmd_test_url; pause ;;
      7) cmd_rename; pause ;;
      8) cmd_rename_tailnet; pause ;;
      9) cmd_funnel status; pause ;;
      10) cmd_funnel on; pause ;;
      11) cmd_funnel off; pause ;;
      12) cmd_ts_status; pause ;;
      0) return ;;
    esac
  done
}

menu_auth() {
  while true; do
    clear
    print_header
    echo ""
    echo "  --- Auth ---"
    echo "   1) Show auth factors"
    echo "   2) Show consent password"
    echo "   3) Show TOTP secret"
    echo "   4) Show current TOTP code"
    echo "   5) Show TOTP QR code"
    echo "   6) Reset password"
    echo "   7) Reset TOTP"
    echo "   8) Toggle device dialog"
    echo "   9) Generate new recovery codes"
    echo "  10) Show recovery code count"
    echo "  11) Revoke all clients"
    echo "  12) Revoke one client"
    echo "  13) Show/set ntfy topic"
    echo "  14) Disable notifications"
    echo ""
    echo "   0) Back"
    echo ""
    printf "  Pick: "
    read -r c
    case "$c" in
      1) cmd_factors; pause ;;
      2) cmd_password; pause ;;
      3) cmd_totp; pause ;;
      4) cmd_totp_code; pause ;;
      5) cmd_qr_totp; pause ;;
      6) cmd_reset_password; pause ;;
      7) cmd_reset_totp; pause ;;
      8) cmd_toggle_dialog; pause ;;
      9) cmd_recovery_init; pause ;;
      10) cmd_recovery_show; pause ;;
      11) cmd_revoke_clients; pause ;;
      12) cmd_revoke_client; pause ;;
      13) cmd_notify; pause ;;
      14) cmd_notify off; pause ;;
      0) return ;;
    esac
  done
}

menu_diagnostics() {
  while true; do
    clear
    print_header
    echo ""
    echo "  --- Logs & Diagnostics ---"
    echo "   1) Audit log (last 50)"
    echo "   2) Audit stats (quick)"
    echo "   3) Audit analyzer (7 days)"
    echo "   4) Follow audit log"
    echo "   5) Export audit log"
    echo "   6) Clear audit log"
    echo "   7) Health check"
    echo "   8) System info"
    echo "   9) Disk usage"
    echo "  10) Run test suite"
    echo "  11) Run HTTP tests"
    echo ""
    echo "   0) Back"
    echo ""
    printf "  Pick: "
    read -r c
    case "$c" in
      1) cmd_audit; pause ;;
      2) cmd_audit_stats; pause ;;
      3) cmd_audit_analyze 7; pause ;;
      4) echo "Press Ctrl+C to stop."; cmd_tail_audit; pause ;;
      5) cmd_export_audit; pause ;;
      6) cmd_clear_audit; pause ;;
      7) cmd_health; pause ;;
      8) cmd_info; pause ;;
      9) cmd_disk; pause ;;
      10) cmd_test; pause ;;
      11) cmd_test_http; pause ;;
      0) return ;;
    esac
  done
}

menu_maintenance() {
  while true; do
    clear
    print_header
    echo ""
    echo "  --- Maintenance ---"
    echo "   1) Update files from GitHub"
    echo "   2) Check for updates"
    echo "   3) Reinstall dependencies"
    echo "   4) Backup config"
    echo "   5) Restore config"
    echo ""
    echo "  --- Config ---"
    echo "   6) Show config"
    echo "   7) Edit config"
    echo "   8) Reset config"
    echo ""
    echo "   0) Back"
    echo ""
    printf "  Pick: "
    read -r c
    case "$c" in
      1) cmd_update; pause ;;
      2) cmd_check_update; pause ;;
      3) cmd_reinstall_deps; pause ;;
      4) cmd_backup; pause ;;
      5) cmd_restore; pause ;;
      6) cmd_config_show; pause ;;
      7) cmd_config_edit; pause ;;
      8) cmd_config_reset; pause ;;
      0) return ;;
    esac
  done
}

show_menu() {
  while true; do
    clear
    print_header
    echo ""
    echo "  --- Main Menu ---"
    echo "   1) Server"
    echo "   2) Sessions & Logs"
    echo "   3) URL & Tailscale"
    echo "   4) Auth"
    echo "   5) Logs & Diagnostics"
    echo "   6) Maintenance & Config"
    echo "   7) Show all commands"
    echo "   0) Exit"
    echo ""
    printf "  Pick: "
    read -r choice
    case "$choice" in
      1) menu_server ;;
      2) menu_sessions ;;
      3) menu_url ;;
      4) menu_auth ;;
      5) menu_diagnostics ;;
      6) menu_maintenance ;;
      7) clear; cmd_list; pause ;;
      0) echo "Bye."; exit 0 ;;
    esac
  done
}

show_help() { cmd_list; }

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
  recovery-init)          cmd_recovery_init ;;
  recovery-show)          cmd_recovery_show ;;
  revoke)                 cmd_revoke_clients ;;
  revoke-client)          cmd_revoke_client "$2" ;;
  notify)                 cmd_notify "$2" ;;

  # Logs & diagnostics
  audit)                  cmd_audit ;;
  audit-stats)            cmd_audit_stats ;;
  audit-analyze)          cmd_audit_analyze "$2" ;;
  tail)                   cmd_tail_audit ;;
  export-audit)           cmd_export_audit ;;
  clear-audit)            cmd_clear_audit ;;
  health)                 cmd_health ;;
  info)                   cmd_info ;;
  disk)                   cmd_disk ;;
  test)                   cmd_test ;;
  test-http)              cmd_test_http ;;

  # Config
  config-show)            cmd_config_show ;;
  config-edit)            cmd_config_edit ;;
  config-reset)           cmd_config_reset ;;

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
