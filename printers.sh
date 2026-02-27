#!/bin/bash
# ===============================================================
# Script: printers.sh (Final Stable Version 12)
# Identity: Help Desk Operations Support
# Supports format: Branch|PrinterName|IP|
# ===============================================================

set -e

OFFICIAL_NAME="Help Desk Operations Support"
SYS_ICON="printer"
VERSION="12.0"

# --- Locate printers.list safely ---
if [ -f "/usr/local/bin/printers.list" ]; then
    DB_FILE="/usr/local/bin/printers.list"
elif [ -f "$HOME/Downloads/IT-Tool/printers.list" ]; then
    DB_FILE="$HOME/Downloads/IT-Tool/printers.list"
elif [ -f "./printers.list" ]; then
    DB_FILE="./printers.list"
else
    zenity --error --title "$OFFICIAL_NAME" \
    --text "⚠️ خطأ: ملف printers.list غير موجود!" \
    --width=400
    exit 1
fi

# --- Check network connection ---
check_connection() {
    local ip=$1
    if ! ping -c 1 -W 2 "$ip" &>/dev/null; then
        zenity --warning --title "تنبيه اتصال" \
        --text "⚠️ الطابعة ($ip) غير متصلة بالشبكة.\nتأكد من كابل LAN." \
        --width=400
        return 1
    fi
    return 0
}

# --- Install Printer ---
install_printer() {

    PRINTER_LIST=$(grep -v '^#' "$DB_FILE" | awk -F'|' '{print $1" | "$2" | "$3}')

    SELECTED=$(echo "$PRINTER_LIST" | zenity --list \
        --title "$OFFICIAL_NAME - Version $VERSION" \
        --text "اختر الطابعة المراد تعريفها:" \
        --column "Branch" \
        --column "Printer Name" \
        --column "IP Address" \
        --width=700 --height=450)

    if [ -z "$SELECTED" ]; then
        return
    fi

    BRANCH=$(echo "$SELECTED" | awk -F'|' '{print $1}' | xargs)
    PR_NAME=$(echo "$SELECTED" | awk -F'|' '{print $2}' | xargs)
    PR_IP=$(echo "$SELECTED" | awk -F'|' '{print $3}' | xargs)

    if ! check_connection "$PR_IP"; then
        return
    fi

    if lpstat -p | grep -q "^printer $PR_NAME "; then
        zenity --info --text "الطابعة $PR_NAME معرفة مسبقاً ✅"
        return
    fi

    (
    echo "30"
    sudo lpadmin -x "$PR_NAME" 2>/dev/null || true
    echo "60"
    sudo lpadmin -p "$PR_NAME" -E \
        -v "socket://$PR_IP" \
        -m everywhere \
        -L "$BRANCH"
    echo "100"
    ) | zenity --progress \
        --title "جاري التعريف..." \
        --percentage=0 --auto-close

    if lpstat -p | grep -q "^printer $PR_NAME "; then
        zenity --info --text "تم تعريف طابعة ($PR_NAME) بنجاح ✅"
    else
        zenity --error --text "فشل تعريف الطابعة ❌"
    fi
}

# --- Smart Repair ---
smart_repair() {
    DEF_PRINTER=$(lpstat -d 2>/dev/null | cut -d: -f2 | xargs)
    if [ -n "$DEF_PRINTER" ]; then
        sudo systemctl restart cups
        cupsenable "$DEF_PRINTER"
        cupsaccept "$DEF_PRINTER"
        zenity --info --text "تمت إعادة تنشيط $DEF_PRINTER ✅"
    else
        zenity --error --text "لا توجد طابعة افتراضية!"
    fi
}

# --- Clear Spooler ---
clear_spooler() {
    cancel -a -x 2>/dev/null
    zenity --info --text "تم مسح أوامر الطباعة بنجاح ✅"
}

# --- View Status ---
view_status() {
    STATUS=$(lpstat -p 2>/dev/null)
    if [ -z "$STATUS" ]; then
        STATUS="لا توجد طابعات معرفة."
    fi
    zenity --info --text "$STATUS" --width=500
}

# --- Initial Check ---
if ! lpstat -v &>/dev/null; then
    zenity --info --title "$OFFICIAL_NAME" \
    --text "لا توجد طابعات معرفة.\nسيتم فتح نافذة التعريف الآن."
    install_printer
fi

# --- Main Menu Loop ---
while true; do
    MAIN_CHOICE=$(zenity --list \
        --title "$OFFICIAL_NAME - Version $VERSION" \
        --window-icon="$SYS_ICON" \
        --text "اختر الخدمة المطلوبة:" \
        --column "ID" --column "الخدمة" --hide-column=1 \
        "1" "🛠️ Smart Repair" \
        "2" "🧹 Clear Spooler" \
        "3" "🆕 Install New Printer" \
        "4" "📊 View Status" \
        "5" "🚪 Exit" \
        --width=550 --height=400)

    case "$MAIN_CHOICE" in
        1) smart_repair ;;
        2) clear_spooler ;;
        3) install_printer ;;
        4) view_status ;;
        *) exit 0 ;;
    esac
done
