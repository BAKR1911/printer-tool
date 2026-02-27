#!/bin/bash
# ===============================================================
# IT Aman - Final Enterprise v10.0
# Merge: Mahmoud Rabia core + Advanced features
# ===============================================================
CURRENT_VERSION="10.0"
OFFICIAL_NAME="IT Aman - Enterprise Printer System (Final)"
USER_GH="BAKR1911"
REPO_GH="printer-tool"
BRANCH_GH="main"

# Raw URLs (no tokens)
URL_VER="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/version.txt"
URL_CODE="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.sh"
URL_LIST="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.list"

LOG_FILE="/var/log/it-aman.log"
LOCAL_DB="/etc/it-aman/printers.list"   # fallback editable local db
TMP_DB="/tmp/.printer_db"

# -------------------------
# Root check
# -------------------------
if [ "$EUID" -ne 0 ]; then
    zenity --error --text "يرجى تشغيل الأداة بصلاحية المدير (sudo)." 2>/dev/null
    exit 1
fi

# -------------------------
# ensure log file
# -------------------------
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

log_event() {
    echo "$(date +'%F %T') - $1" >> "$LOG_FILE"
}

# -------------------------
# Auto update (silent, safe)
# -------------------------
auto_sync_system() {
    # only attempt if we have network
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        REMOTE_V=$(curl -fsS --connect-timeout 5 "$URL_VER" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
            # download new script atomically
            tmpf=$(mktemp)
            if curl -fsS --connect-timeout 5 "$URL_CODE" -o "$tmpf" 2>/dev/null; then
                chmod +x "$tmpf"
                mv "$tmpf" /usr/local/bin/it-aman
                log_event "Auto-updated to version $REMOTE_V"
                exec /usr/local/bin/it-aman
            else
                rm -f "$tmpf"
                log_event "Auto-update failed to download new code"
            fi
        fi
    fi
}

# -------------------------
# Fetch central DB with fallback
# -------------------------
fetch_db() {
    rm -f "$TMP_DB"
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        curl -fsS --connect-timeout 5 "$URL_LIST" -o "$TMP_DB" 2>/dev/null
        if [ -s "$TMP_DB" ]; then
            DB_FILE="$TMP_DB"
            log_event "Fetched central DB"
            return
        fi
    fi
    # fallback to local
    if [ -f "$LOCAL_DB" ] && [ -s "$LOCAL_DB" ]; then
        DB_FILE="$LOCAL_DB"
        log_event "Using local DB fallback: $LOCAL_DB"
        return
    fi
    # if no DB, create sample
    cat <<EOF > /tmp/.printer_db_sample
# Sample printers.list
# Format (final): Branch|PrinterLabel|Address|Type|Driver(optional)
# Type: network | usb | serial
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Aswan|Manager HP M404|192.168.10.21|network|hp-ppd
Aswan|POS Thermal 1|/dev/ttyUSB0|serial|tm-raw
Aswan|POS Thermal 2|USB_POS_01|usb|tm-raw
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
    DB_FILE="/tmp/.printer_db_sample"
    log_event "No DB found; created sample DB"
}

# -------------------------
# Helper: normalize whitespace and remove comments
# -------------------------
normalize_db() {
    # produce a clean temp db without blank lines or leading # comments
    awk -F'|' '{
        # skip empty and comment lines
        if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
        # trim fields
        for(i=1;i<=NF;i++){
            gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)
        }
        print $0
    }' "$DB_FILE" > /tmp/.printer_db_clean
    DB_FILE="/tmp/.printer_db_clean"
}

# -------------------------
# Network/Port validation
# -------------------------
validate_printer_connection() {
    # arg1 = address (ip or hostname), returns:
    # 0 = ok (ping and port open for network)
    # 1 = ping failed
    # 2 = ping ok but port closed (9100)
    TARGET="$1"

    # if TARGET looks like an IP or hostname use ping+nc
    if [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        if ! ping -c 1 -W 2 "$TARGET" &>/dev/null; then
            return 1
        fi
        # check port 9100
        if command -v nc &>/dev/null; then
            if nc -z -w2 "$TARGET" 9100 &>/dev/null; then
                return 0
            else
                return 2
            fi
        else
            # no nc: assume reachable if ping ok
            return 0
        fi
    else
        # hostname: try ping
        if ! ping -c 1 -W 2 "$TARGET" &>/dev/null; then
            return 1
        fi
        if command -v nc &>/dev/null; then
            if nc -z -w2 "$TARGET" 9100 &>/dev/null; then
                return 0
            else
                return 2
            fi
        else
            return 0
        fi
    fi
}

# -------------------------
# Deploy logic (advanced)
# -------------------------
deploy_printer_advanced() {
    # search input
    SEARCH=$(zenity --entry --title "بحث عن فرع / طابعة" --text "اكتب اسم الفرع أو اسم الطابعة للبحث:" 2>/dev/null)
    [ -z "$SEARCH" ] && return

    # start-with matches first (case-insensitive)
    STARTS=$(grep -i -E "^[[:space:]]*$SEARCH" "$DB_FILE" | sed 's/^[[:space:]]*//')
    # then contains matches excluding starts-with
    CONTAINS=$(grep -i "$SEARCH" "$DB_FILE" | grep -vi -F "$SEARCH" | sed 's/^[[:space:]]*//')

    LIST=""
    if [ -n "$STARTS" ]; then
        while IFS= read -r line; do
            # fields: Branch|Label|Address|Type|Driver?
            branch=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
            label=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
            typ=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
            LIST+="${branch} | ${label} (${typ})"$'\n'
        done <<< "$STARTS"
    fi
    if [ -n "$CONTAINS" ]; then
        while IFS= read -r line; do
            branch=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
            label=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
            typ=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
            LIST+="${branch} | ${label} (${typ})"$'\n'
        done <<< "$CONTAINS"
    fi

    # present list to user (first match first)
    SELECTED=$(echo -n "$LIST" | sed '/^[[:space:]]*$/d' | zenity --list --title "النتائج" \
        --text "اختر الطابعة المطلوبة:" --column "Branch | Printer (type)" --width=650 --height=400 2>/dev/null)

    [ -z "$SELECTED" ] && return

    # parse selected: "Branch | Label (type)" -> get Branch and Label
    BRANCH=$(echo "$SELECTED" | awk -F'|' '{print $1}' | xargs)
    # label part includes " label (type)" -> remove trailing " (type)"
    LABEL_WITH_TYPE=$(echo "$SELECTED" | awk -F'|' '{print $2}' | xargs)
    # strip trailing " (xxx)"
    PR_LABEL=$(echo "$LABEL_WITH_TYPE" | sed 's/ *([[:alnum:]_ -]\+)$//; s/ *([^)]\+)$//')

    # find exact DB record (match branch and label, case-insensitive)
    RECORD=$(awk -F'|' -v b="$BRANCH" -v l="$PR_LABEL" 'BEGIN{IGNORECASE=1} 
        {
            if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit}
        }' "$DB_FILE")

    if [ -z "$RECORD" ]; then
        zenity --error --text "لا يمكن العثور على السجل الكامل للطابعة المختارة." 2>/dev/null
        log_event "Record not found for selection: $SELECTED"
        return
    fi

    ADDR=$(echo "$RECORD" | awk -F'|' '{print $3}' | xargs)
    TYPE=$(echo "$RECORD" | awk -F'|' '{print $4}' | xargs)
    DRIVER=$(echo "$RECORD" | awk -F'|' '{print $5}' | xargs)

    # create safe printer name
    PR_NAME="ITA_${BRANCH// /_}_${PR_LABEL// /_}"
    PR_NAME=$(echo "$PR_NAME" | tr -s '_')

    # prevent redefinition
    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
        zenity --info --text "الطابعة معرفة بالفعل على هذا الجهاز." 2>/dev/null
        log_event "Skipped deploy - already exists: $PR_NAME"
        return
    fi

    # handle types
    if [[ "$TYPE" == "usb" ]]; then
        # Address could be USB id or logical name; attempt usb uri or device path
        # give user helpful message
        zenity --info --text "جاري تعريف طابعة USB..." 2>/dev/null
        # allow device path or USB token; if address looks like /dev use file: URI
        if [[ "$ADDR" =~ ^/dev/ ]]; then
            LP_URI="file:$ADDR"
        else
            LP_URI="usb://$ADDR"
        fi
        # use raw driver by default for POS thermal
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER:-raw}" 2>/dev/null
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER:-raw}" 2>/dev/null || true
        lpdefault -d "$PR_NAME" 2>/dev/null || true

        if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
            zenity --info --text "تم تعريف طابعة USB: $PR_LABEL" 2>/dev/null
            log_event "USB printer deployed: $PR_NAME (URI: $LP_URI)"
        else
            zenity --error --text "فشل تعريف طابعة USB. تأكد من توصيل الكابل وصلاحيات الجهاز." 2>/dev/null
            log_event "USB deploy failed: $PR_NAME (URI: $LP_URI)"
        fi
        return
    fi

    if [[ "$TYPE" == "serial" ]]; then
        zenity --info --text "جاري تعريف طابعة Serial..." 2>/dev/null
        # ADDRESS expected like /dev/ttyUSB0 or /dev/ttyS0
        if [[ "$ADDR" =~ ^/dev/ ]]; then
            LP_URI="file:$ADDR"
        else
            LP_URI="file:$ADDR"
        fi
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER:-raw}" 2>/dev/null || true
        lpdefault -d "$PR_NAME" 2>/dev/null || true

        if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
            zenity --info --text "تم تعريف الطابعة التسلسلية: $PR_LABEL" 2>/dev/null
            log_event "Serial printer deployed: $PR_NAME (URI: $LP_URI)"
        else
            zenity --error --text "فشل تعريف الطابعة التسلسلية. تأكد من توصيل الكابل وصلاحيات الجهاز." 2>/dev/null
            log_event "Serial deploy failed: $PR_NAME (URI: $LP_URI)"
        fi
        return
    fi

    # else network
    validate_printer_connection "$ADDR"
    RES=$?
    if [ $RES -eq 1 ]; then
        zenity --error --text "تعذر الوصول للطابعة (Ping فشل). برجاء التحقق من الكابل/الشبكة." 2>/dev/null
        log_event "Ping failed - $PR_NAME ($ADDR)"
        return
    elif [ $RES -eq 2 ]; then
        zenity --warning --text "الطابعة ترد على الشبكة لكن منفذ الطباعة (9100) مغلق. قد لا تعمل الطباعة." 2>/dev/null
        log_event "Port 9100 closed - $PR_NAME ($ADDR)"
        # we can still try to register but warn
    fi

    # create printer via socket
    LP_URI="socket://$ADDR"
    if [ -n "$DRIVER" ]; then
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "$DRIVER" 2>/dev/null || true
    else
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null || true
    fi
    lpdefault -d "$PR_NAME" 2>/dev/null || true

    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
        zenity --info --text "تم تعريف الطابعة (Network) بنجاح: $PR_LABEL" 2>/dev/null
        log_event "Network printer deployed: $PR_NAME (URI: $LP_URI)"
    else
        zenity --error --text "فشل تعريف الطابعة الشبكية." 2>/dev/null
        log_event "Network deploy failed: $PR_NAME (URI: $LP_URI)"
    fi
}

# -------------------------
# Legacy support: accept old simple format Branch|IP|Model
# convert on-the-fly to Branch|Model|IP|network
# -------------------------
normalize_legacy() {
    awk -F'|' '{
        # skip comments/blank
        if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
        if (NF==3) {
            branch=$1; addr=$2; model=$3;
            gsub(/^[ \t]+|[ \t]+$/,"",branch);
            gsub(/^[ \t]+|[ \t]+$/,"",addr);
            gsub(/^[ \t]+|[ \t]+$/,"",model);
            print branch "|" model "|" addr "|network"
        } else {
            print $0
        }
    }' "$DB_FILE" > /tmp/.printer_db_norm
    DB_FILE="/tmp/.printer_db_norm"
}

# -------------------------
# Smart fix / core engine (Mahmoud Rabia)
# -------------------------
smart_fix_engine() {
    DIAG_LOG=$(mktemp)
    (
    echo "10"
    if ! systemctl is-active --quiet cups; then
        systemctl restart cups; echo "- restarted CUPS" >> "$DIAG_LOG"
    fi
    echo "40"
    if [ -n "$(lpstat -o 2>/dev/null)" ]; then
        cancel -a 2>/dev/null; echo "- cleared stuck jobs" >> "$DIAG_LOG"
    fi
    echo "70"
    DISABLED=$(lpstat -p 2>/dev/null | grep "disabled" | awk '{print $2}')
    if [ -n "$DISABLED" ]; then
        for p in $DISABLED; do
            cupsenable "$p"; cupsaccept "$p"
        done
        echo "- re-enabled printers" >> "$DIAG_LOG"
    fi
    echo "100"
    ) | zenity --progress --title "$OFFICIAL_NAME - Smart Fix" --text "Running diagnostics..." --auto-close 2>/dev/null

    if [ -s "$DIAG_LOG" ]; then
        zenity --info --title "تقرير الإصلاح" --text "$(cat $DIAG_LOG)" --width=450 2>/dev/null
    else
        zenity --info --title "تقرير الإصلاح" --text "النظام يعمل بشكل جيد، لم يتم العثور على أخطاء برمجية." --width=450 2>/dev/null
    fi
    rm -f "$DIAG_LOG"
    log_event "Smart fix executed"
}

# -------------------------
# Spooler clean
# -------------------------
clean_spooler() {
    (echo "50"; systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; echo "100") | zenity --progress --text "Cleaning spooler..." --auto-close 2>/dev/null
    zenity --info --text "تم مسح أوامر الطباعة المعلقة." 2>/dev/null
    log_event "Spooler cleaned"
}

# -------------------------
# Status view
# -------------------------
status_view() {
    STATUS=$(lpstat -p 2>/dev/null)
    JOBS=$(lpstat -o 2>/dev/null)
    zenity --info --title "حالة الطابعات" --text "<b>الحالة العامة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null
}

# -------------------------
# Init: fetch and normalize DB
# -------------------------
auto_sync_system
fetch_db
normalize_db
normalize_legacy

# -------------------------
# Main loop (UI)
# -------------------------
while true; do
    auto_sync_system

    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" \
        --radiolist --column "اختر" --column "ID" --column "الخدمة" \
        FALSE "1" "➕ تعريف طابعة (بحث ذكي)" \
        FALSE "2" "🛠️ الإصلاح الذكي (Mahmoud Rabia Core)" \
        FALSE "3" "🧹 تنظيف الذاكرة (Spooler Clean)" \
        FALSE "4" "📊 عرض الحالة" \
        FALSE "5" "📂 افتح ملف قاعدة البيانات (للمسؤول)" \
        FALSE "6" "🚪 خروج" \
        --width=700 --height=450 2>/dev/null)

    [ -z "$CHOICE" ] && exit 0
    if [ "$CHOICE" == "6" ]; then exit 0; fi

    case "$CHOICE" in
        1) deploy_printer_advanced ;;
        2) smart_fix_engine ;;
        3) clean_spooler ;;
        4) status_view ;;
        5) 
            # open the active DB file for admin (local or tmp)
            sudo -u "$SUDO_USER" xdg-open "$DB_FILE" 2>/dev/null || zenity --info --text "فتح الملف: $DB_FILE" 2>/dev/null
            ;;
    esac
done
