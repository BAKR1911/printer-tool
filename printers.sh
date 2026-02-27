#!/bin/bash
# ===============================================================
# IT Aman Enterprise Core v9.0
# Clean Architecture - Full Merge
# Mahmoud Rabia Edition
# ===============================================================

CURRENT_VERSION="9.0"
OFFICIAL_NAME="IT Aman - Enterprise Printer System"

USER_GH="BAKR1911"
REPO_GH="printer-tool"
BRANCH_GH="main"

URL_VER="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/version.txt"
URL_CODE="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.sh"
URL_LIST="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.list"

LOG_FILE="/var/log/it-aman.log"

# =============================
# Root Check
# =============================
if [ "$EUID" -ne 0 ]; then
    zenity --error --text "يرجى تشغيل الأداة بصلاحية sudo" 2>/dev/null
    exit 1
fi

# =============================
# Logging
# =============================
log_event() {
    echo "$(date) - $1" >> "$LOG_FILE"
}

# =============================
# Silent Auto Update
# =============================
auto_sync_system() {
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        REMOTE_V=$(curl -sL "$URL_VER" | tr -d '[:space:]')
        if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
            curl -sL "$URL_CODE" -o /usr/local/bin/it-aman
            chmod +x /usr/local/bin/it-aman
            exec /usr/local/bin/it-aman
        fi
    fi
}

# =============================
# Fetch Central DB
# =============================
fetch_db() {
    rm -f /tmp/.printer_db
    curl -sL "$URL_LIST" -o /tmp/.printer_db
    DB_FILE="/tmp/.printer_db"
}

# =============================
# Network Validation Layer
# =============================
validate_printer_connection() {
    TARGET="$1"

    ping -c 1 -W 2 "$TARGET" >/dev/null 2>&1 || return 1
    nc -z -w2 "$TARGET" 9100 >/dev/null 2>&1 || return 2

    return 0
}

# =============================
# Mahmoud Rabia Core Engine
# =============================
smart_fix() {
    systemctl restart cups
    cancel -a 2>/dev/null
    for p in $(lpstat -p | grep "disabled" | awk '{print $2}'); do
        cupsenable "$p"
        cupsaccept "$p"
    done
    log_event "Smart Fix executed"
}

clean_spooler() {
    systemctl stop cups
    rm -rf /var/spool/cups/*
    systemctl start cups
    log_event "Spooler cleaned"
}

status_report() {
    lpstat -p
    lpstat -o
}

# =============================
# Deploy Printer By Branch
# =============================
deploy_printer() {

    BRANCH_LIST=$(cut -d'|' -f1 "$DB_FILE")

    SELECTED=$(echo "$BRANCH_LIST" | zenity --list \
        --title "تعريف طابعة" \
        --text "اختر الفرع:" \
        --column "اسم الفرع" \
        --width=400 --height=400 2>/dev/null)

    [ -z "$SELECTED" ] && return

    RECORD=$(grep "^$SELECTED|" "$DB_FILE")
    IP=$(echo "$RECORD" | cut -d'|' -f2 | xargs)

    PR_NAME="Printer_${SELECTED// /_}"

    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
        zenity --info --text "الطابعة معرفة بالفعل." 2>/dev/null
        return
    fi

    validate_printer_connection "$IP"
    RESULT=$?

    if [ $RESULT -eq 1 ]; then
        zenity --error --text "لا يمكن الوصول للطابعة.
تأكد من:
- توصيل كابل الشبكة
- تشغيل الطابعة" 2>/dev/null
        log_event "Ping failed for $SELECTED"
        return
    fi

    if [ $RESULT -eq 2 ]; then
        zenity --error --text "الطابعة متصلة لكن منفذ الطباعة مغلق (9100).
راجع إعدادات الشبكة." 2>/dev/null
        log_event "Port 9100 closed for $SELECTED"
        return
    fi

    systemctl restart cups

    lpadmin -p "$PR_NAME" -E -v "socket://$IP" -m everywhere
    lpdefault -d "$PR_NAME"

    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
        zenity --info --text "تم تعريف طابعة $SELECTED بنجاح." 2>/dev/null
        log_event "Printer $SELECTED deployed successfully"
    else
        zenity --error --text "حدث خطأ أثناء التعريف." 2>/dev/null
        log_event "Deployment failed for $SELECTED"
    fi
}

# =============================
# Init
# =============================
auto_sync_system
fetch_db

# =============================
# Main UI
# =============================
while true; do

    auto_sync_system

    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" \
    --radiolist --column "اختر" --column "ID" --column "الخدمة" \
    FALSE "1" "➕ تعريف طابعة حسب الفرع" \
    FALSE "2" "🛠️ الإصلاح الذكي" \
    FALSE "3" "🧹 تنظيف الذاكرة" \
    FALSE "4" "📊 تقرير الحالة" \
    FALSE "5" "🚪 خروج" \
    --width=500 --height=400 2>/dev/null)

    [ -z "$CHOICE" ] || [ "$CHOICE" == "5" ] && exit 0

    case "$CHOICE" in
        1) deploy_printer ;;
        2) smart_fix; zenity --info --text "تم تنفيذ الإصلاح الذكي." 2>/dev/null ;;
        3) clean_spooler; zenity --info --text "تم تنظيف الذاكرة." 2>/dev/null ;;
        4) zenity --info --text "$(status_report)" --width=550 2>/dev/null ;;
    esac

done
