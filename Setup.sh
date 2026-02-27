#!/bin/bash
# ===============================================================
# Setup.sh - Installer for printer-tool
# - installs to /opt/printer-tool
# - creates symlink /usr/local/bin/printer-tool
# - creates desktop shortcut for the real interactive user
# - creates sudoers entry so the desktop icon can run the tool WITHOUT password
# ===============================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./Setup.sh"
  exit 1
fi

REPO_RAW="https://raw.githubusercontent.com/BAKR1911/printer-tool/main"
INSTALL_DIR="/opt/printer-tool"
BIN="/usr/local/bin/printer-tool"
DESKTOP_NAME="printer-tool.desktop"

# determine real interactive user (the one who invoked sudo)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "/home/$REAL_USER")"
DESKTOP_DIR="$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP 2>/dev/null || echo "$USER_HOME/Desktop")"
mkdir -p "$DESKTOP_DIR" 2>/dev/null || true

echo "[1/6] Creating install dir $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"

echo "[2/6] Downloading printers.sh and printers.list (or use local files if present)..."
# prefer local files if present in current folder
if [ -f "./printers.sh" ]; then
  cp -f ./printers.sh "$INSTALL_DIR/printers.sh"
else
  curl -fsSL "$REPO_RAW/printers.sh" -o "$INSTALL_DIR/printers.sh"
fi

if [ -f "./printers.list" ]; then
  cp -f ./printers.list "$INSTALL_DIR/printers.list"
else
  # try fetch remote printers.list (optional)
  if curl -fsS --connect-timeout 5 "$REPO_RAW/printers.list" -o "$INSTALL_DIR/printers.list" 2>/dev/null; then
    echo "  - remote printers.list fetched"
  else
    # leave empty file for admin to fill
    : > "$INSTALL_DIR/printers.list"
    echo "  - no printers.list available, created empty $INSTALL_DIR/printers.list"
  fi
fi

chmod +x "$INSTALL_DIR/printers.sh"

echo "[3/6] Creating symlink $BIN -> $INSTALL_DIR/printers.sh"
ln -sf "$INSTALL_DIR/printers.sh" "$BIN"
chmod +x "$BIN"

echo "[4/6] Creating sudoers entry to allow $REAL_USER run $BIN without password"
SUDOERS_FILE="/etc/sudoers.d/printer-tool-$REAL_USER"
cat > "$SUDOERS_FILE" <<EOF
# Allow the interactive user to run printer-tool without password
$REAL_USER ALL=(ALL) NOPASSWD: $BIN
EOF
chmod 0440 "$SUDOERS_FILE"

echo "[5/6] Creating desktop shortcut for $REAL_USER (no password at launch)"
DESKTOP_PATH="$DESKTOP_DIR/$DESKTOP_NAME"
cat > /tmp/$DESKTOP_NAME.$$ <<EOF
[Desktop Entry]
Name=Printer Tool
Comment=IT Aman - Printer Tool
Exec=sudo $BIN
Icon=printer
Terminal=false
Type=Application
Categories=Utility;
EOF

mv -f /tmp/$DESKTOP_NAME.$$ "$DESKTOP_PATH"
chown "$REAL_USER:$REAL_USER" "$DESKTOP_PATH" 2>/dev/null || true
chmod +x "$DESKTOP_PATH"
# try mark trusted (GNOME)
sudo -u "$REAL_USER" gio set "$DESKTOP_PATH" "metadata::trusted" true 2>/dev/null || true

echo "[6/6] Done. Installed at: $INSTALL_DIR"
echo "You can run the tool from Applications menu or by double-clicking the desktop icon."
