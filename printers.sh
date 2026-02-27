#!/bin/bash
# ===============================================================
#  Script: it_aman_printer_fix.sh
#  Version: 11.0 - Final Merged
#  Purpose: IT Aman - Printer Support (original UI + advanced features)
# ===============================================================
CURRENT_VERSION="11.0"
# Use public raw GitHub URLs (no token stored here)
USER="BAKR1911"
REPO="printer-tool"
BRANCH="main"
VERSION_URL="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/version.txt"
SCRIPT_URL="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.sh"
DB_URL="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.list"

LOG_FILE="/var/log/it-aman.log"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

# -------------------------
# root check
# -------------------------
if [ "$EUID" -ne 0 ]; then
    zenity --error --title "Error" --text "Administrator rights required. Please use sudo." 2>/dev/null
    exit 1
fi

REAL_USER=${SUDO_USER:-$(whoami)}

# -------------------------
# ensure log file
# -------------------------
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 0644 "$LOG_FILE" 2>/dev/null || true
log_event() { echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

# -------------------------
# Auto update (public raw)
# -------------------------
auto_sync_system() {
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        REMOTE_V=$(curl -fsS --connect-timeout 5 "$VERSION_URL" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
            tmpf=$(mktemp)
            if curl -fsS --connect-timeout 5 "$SCRIPT_URL" -o "$tmpf" 2>/dev/null; then
                chmod +x "$tmpf"
                mv "$tmpf" /usr/local/bin/it-aman
                log_event "Auto-updated to version $REMOTE_V"
                exec /usr/local/bin/it-aman
            else
                rm -f "$tmpf" 2>/dev/null || true
                log_event "Auto-update failed to download new code"
            fi
        fi
    fi
}

# -------------------------
# Fetch DB with fallback
# -------------------------
fetch_db() {
    rm -f "$TMP_DB" 2>/dev/null || true
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        curl -fsS --connect-timeout 5 "$DB_URL" -o "$TMP_DB" 2>/dev/null || true
        if [ -s "$TMP_DB" ]; then
            DB_FILE="$TMP_DB"
            log_event "Fetched central DB"
            return
        fi
    fi
    if [ -f "$LOCAL_DB" ] && [ -s "$LOCAL_DB" ]; then
        DB_FILE="$LOCAL_DB"
        log_event "Using local DB fallback: $LOCAL_DB"
        return
    fi
    # sample DB if none found
    cat > /tmp/.printer_db_sample <<'EOF'
# Sample printers.list
# Format: Branch|PrinterLabel|Address|Type|Driver(optional)
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
# Normalize DB: remove comments/blank, trim fields
# -------------------------
normalize_db() {
    awk -F'|' '{
        if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
        for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
        print $0
    }' "$DB_FILE" > /tmp/.printer_db_clean
    DB_FILE="/tmp/.printer_db_clean"
}

# -------------------------
# Legacy support: Branch|IP|Model -> Branch|Model|IP|network
# -------------------------
normalize_legacy() {
    awk -F'|' '{
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
# Validate network printer: ping + port 9100
# returns: 0 ok, 1 ping failed, 2 port closed
# -------------------------
validate_printer_connection() {
    TARGET="$1"
    if ! ping -c 1 -W 2 "$TARGET" &>/dev/null; then
        return 1
    fi
    if command -v nc &>/dev/null; then
        if nc -z -w2 "$TARGET" 9100 &>/dev/null; then
            return 0
        else
            return 2
        fi
    fi
    return 0
}

# -------------------------
# Deploy printer (network / usb / serial)
# -------------------------
deploy_printer_from_record() {
    RECORD="$1"   # Branch|Label|Address|Type|Driver
    BRANCH=$(echo "$RECORD" | awk -F'|' '{print $1}' | xargs)
    LABEL=$(echo "$RECORD" | awk -F'|' '{print $2}' | xargs)
    ADDR=$(echo "$RECORD" | awk -F'|' '{print $3}' | xargs)
    TYPE=$(echo "$RECORD" | awk -F'|' '{print $4}' | xargs)
    DRIVER=$(echo "$RECORD" | awk -F'|' '{print $5}' | xargs)

    PR_NAME="Printer_${BRANCH// /_}_${LABEL// /_}"
    PR_NAME=$(echo "$PR_NAME" | tr -s '_')

    # prevent redefinition
    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
        zenity --info --text "الطابعة معرفة بالفعل على هذا الجهاز." 2>/dev/null
        log_event "Skipped deploy - already exists: $PR_NAME"
        return
    fi

    if [[ "$TYPE" == "usb" ]]; then
        if [[ "$ADDR" =~ ^/dev/ ]]; then
            LP_URI="file:$ADDR"
        else
            LP_URI="usb://$ADDR"
        fi
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER:-raw}" 2>/dev/null || true
        lpdefault -d "$PR_NAME" 2>/dev/null || true
        if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
            zenity --info --text "تم تعريف طابعة USB: $LABEL" 2>/dev/null
            log_event "USB printer deployed: $PR_NAME (URI: $LP_URI)"
        else
            zenity --error --text "فشل تعريف طابعة USB. تحقق من الكابل وصلاحيات الجهاز." 2>/dev/null
            log_event "USB deploy failed: $PR_NAME (URI: $LP_URI)"
        fi
        return
    fi

    if [[ "$TYPE" == "serial" ]]; then
        LP_URI="file:$ADDR"
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER:-raw}" 2>/dev/null || true
        lpdefault -d "$PR_NAME" 2>/dev/null || true
        if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
            zenity --info --text "تم تعريف الطابعة التسلسلية: $LABEL" 2>/dev/null
            log_event "Serial printer deployed: $PR_NAME (URI: $LP_URI)"
        else
            zenity --error --text "فشل تعريف الطابعة التسلسلية." 2>/dev/null
            log_event "Serial deploy failed: $PR_NAME"
        fi
        return
    fi

    # network
    validate_printer_connection "$ADDR"
    RES=$?
    if [ $RES -eq 1 ]; then
        zenity --error --text "تعذر الوصول للطابعة (Ping فشل). تأكد من الكابل/الشبكة." 2>/dev/null
        log_event "Ping failed - $PR_NAME ($ADDR)"
        return
    elif [ $RES -eq 2 ]; then
        zenity --warning --text "الطابعة ترد لكن منفذ 9100 مغلق — قد لا تعمل الطباعة." 2>/dev/null
        log_event "Port 9100 closed - $PR_NAME ($ADDR)"
    fi

    LP_URI="socket://$ADDR"
    if [ -n "$DRIVER" ]; then
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "$DRIVER" 2>/dev/null || true
    else
        lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null || true
    fi
    lpdefault -d "$PR_NAME" 2>/dev/null || true

    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
        zenity --info --text "تم تعريف الطابعة (Network) بنجاح: $LABEL" 2>/dev/null
        log_event "Network printer deployed: $PR_NAME (URI: $LP_URI)"
    else
        zenity --error --text "فشل تعريف الطابعة الشبكية." 2>/dev/null
        log_event "Network deploy failed: $PR_NAME (URI: $LP_URI)"
    fi
}

# -------------------------
# Smart Fix engine (legacy actions)
# -------------------------
smart_fix_engine() {
    DIAG_LOG=$(mktemp)
    (
    echo "10"
    if ! systemctl is-active --quiet cups; then
        systemctl restart cups; echo -e "$REP_C_FX" >> "$DIAG_LOG"
    fi
    echo "40"
    if [ -n "$(lpstat -o 2>/dev/null)" ]; then
        cancel -a 2>/dev/null; echo -e "$REP_J_FX" >> "$DIAG_LOG"
    fi
    echo "70"
    DISABLED_PRINTERS=$(lpstat -p 2>/dev/null | grep "disabled" | awk '{print $2}')
    if [ -n "$DISABLED_PRINTERS" ]; then
        while read -r p; do
            cupsenable "$p"; cupsaccept "$p"
        done <<< "$DISABLED_PRINTERS"
        echo -e "$REP_E_FX" >> "$DIAG_LOG"
    fi
    echo "100"
    ) | zenity --progress --title "$TOOL_NAME" --text "$TXT_WAIT" --auto-close 2>/dev/null

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
    (echo "50"; systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; echo "100") | zenity --progress --text "$TXT_WAIT" --auto-close 2>/dev/null
    zenity --info --text "$TXT_SUCCESS" 2>/dev/null
    log_event "Spooler cleaned"
}

# -------------------------
# Status view
# -------------------------
status_view() {
    STATUS=$(lpstat -p 2>/dev/null)
    JOBS=$(lpstat -o 2>/dev/null)
    zenity --info --text "<b>الحالة العامة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=520 2>/dev/null
}

# -------------------------
# Search & list UI (user asked: search box + filtered list under it)
# Implementation note:
# Zenity doesn't support fully dynamic single-window filtering; we emulate by:
#  - show an entry dialog for search (prefilled)
#  - then show filtered list under it
#  - user can "Search again" to change filter without leaving flow
# -------------------------
search_and_select_printer() {
    local search=""
    while true; do
        # prompt search (pre-filled)
        search=$(zenity --entry --title "بحث عن فرع / طابعة" --text "أدخل اسم الفرع أو اسم الطابعة للفلترة (اكتب جزء من الاسم):" --entry-text "$search" --width=500 2>/dev/null)
        [ -z "$search" ] && return  # cancel or empty -> exit to main menu

        # build filtered list: match branch or label (case-insensitive), starts-with prioritized
        MATCHES=""
        # starts-with
        while IFS= read -r line; do
            branch=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
            label=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
            ADDR=$(echo "$line" | awk -F'|' '{print $3}' | xargs)
            typ=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
            # show only user-visible name (branch | label (type))
            if echo "$branch" | grep -iqE "^$search"; then
                MATCHES+="${branch} | ${label} | ${typ}"$'\n'
                continue
            fi
            if echo "$label" | grep -iqE "^$search"; then
                MATCHES+="${branch} | ${label} | ${typ}"$'\n'
            fi
        done < "$DB_FILE"

        # then contains (non starts-with)
        while IFS= read -r line; do
            branch=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
            label=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
            typ=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
            if echo "${branch}|${label}" | grep -iq "$search"; then
                # avoid duplicates: only add if not already in MATCHES
                if ! echo "$MATCHES" | grep -iqF "${branch} | ${label} | ${typ}"; then
                    MATCHES+="${branch} | ${label} | ${typ}"$'\n'
                fi
            fi
        done < "$DB_FILE"

        if [ -z "$MATCHES" ]; then
            zenity --info --text "لا توجد نتائج مطابقة. حاول كلمة أخرى." --width=380 2>/dev/null
            continue
        fi

        # present list to user
        SELECTED=$(echo -n "$MATCHES" | sed '/^[[:space:]]*$/d' | zenity --list --title "النتائج" --text "نتائج البحث (اختر للطباعة / إدارة):" --column "الBranch|Label|Type" --width=700 --height=420 2>/dev/null)
        # Zenity returns the selected row like: "Aswan | Front Office HP M404 | network"
        if [ -z "$SELECTED" ]; then
            # user closed the list -> ask to search again or exit
            ASK=$(zenity --question --title "متابعة" --text "هل تريد البحث مرة أخرى؟" --ok-label "نعم" --cancel-label "لا" 2>/dev/null; echo $?)
            if [ "$ASK" -ne 0 ]; then
                return
            else
                continue
            fi
        fi

        # parse selection
        SEL_BRANCH=$(echo "$SELECTED" | awk -F'|' '{print $1}' | xargs)
        SEL_LABEL=$(echo "$SELECTED" | awk -F'|' '{print $2}' | xargs)

        # find the exact DB record (match branch + label)
        RECORD=$(awk -F'|' -v b="$SEL_BRANCH" -v l="$SEL_LABEL" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit}}' "$DB_FILE")
        if [ -z "$RECORD" ]; then
            zenity --error --text "لم يتم العثور على السجل الكامل للطابعة." 2>/dev/null
            log_event "Record not found for selection: $SELECTED"
            continue
        fi

        # After selecting printer, offer actions
        ACTION=$(zenity --list --title "خيارات الطابعة" --text "اختر الإجراء المطلوب للطابعة: $SEL_LABEL" --column "ID" --column "Action" \
            1 "Activate & Clear Jobs" 2 "Check Status" 3 "Deploy/Define Printer" 4 "Back to Search" 2>/dev/null)
        if [ -z "$ACTION" ]; then
            continue
        fi

        case "$ACTION" in
            1)
                # attempt to enable & clear jobs by printer name known to CUPS (if present)
                # try to find matching CUPS name by label (best-effort)
                CUPS_NAME=$(lpstat -p 2>/dev/null | awk '{print $2}' | grep -i "$(echo "$SEL_LABEL" | sed 's/ /\\s*/g')" | head -n1)
                if [ -n "$CUPS_NAME" ]; then
                    cancel -a "$CUPS_NAME" 2>/dev/null
                    cupsenable "$CUPS_NAME" 2>/dev/null
                    cupsaccept "$CUPS_NAME" 2>/dev/null
                    zenity --info --text "تم تفعيل الطابعة ومسح الأوامر بنجاح ✅" --width=350 2>/dev/null
                    log_event "Activated & cleared jobs for CUPS name: $CUPS_NAME"
                else
                    # If not known to CUPS, offer to deploy (define) it
                    if zenity --question --text "لم يتم العثور على الطابعة في النظام. هل تريد تعريفها الآن؟" --width=420 2>/dev/null; then
                        deploy_printer_from_record "$RECORD"
                    fi
                fi
                ;;
            2)
                # check status (try CUPS name first)
                CUPS_NAME=$(lpstat -p 2>/dev/null | awk '{print $2}' | grep -i "$(echo "$SEL_LABEL" | sed 's/ /\\s*/g')" | head -n1)
                if [ -n "$CUPS_NAME" ]; then
                    STATUS=$(lpstat -p "$CUPS_NAME" 2>/dev/null)
                    JOBS=$(lpstat -o "$CUPS_NAME" 2>/dev/null)
                    zenity --info --text "<b>الحالة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=520 2>/dev/null
                else
                    zenity --info --text "الطابعة غير معرفة على الجهاز. يمكنك تعريفها من خيار Deploy." --width=420 2>/dev/null
                fi
                ;;
            3)
                deploy_printer_from_record "$RECORD"
                ;;
            4)
                continue
                ;;
        esac

        # after action, ask return to search or exit
        if ! zenity --question --title "متابعة" --text "العودة إلى البحث؟" --ok-label "نعم" --cancel-label "لا" 2>/dev/null; then
            return
        fi
    done
}

# -------------------------
# Main (preserve original UI texts, removed personal name)
# -------------------------
# Prepare UI texts (Arabic + English as in original)
TOOL_NAME="IT Aman - Printer Tool v 11.0"
SYS_ICON="printer-error"

TXT_SELECT_VIDEO="اختار لينك اذا لم يعمل اللينك الاول اختار الثاني :"
TXT_VIDEO_1="Google Drive"
TXT_VIDEO_2="DropBox"
TXT_O1=" معالجة حشر الورق (ارشادات)"
TXT_O2=" فحص النظام الذكي (كشف وحل تلقائي)"
TXT_O3=" اعاده تعريف الطابعه كبيره/حراريه (إصلاح مباشر)"
TXT_O4=" إصلاح أوامر الطباعة (تنظيف الذاكرة العامة)"
TXT_O5=" عرض الحالة العامة للطابعات"
TXT_O6=" خروج"
TXT_WAIT="جاري المعالجة، يرجى الانتظار..."
TXT_SUCCESS="تمت العملية بنجاح ✅"
JAM_TITLE="خطوات إزالة الورق العالق"
JAM_MSG="⚠️ يرجى اتباع التعليمات التالية بدقة:\n\n1. أطفئ الطابعة وافصل كابل الكهرباء فوراً.\n2. افتح الأبواب المخصصة للورق.\n3. اسحب الورق العالق 'بكلتا اليدين' ببطء شديد.\n4. لا تستخدم القوة المفرطة أو أدوات حادة.\n\nاضغط OK للانتقال إلى الفيديو التوضيحي."
REP_HDR="[ تقرير فحص IT Aman ]"
REP_C_FX="- تم إعادة تشغيل خدمة الطباعة (CUPS)."
REP_J_FX="- تم تنظيف مهام الطباعة العالقة."
REP_E_FX="- تم اكتشاف طابعات معطلة وإعادة تنشيطها."
PRINTER_LIST_MSG="اختر الطابعة التي تريد تنشيطها ومسح أوامرها:"
ENABLE_MSG="جاري التنشيط ومسح الذاكرة..."

# Init DB
auto_sync_system
fetch_db
normalize_db
normalize_legacy

# Main loop (preserve original menu look & flow)
while true; do
    CHOICE=$(zenity --list --title "$TOOL_NAME" --window-icon="$SYS_ICON" --text "قائمة الخدمات المتاحة:" \
    --radiolist --column "Select" --column "ID" --column "Option" \
    FALSE "1" "$TXT_O1" FALSE "2" "$TXT_O2" FALSE "3" "$TXT_O3" \
    FALSE "4" "$TXT_O4" FALSE "5" "$TXT_O5" FALSE "6" "$TXT_O6" \
    --width=600 --height=450 2>/dev/null)

    if [ -z "$CHOICE" ] || [ "$CHOICE" == "6" ]; then exit 0; fi

    case "$CHOICE" in
        1)
            zenity --info --title "$JAM_TITLE" --window-icon="$SYS_ICON" --text "$JAM_MSG" --width=500 2>/dev/null
            VIDEO_CHOICE=$(zenity --list --title "$JAM_TITLE" --window-icon="$SYS_ICON" \
                --text "$TXT_SELECT_VIDEO" \
                --column "ID" --column "Video Description" \
                "1" "$TXT_VIDEO_1" \
                "2" "$TXT_VIDEO_2" \
                --width=400 --height=250 2>/dev/null)
            case "$VIDEO_CHOICE" in
                "1") sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null ;;
                "2") sudo -u "$REAL_USER" xdg-open "https://www.dropbox.com/scl/fi/pg75dydlchtpju7j65kr2/Remove-paper-jam-inside-keyocera-UK-TECH-720p-h264.mp4?dl=0" &>/dev/null ;;
            esac
            ;;
        2)
            # run smart fix
            smart_fix_engine
            ;;
        3)
            # open search+list UI (advanced)
            search_and_select_printer
            ;;
        4)
            clean_spooler
            ;;
        5)
            status_view
            ;;
    esac
done
