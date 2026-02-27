#!/bin/bash
# ===============================================================
#  Script: it_aman_printer_fix.sh (Merged Edition 4.0)
#  Combined by: IT Help Desk Opertions
#  Features: Auto-Update, GitHub Sync, CUPS Maintenance, Search
# ===============================================================

# --- [ الإعدادات الأساسية ] ---
CURRENT_VERSION="4.0"
OFFICIAL_NAME="IT Aman - Printer Tool v4.0"
USER="BAKR1911"
REPO="printer-tool"
BRANCH="main"

# روابط GitHub (بدون توكن لسهولة العمل العام، أو أضف التوكن لو المستودع Private)
URL_VER="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/version.txt?v=$(date +%s)"
URL_CODE="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.sh?v=$(date +%s)"
URL_LIST="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.list?v=$(date +%s)"

# --- [ 1. وظيفة التحديث التلقائي - ذكية ومنعشة ] ---
check_for_updates() {
    if ! ping -c 1 -W 2 google.com &>/dev/null; then return; fi
    REMOTE_VERSION=$(curl -sL "$URL_VER" | tr -d '[:space:]')
    
    if [[ -n "$REMOTE_VERSION" && "$REMOTE_VERSION" != "$CURRENT_VERSION" ]]; then
        if zenity --question --title "تحديث متوفر New Update" \
               --text "يوجد إصدار جديد ($REMOTE_VERSION). هل تريد التحديث الآن؟" --width=350 2>/dev/null; then
            
            sudo curl -sL "$URL_CODE" -o /usr/local/bin/it-aman
            sudo chmod +x /usr/local/bin/it-aman
            zenity --info --text "تم التحديث بنجاح! سيتم إعادة تشغيل الأداة." --width=300 2>/dev/null
            pkill -f it-aman
            /usr/local/bin/it-aman &
            exit 0
        fi
    fi
}

# --- [ 2. جلب قائمة الطابعات من GitHub ] ---
sync_printer_list() {
    curl -sL "$URL_LIST" -o /tmp/.printer_db
    if [ ! -s /tmp/.printer_db ]; then
        cp /usr/local/bin/printers.list /tmp/.printer_db 2>/dev/null
    fi
    DB_FILE="/tmp/.printer_db"
}

# تشغيل الفحوصات الأولية
check_for_updates
sync_printer_list

# --- [ 3. التحقق من صلاحيات الجذر (Sudo) ] ---
if [ "$EUID" -ne 0 ]; then
    zenity --error --title "Error" --text "يرجى تشغيل الأداة بصلاحيات الـ Root (sudo)." 2>/dev/null
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
SYS_ICON="printer"

# --- [ 4. قائمة الخدمات (دمج محمود ربيع مع البحث الجديد) ] ---
while true; do
    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" --window-icon="$SYS_ICON" \
    --text "اختر الخدمة المطلوبة (يمكنك استخدام البحث بالأسفل):" \
    --radiolist --column "اختر" --column "ID" --column "الخدمة" \
    FALSE "1" "➕ إضافة تعريف طابعة جديدة (من قاعدة البيانات)" \
    FALSE "2" "🛠️ فحص النظام الذكي (إصلاح تلقائي)" \
    FALSE "3" "🧹 تنظيف ذاكرة الطباعة (Spooler Fix)" \
    FALSE "4" "📋 عرض حالة الطابعات المتصلة" \
    FALSE "5" "⚠️ إرشادات حشر الورق (فيديو)" \
    FALSE "6" "❌ خروج" \
    --width=650 --height=500 2>/dev/null)

    if [ -z "$CHOICE" ] || [ "$CHOICE" == "6" ]; then exit 0; fi

    case "$CHOICE" in
        1) # --- إضافة طابعة مع خاصية البحث ---
            SELECTED=$(cat "$DB_FILE" | awk -F'|' '{print $1 " | " $2 " | " $3}' | zenity --list \
                --title "قاعدة بيانات الطابعات" \
                --text "ابحث باسم الفرع أو الـ IP:" \
                --column="الفرع" --column="IP Address" --column="الموديل" \
                --width=700 --height=450 --search-column=1 2>/dev/null)

            if [ -n "$SELECTED" ]; then
                IP=$(echo "$SELECTED" | awk -F' | ' '{print $2}')
                BRANCH=$(echo "$SELECTED" | awk -F' | ' '{print $1}')
                MODEL=$(echo "$SELECTED" | awk -F' | ' '{print $3}')
                PR_NAME="Printer_${BRANCH// /_}"

                (
                echo "20" ; echo "# جاري إعادة تشغيل خدمة CUPS..." ; sudo systemctl restart cups
                echo "50" ; echo "# جاري فحص الاتصال بـ $IP..."
                if ping -c 1 -W 1 "$IP" >/dev/null; then
                    echo "80" ; echo "# جاري التعريف..."
                    sudo lpadmin -p "$PR_NAME" -E -v "socket://$IP" -m driverless:socket://$IP
                    sudo lpdefault -d "$PR_NAME"
                    echo "100"
                else
                    echo "100" ; zenity --error --text "الطابعة غير متصلة بالشبكة!" 2>/dev/null ; exit 1
                fi
                ) | zenity --progress --title "تثبيت" --auto-close --percentage=0 2>/dev/null
                
                [ $? -eq 0 ] && zenity --info --text "تم تعريف طابعة $BRANCH بنجاح." 2>/dev/null
            fi
            ;;

        2) # --- فحص ذكي (محمود ربيع) ---
            (
            echo "30" ; systemctl restart cups
            echo "60" ; cancel -a 2>/dev/null
            echo "90" ; for p in $(lpstat -p | grep "disabled" | awk '{print $2}'); do cupsenable "$p"; cupsaccept "$p"; done
            echo "100"
            ) | zenity --progress --title "Smart Fix" --text "جاري معالجة مشاكل النظام..." --auto-close 2>/dev/null
            zenity --info --text "تم إصلاح خدمات الطباعة وتنشيط الطابعات المعطلة." 2>/dev/null
            ;;

        3) # --- تنظيف الذاكرة ---
            sudo systemctl stop cups && sudo rm -rf /var/spool/cups/* && sudo systemctl start cups
            zenity --info --text "تم تنظيف ذاكرة الطباعة (Spooler) بنجاح." 2>/dev/null
            ;;

        4) # --- الحالة العامة ---
            STATUS=$(lpstat -p); JOBS=$(lpstat -o)
            zenity --info --title "Status" --text "<b>حالة الطابعات:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=500 2>/dev/null
            ;;

        5) # --- فيديو حشر الورق (محمود ربيع) ---
            zenity --info --text "سيتم فتح الفيديو الإرشادي الآن..." --width=300 2>/dev/null
            sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view" &>/dev/null &
            ;;
    esac
done
