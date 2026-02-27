#!/bin/bash
# ===============================================================
# IT Aman Ultimate System v7.0
# Merged: Mahmoud Rabia + Central Management
# ===============================================================

CURRENT_VERSION="7.0"
OFFICIAL_NAME="IT Aman - نظام الدعم الفني للطابعات"

USER_GH="BAKR1911"
REPO_GH="printer-tool"
BRANCH_GH="main"

URL_VER="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/version.txt"
URL_CODE="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.sh"
URL_LIST="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.list"

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
fetch_central_db() {
    rm -f /tmp/.printer_db
    curl -sL --connect-timeout 5 "$URL_LIST" -o /tmp/.printer_db
    DB_FILE="/tmp/.printer_db"
}

# =============================
# Root Check
# =============================
if [ "$EUID" -ne 0 ]; then
    zenity --error --text "يرجى تشغيل الأداة بصلاحية المدير (sudo it-aman)" --width=300 2>/dev/null
    exit 1
fi

auto_sync_system
fetch_central_db

# =============================
# Main Menu
# =============================
while true; do

    auto_sync_system

    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" \
    --text "اختر الخدمة المطلوبة:" \
    --radiolist --column "اختر" --column "ID" --column "الخدمة" \
    FALSE "1" "➕ تعريف طابعة بالاسم (بدون إظهار IP)" \
    FALSE "2" "🛠️ الإصلاح الذكي للخدمات" \
    FALSE "3" "🧹 مسح أوامر الطباعة المعلقة" \
    FALSE "4" "📊 عرض حالة الطابعات" \
    FALSE "5" "🚪 خروج" \
    --width=600 --height=450 2>/dev/null)

    [ -z "$CHOICE" ] || [ "$CHOICE" == "5" ] && exit 0

    case "$CHOICE" in

        1)
            BRANCH_NAME=$(zenity --entry \
            --title "تعريف طابعة" \
            --text "اكتب اسم الفرع كما هو مسجل:" 2>/dev/null)

            [ -z "$BRANCH_NAME" ] && continue

            RECORD=$(grep -i "^$BRANCH_NAME|" "$DB_FILE")

            if [ -z "$RECORD" ]; then
                zenity --error --text "الفرع غير موجود في قاعدة البيانات." 2>/dev/null
                continue
            fi

            HOST=$(echo "$RECORD" | cut -d'|' -f2 | xargs)
            MODEL=$(echo "$RECORD" | cut -d'|' -f3 | xargs)

            PR_NAME="Printer_${BRANCH_NAME// /_}"

            (
            echo "20"
            echo "# جاري التحقق من اتصال الطابعة..."

            if ping -c 1 -W 2 "$HOST" >/dev/null; then

                echo "50"
                echo "# تم العثور على الطابعة، جاري التعريف..."

                systemctl restart cups

                lpadmin -p "$PR_NAME" -E -v "socket://$HOST" -m everywhere
                lpdefault -d "$PR_NAME"

                echo "90"

                if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
                    echo "100"
                else
                    exit 1
                fi

            else
                echo "# الطابعة غير متصلة بالشبكة."
                sleep 2
                exit 1
            fi

            ) | zenity --progress --title "جاري التنفيذ" --auto-close --width=400 2>/dev/null

            if [ $? -eq 0 ]; then
                zenity --info --text "تم تعريف طابعة فرع $BRANCH_NAME بنجاح." 2>/dev/null
            else
                zenity --error --text "تعذر الوصول للطابعة.
برجاء التأكد من:
- توصيل كابل الإنترنت بالطابعة
- أن الطابعة تعمل
- أن الشبكة تعمل بشكل صحيح" 2>/dev/null
            fi
            ;;

        2)
            (
            echo "30"; systemctl restart cups
            echo "60"; cancel -a 2>/dev/null
            echo "90"; for p in $(lpstat -p | grep "disabled" | awk '{print $2}'); do cupsenable "$p"; cupsaccept "$p"; done
            echo "100"
            ) | zenity --progress --title "إصلاح ذكي" --auto-close 2>/dev/null

            zenity --info --text "تم إصلاح خدمات الطباعة وتفعيل الطابعات المعطلة." 2>/dev/null
            ;;

        3)
            systemctl stop cups
            rm -rf /var/spool/cups/*
            systemctl start cups
            zenity --info --text "تم مسح أوامر الطباعة المعلقة بنجاح." 2>/dev/null
            ;;

        4)
            zenity --info --title "حالة النظام" \
            --text "$(lpstat -p 2>/dev/null)\n\n$(lpstat -o 2>/dev/null)" \
            --width=550 2>/dev/null
            ;;
    esac
done
