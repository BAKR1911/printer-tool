#!/bin/bash
# ===============================================================
# printers.sh - IT Aman / Printer Tool (Stable, full-featured)
# Version: 11.8
# Purpose: Branch-first UI, network-only deploy, self-update, merge DB,
#          single desktop shortcut, robust CUPS deploy with validation.
# ===============================================================
set -euo pipefail
IFS=$'\n\t'

CURRENT_VERSION="11.8"
REPO_RAW="https://raw.githubusercontent.com/BAKR1911/printer-tool/main"
APP="printer-tool"
INSTALL_DIR="/opt/$APP"
BIN_LINK="/usr/local/bin/$APP"
DESKTOP_NAME="printer-tool.desktop"
LOG="/var/log/$APP.log"
PRINTERS_LIST="printers.list"
VERSION_FILE="version.txt"
ICON_NAME="printer.png"
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" "/usr/share/cups/drv" )
TMP_PREFIX="/tmp/${APP}_$$"

_info(){ printf '%s [INFO] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG" 2>/dev/null; }
_warn(){ printf '%s [WARN] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG" 2>/dev/null; }
_err(){ printf '%s [ERROR] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG" >&2 2>/dev/null; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
touch "$LOG" 2>/dev/null || true
chmod 644 "$LOG" 2>/dev/null || true

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "$HOME")"

detect_desktop_dir(){
  local desktop
  desktop=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP 2>/dev/null || true)
  if [ -n "$desktop" ] && [ -d "$desktop" ]; then
    echo "$desktop"
    return
  fi
  if [ -d "$USER_HOME/Desktop" ]; then echo "$USER_HOME/Desktop"; return; fi
  if [ -d "$USER_HOME/سطح المكتب" ]; then echo "$USER_HOME/سطح المكتب"; return; fi
  mkdir -p "$USER_HOME/Desktop" 2>/dev/null || true
  echo "$USER_HOME/Desktop"
}
DESKTOP_DIR="$(detect_desktop_dir)"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

SUDO_CMD=""
if [ "$EUID" -ne 0 ]; then SUDO_CMD="sudo"; fi

# Self-install (copy to /opt and symlink) - idempotent
self_install(){
  if [ "$SCRIPT_PATH" != "$INSTALL_DIR/printers.sh" ]; then
    _info "Installing $APP to $INSTALL_DIR ..."
    $SUDO_CMD mkdir -p "$INSTALL_DIR"
    $SUDO_CMD cp -f "$SCRIPT_PATH" "$INSTALL_DIR/printers.sh"
    $SUDO_CMD chmod +x "$INSTALL_DIR/printers.sh"
    if [ -f "$SCRIPT_DIR/$PRINTERS_LIST" ]; then
      if $SUDO_CMD test -f "$INSTALL_DIR/$PRINTERS_LIST"; then
        # merge local into installed as additions (keep remote authoritative later on)
        tmpsrc=$(mktemp "$TMP_PREFIX.src.XXXX")
        cp -f "$SCRIPT_DIR/$PRINTERS_LIST" "$tmpsrc"
        $SUDO_CMD bash -c "awk 'NF && \$0 !~ /^#/ {print \$0}' '$tmpsrc' | while IFS= read -r line; do if ! grep -Fxq \"\$line\" '$INSTALL_DIR/$PRINTERS_LIST'; then echo \"\$line\" >> '$INSTALL_DIR/$PRINTERS_LIST'; fi; done"
        rm -f "$tmpsrc" 2>/dev/null || true
      else
        $SUDO_CMD cp -f "$SCRIPT_DIR/$PRINTERS_LIST" "$INSTALL_DIR/$PRINTERS_LIST"
      fi
    fi
    if [ -f "$SCRIPT_DIR/$ICON_NAME" ]; then
      $SUDO_CMD cp -f "$SCRIPT_DIR/$ICON_NAME" "$INSTALL_DIR/$ICON_NAME"
    fi
    $SUDO_CMD ln -sf "$INSTALL_DIR/printers.sh" "$BIN_LINK"
    $SUDO_CMD chmod +x "$BIN_LINK"
    _info "Installed. Re-executing installed script..."
    exec $SUDO_CMD "$INSTALL_DIR/printers.sh" "$@"
    exit 0
  fi
}

ensure_single_desktop(){
  [ -n "$DESKTOP_DIR" ] || return 0
  local desktop_path="$DESKTOP_DIR/$DESKTOP_NAME"
  local legacy=("IT-Aman.desktop" "IT-Aman-Tool.desktop" "Printer-Tool.desktop" "$DESKTOP_NAME")
  for n in "${legacy[@]}"; do
    $SUDO_CMD rm -f "$DESKTOP_DIR/$n" 2>/dev/null || true
  done
  local exec_cmd="sudo $BIN_LINK"
  local iconpath="$INSTALL_DIR/$ICON_NAME"
  if ! $SUDO_CMD test -f "$iconpath"; then iconpath="printer"; fi
  tmpfile=$(mktemp "$TMP_PREFIX.desktop.XXXX")
  cat > "$tmpfile" <<EOF
[Desktop Entry]
Name=Printer Tool
Comment=IT Printer Management Tool
Exec=$exec_cmd
Icon=$iconpath
Terminal=false
Type=Application
Categories=Utility;
EOF
  $SUDO_CMD mv -f "$tmpfile" "$desktop_path"
  $SUDO_CMD chown "$REAL_USER:$REAL_USER" "$desktop_path" 2>/dev/null || true
  $SUDO_CMD chmod +x "$desktop_path" 2>/dev/null || true
  sudo -u "$REAL_USER" gio set "$desktop_path" "metadata::trusted" true 2>/dev/null || true
  _info "Desktop shortcut ensured: $desktop_path"
}

# -----------------------
# IMPORTANT CHANGE: fetch_and_merge_db (remote-first overwrite + append local-only)
# -----------------------
fetch_and_merge_db(){
  tmp_remote=$(mktemp "$TMP_PREFIX.remote.XXXX")
  rm -f "$tmp_remote" 2>/dev/null || true

  # try fetch remote
  if ping -c1 -W2 8.8.8.8 &>/dev/null && command -v curl >/dev/null 2>&1; then
    if curl -fsS --connect-timeout 5 "$REPO_RAW/$PRINTERS_LIST" -o "$tmp_remote" 2>/dev/null; then
      if [ -s "$tmp_remote" ]; then
        _info "Fetched remote printers.list"
        # if there is an existing installed local file, preserve its local-only lines
        if [ -f "$INSTALL_DIR/$PRINTERS_LIST" ]; then
          # create merged: start with remote content (remote authoritative)
          tmp_merged=$(mktemp "$TMP_PREFIX.merged.XXXX")
          awk 'NF && $0 !~ /^#/ {print $0}' "$tmp_remote" > "$tmp_merged"
          # append any lines from existing installed file that are NOT present in remote (local-only)
          awk 'NF && $0 !~ /^#/ {print $0}' "$INSTALL_DIR/$PRINTERS_LIST" | while IFS= read -r line; do
            if ! grep -Fxq "$line" "$tmp_merged"; then
              echo "$line" >> "$tmp_merged"
            fi
          done
          # move merged to installed file (atomic)
          $SUDO_CMD mv -f "$tmp_merged" "$INSTALL_DIR/$PRINTERS_LIST"
          DB_FILE="$INSTALL_DIR/$PRINTERS_LIST"
          _info "Updated $INSTALL_DIR/$PRINTERS_LIST from remote (remote wins; local extras preserved)"
        else
          # no installed file -> copy remote to install dir
          $SUDO_CMD cp -f "$tmp_remote" "$INSTALL_DIR/$PRINTERS_LIST"
          DB_FILE="$INSTALL_DIR/$PRINTERS_LIST"
          _info "Copied remote printers.list to $INSTALL_DIR"
        fi
        rm -f "$tmp_remote" 2>/dev/null || true
        return 0
      fi
    fi
  fi

  # if remote not available, prefer local next to script then installed
  if [ -f "$SCRIPT_DIR/$PRINTERS_LIST" ] && [ -s "$SCRIPT_DIR/$PRINTERS_LIST" ]; then
    DB_FILE="$SCRIPT_DIR/$PRINTERS_LIST"
    _info "Using local printers.list next to script"
    return 0
  fi
  if [ -f "$INSTALL_DIR/$PRINTERS_LIST" ] && [ -s "$INSTALL_DIR/$PRINTERS_LIST" ]; then
    DB_FILE="$INSTALL_DIR/$PRINTERS_LIST"
    _info "Using installed printers.list"
    return 0
  fi

  tmpdb=$(mktemp "$TMP_PREFIX.sample.XXXX")
  cat > "$tmpdb" <<'EOF'
# Sample printers.list
# Format: Branch|Label|Address|Type|Driver(optional)
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
EOF
  DB_FILE="$tmpdb"
  _info "Using sample printers DB"
  return 0
}

# rest of script remains the same: normalize_db, normalize_legacy, validate_network, find_driver, deploy_network_printer, run_test_and_open_cups, branch_list_ui, search_branch_and_deploy, smart_fix, clean_spooler, view_status, self_update etc.
# (For brevity I keep the rest unchanged from previous 11.7 implementation. They will work with the new fetch_and_merge_db logic.)
# Ensure you keep the rest of the code identical to the previous 11.7 body (deploy_network_printer, test page, UI), or copy the full content as in prior 11.7 release.

# -----------------------
# Quick init sequence (call the functions)
# -----------------------
self_install "$@"
ensure_single_desktop
background_update_check "$@"
fetch_and_merge_db
normalize_db
normalize_legacy

# main UI loop (unchanged)
# ... (unchanged: as provided in version 11.7)
