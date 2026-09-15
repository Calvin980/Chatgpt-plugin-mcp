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

  mkdir -p ~/mcp-work ~/mcp-ai-home
  tmux kill-session -t mcp-server 2>/dev/null
  tmux kill-session -t mcp-ai 2>/dev/null

  local url
  url=$(get_url) || { echo "Could not read Tailscale DNS name."; return 1; }

  echo ""
  echo "Starting Tailscale Funnel on port 8000..."
  tailscale funnel 8000 >/dev/null 2>&1
  sleep 1

  if ! funnel_active; then
    echo "Warning: Funnel may not be active."
    echo "Enable it: https://login.tailscale.com/admin/dns"
    echo ""
  fi

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

cmd_panic() {
  echo "Killing everything..."
  tmux kill-session -t mcp-server 2>/dev/null
  tmux kill-session -t mcp-ai 2>/dev/null
  termux-wake-unlock 2>/dev/null
  rm -f "$DATA_DIR/.unlocked_until"
  echo "All sessions killed, unlock cleared."
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
    echo "URL changed. Re-enabling Funnel on port 8000..."
    tailscale funnel 8000 >/dev/null 2>&1
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
  echo "Note: this changes the .ts.net part of every URL,"
  echo "so you'll have to update the ChatGPT connector too."
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "https://login.tailscale.com/admin/dns"
  fi
}

cmd_funnel() {
  require_tailscale
  local action="$1"
  case "$action" in
    on)
      tailscale funnel 8000
      echo ""
      tailscale funnel status
      ;;
    off)
      tailscale funnel --https=443 off 2>/dev/null || tailscale funnel reset
      echo "Funnel disabled."
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

# ============================================================
# Logs & diagnostics
# ============================================================

cmd_audit() {
  tail -n 50 "$DATA_DIR/audit.log" 2>/dev/null || echo "(no audit log yet)"
}

cmd_tail_audit() {
  tail -f "$DATA_DIR/audit.log" 2>/dev/null || echo "(no audit log yet)"
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

  local url
  url=$(get_url 2>/dev/null)
  if [ -n "$url" ]; then
    echo "MCP URL:        $url/mcp"
  else
    echo "MCP URL:        (unavailable)"
  fi

  echo "Funnel:         $(funnel_active && echo on || echo off)"

  echo ""
  echo "--- Auth ---"
  [ -f "$DATA_DIR/.consent_password" ] && echo "Password:       enabled" || echo "Password:       disabled"
  [ -f "$DATA_DIR/.totp_secret" ] && echo "TOTP:           enabled" || echo "TOTP:           disabled"
  [ -f "$DATA_DIR/.use_dialog" ] && echo "Dialog:         enabled" || echo "Dialog:         disabled"
  [ -f "$DATA_DIR/.unlocked_until" ] && echo "Unlock:         active" || echo "Unlock:         locked"

  echo ""
  echo "--- System ---"
  echo "Node:           $(node -v 2>/dev/null || echo missing)"
  echo "Tailscale:      $(tailscale version 2>/dev/null | head -1 || echo missing)"
  echo "Uptime:         $(uptime | sed 's/.*up //; s/,.*load/ | load/')"
  echo "Disk (home):    $(df -h $HOME | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
  echo "Audit size:     $(du -h "$DATA_DIR/audit.log" 2>/dev/null | cut -f1 || echo 0)"
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
  termux-mcp unlock [n]         Allow mutating tools for n minutes (default 5)
  termux-mcp lock               Lock mutating tools immediately
  termux-mcp panic              Kill everything and clear unlock

URL & TAILSCALE
  termux-mcp url                Print MCP URL
  termux-mcp open               Open MCP URL in browser
  termux-mcp copy               Copy MCP URL to clipboard
  termux-mcp qr-url             Show MCP URL as QR code
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

LOGS & INFO
  termux-mcp audit              Show last 50 audit entries
  termux-mcp tail               Follow audit log live
  termux-mcp test               Run the test suite
  termux-mcp info               Show system info

MAINTENANCE
  termux-mcp update             Pull latest files from GitHub
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
  local status mode url funnel
  status=$(server_running && echo "running" || echo "stopped")
  mode=$(server_mode)
  url=$(get_url 2>/dev/null || echo "—")
  funnel=$(funnel_active && echo "on" || echo "off")

  echo ""
  echo "=============================================="
  echo "  Termux MCP"
  echo "=============================================="
  echo "  Status:  $status ($mode)"
  echo "  Funnel:  $funnel"
  echo "  URL:     $url/mcp"
  echo "=============================================="
}

print_menu() {
  echo ""
  echo "  --- Server ---"
  echo "   1) Start (restricted)"
  echo "   2) Start (unrestricted)"
  echo "   3) Stop"
  echo "   4) Restart"
  echo "   5) Unlock mutating tools (5 min)"
  echo "   6) Lock mutating tools"
  echo "   7) Panic (kill + clear unlock)"
  echo ""
  echo "  --- URL & Tailscale ---"
  echo "   8) Show MCP URL"
  echo "   9) Open MCP URL in browser"
  echo "  10) Copy MCP URL to clipboard"
  echo "  11) Show URL QR code"
  echo "  12) Rename machine (changes URL)"
  echo "  13) Rename tailnet (opens console)"
  echo "  14) Funnel status"
  echo "  15) Enable funnel"
  echo "  16) Disable funnel"
  echo "  17) Tailscale status"
  echo ""
  echo "  --- Auth ---"
  echo "  18) Show auth factors"
  echo "  19) Show consent password"
  echo "  20) Show TOTP secret"
  echo "  21) Show current TOTP code"
  echo "  22) Show TOTP QR code"
  echo "  23) Reset password"
  echo "  24) Reset TOTP"
  echo "  25) Toggle device dialog"
  echo ""
  echo "  --- Logs & Info ---"
  echo "  26) Audit log (last 50)"
  echo "  27) Follow audit log"
  echo "  28) Run test suite"
  echo "  29) System info"
  echo ""
  echo "  --- Maintenance ---"
  echo "  30) Update files from GitHub"
  echo "  31) Backup config"
  echo "  32) Restore config"
  echo ""
  echo "  33) Show all commands"
  echo "   0) Exit"
  echo ""
}

menu_choice() {
  case "$1" in
    1) cmd_start_server restricted ;;
    2) cmd_start_server unrestricted ;;
    3) cmd_stop ;;
    4) cmd_stop; sleep 1; cmd_start_server restricted ;;
    5) cmd_unlock 5 ;;
    6) cmd_lock ;;
    7) cmd_panic ;;
    8) cmd_url ;;
    9) cmd_open_url ;;
    10) cmd_copy_url ;;
    11) cmd_qr_url ;;
    12) cmd_rename ;;
    13) cmd_rename_tailnet ;;
    14) cmd_funnel status ;;
    15) cmd_funnel on ;;
    16) cmd_funnel off ;;
    17) cmd_ts_status ;;
    18) cmd_factors ;;
    19) cmd_password ;;
    20) cmd_totp ;;
    21) cmd_totp_code ;;
    22) cmd_qr_totp ;;
    23) cmd_reset_password ;;
    24) cmd_reset_totp ;;
    25) cmd_toggle_dialog ;;
    26) cmd_audit ;;
    27) echo "Press Ctrl+C to stop following."; cmd_tail_audit ;;
    28) cmd_test ;;
    29) cmd_info ;;
    30) cmd_update ;;
    31) cmd_backup ;;
    32) cmd_restore ;;
    33) cmd_list ;;
    0) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ;;
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
# Help (same as list)
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
  start|restricted) cmd_start_server restricted ;;
  unrestricted)     cmd_start_server unrestricted ;;
  stop)             cmd_stop ;;
  restart)          cmd_stop; sleep 1; cmd_start_server restricted ;;
  panic)            cmd_panic ;;
  unlock)           cmd_unlock "$2" ;;
  lock)             cmd_lock ;;

  # URL & Tailscale
  url)              cmd_url ;;
  open)             cmd_open_url ;;
  copy)             cmd_copy_url ;;
  qr-url)           cmd_qr_url ;;
  rename)           cmd_rename "$2" ;;
  rename-tailnet)   cmd_rename_tailnet ;;
  funnel)           cmd_funnel "$2" ;;
  ts|tailscale)     cmd_ts_status ;;

  # Auth
  factors)          cmd_factors ;;
  password)         cmd_password ;;
  totp)             cmd_totp ;;
  totp-code)        cmd_totp_code ;;
  qr-totp)          cmd_qr_totp ;;
  reset-password)   cmd_reset_password ;;
  reset-totp)       cmd_reset_totp ;;
  toggle-dialog)    cmd_toggle_dialog ;;

  # Logs & Info
  audit)            cmd_audit ;;
  tail)             cmd_tail_audit ;;
  test)             cmd_test ;;
  info)             cmd_info ;;

  # Maintenance
  update)           cmd_update ;;
  backup)           cmd_backup "$2" ;;
  restore)          cmd_restore "$2" ;;

  *)
    echo "Unknown command: $1"
    echo "Run 'termux-mcp list' for the full list."
    exit 1
    ;;
esac
