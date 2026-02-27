#!/bin/bash

set -e

APP_NAME="printer-tool"
INSTALL_DIR="/opt/$APP_NAME"
DESKTOP_FILE_NAME="printer-tool.desktop"

# ---------- Detect real user ----------
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$(whoami)"
fi

USER_HOME=$(eval echo "~$REAL_USER")

# ---------- Detect Desktop ----------
detect_desktop() {
    if [ -d "$USER_HOME/Desktop" ]; then
        echo "$USER_HOME/Desktop"
    elif [ -d "$USER_HOME/سطح المكتب" ]; then
        echo "$USER_HOME/سطح المكتب"
    else
        echo "$USER_HOME/Desktop"
    fi
}

DESKTOP_DIR=$(detect_desktop)

# ---------- Get real script path ----------
SCRIPT_PATH="$(readlink -f "$0")"

# ---------- Self install to /opt ----------
install_self() {

    if [ "$SCRIPT_PATH" != "$INSTALL_DIR/printers.sh" ]; then
        echo "Installing to $INSTALL_DIR ..."
        sudo mkdir -p "$INSTALL_DIR"
        sudo cp "$SCRIPT_PATH" "$INSTALL_DIR/printers.sh"
        sudo chmod +x "$INSTALL_DIR/printers.sh"

        # restart from installed location
        exec sudo "$INSTALL_DIR/printers.sh"
        exit 0
    fi
}

# ---------- Create ONE desktop shortcut ----------
create_shortcut() {

    sudo rm -f "$DESKTOP_DIR/IT-Aman.desktop" 2>/dev/null || true
    sudo rm -f "$DESKTOP_DIR/Printer-Tool.desktop" 2>/dev/null || true
    sudo rm -f "$DESKTOP_DIR/$DESKTOP_FILE_NAME" 2>/dev/null || true

    cat <<EOF | sudo tee "$DESKTOP_DIR/$DESKTOP_FILE_NAME" >/dev/null
[Desktop Entry]
Name=Printer Tool
Comment=IT Printer Deployment Tool
Exec=sudo $INSTALL_DIR/printers.sh
Icon=printer
Terminal=true
Type=Application
Categories=Utility;
EOF

    sudo chown $REAL_USER:$REAL_USER "$DESKTOP_DIR/$DESKTOP_FILE_NAME"
    sudo chmod +x "$DESKTOP_DIR/$DESKTOP_FILE_NAME"

    sudo -u $REAL_USER gio set "$DESKTOP_DIR/$DESKTOP_FILE_NAME" metadata::trusted true 2>/dev/null || true

    echo "Desktop shortcut created."
}

# ---------- Check CUPS ----------
check_cups() {
    if ! systemctl is-active --quiet cups; then
        echo "Starting CUPS..."
        sudo systemctl start cups
    fi
}

# ---------- Deploy Printer ----------
deploy_printer() {

    BRANCH="$1"
    NAME="$2"
    IP="$3"

    PRINTER_NAME="ITA_${BRANCH}_${NAME}"
    PRINTER_NAME=$(echo "$PRINTER_NAME" | tr ' ' '_' | tr -s '_')

    if sudo lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
        echo "Printer already exists: $PRINTER_NAME"
        return
    fi

    if ! ping -c1 -W2 "$IP" >/dev/null 2>&1; then
        echo "Cannot reach printer IP: $IP"
        return
    fi

    echo "Adding printer $PRINTER_NAME ..."

    sudo lpadmin -p "$PRINTER_NAME" -E -v socket://$IP:9100 -m everywhere

    sudo lpoptions -d "$PRINTER_NAME"

    echo "Test Page from IT Tool - $(date)" | sudo lp -d "$PRINTER_NAME"

    xdg-open "http://localhost:631/printers/$PRINTER_NAME" >/dev/null 2>&1 || true

    echo "Printer installed successfully."
}

# ---------- MENU ----------
menu() {

    clear
    echo "=============================="
    echo "       IT Printer Tool        "
    echo "=============================="
    echo "1) Install Branch A Printer"
    echo "2) Install Branch B Printer"
    echo "3) Exit"
    echo "=============================="

    read -p "Select option: " opt

    case $opt in
        1)
            deploy_printer "BranchA" "MainPrinter" "192.168.1.100"
            ;;
        2)
            deploy_printer "BranchB" "MainPrinter" "192.168.1.101"
            ;;
        3)
            exit 0
            ;;
        *)
            echo "Invalid option"
            ;;
    esac

    read -p "Press Enter to continue..."
    menu
}

# ---------- MAIN ----------
install_self
check_cups
create_shortcut
menu
