#!/bin/bash
# ===============================================================
#  Script: it-aman-central-pro.sh (Version 5.2)
#  Description: نظام إدارة وتعريف الطابعات المركزي
# ===============================================================

# --- [ الإعدادات المركزية ] ---
CURRENT_VERSION="5.2"
OFFICIAL_NAME="نظام تعريف الطابعات المركزي - IT Aman"
USER_GH="BAKR1911"
REPO_GH="printer-tool"
BRANCH_GH="main"

# روابط السحب المباشر
URL_VER="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/version.txt?v=$(date +%s)"
URL_CODE="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.sh?v=$(date +%s)"
URL_LIST="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.list?v=$(date +%s)"

# --- [ 1. وظيفة ضمان وجود الأيقونة على سطح المكتب ] ---
ensure_desktop_icon() {
    local REAL_USER=${SUDO_USER:-$USER}
    local DESKTOP_PATH=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP)
    [ -z "$DESKTOP_PATH" ] && DESKTOP_PATH="/home/$REAL_USER/Desktop"
    local ICON_FILE="$DESKTOP_PATH/it-aman.desktop"
    
    if [ ! -f "$ICON_FILE" ]; then
        cat <<EOF > "$ICON_FILE"
[Desktop Entry]
Version=1.0
Type=Application
Name=تعريف الطابعات IT
Comment=Central Printer Setup
Exec=sudo /usr/local/bin/it-aman
Icon=printer
Terminal=false
Categories=System;Utility;
EOF
        chown "$REAL_USER":"$REAL_USER" "$ICON_FILE"
        chmod +x "$ICON_FILE"
        sudo -u "$REAL_USER" gio set "$ICON_FILE" metadata::trusted true 2>/dev/null
    fi
}

# --- [ 2. التحديث التلقائي الصامت ] ---
auto_update() {
    if ping -c 1 -W 2 google.com &>/dev/null; then
        REMOTE_V=$(curl -sL "$URL_VER" | tr -d '[:space:]')
        if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
            sudo curl -sL "$URL_CODE" -o /usr/local/bin/it-aman
            sudo chmod +x /usr/local/bin/it-aman
            pkill -f it-aman ; /usr/local/bin/it-aman & exit 0
        fi
    fi
}

# --- [ 3. سحب قاعدة البيانات المركزية ] ---
sync_database() {
    rm -f /tmp/.printer_db
    curl -sL --connect-timeout 5 "$URL_LIST" -o /tmp/.printer_db
    DB_FILE="/tmp/.printer_db"
}

# تشغيل العمليات التمهيدية
auto_update
ensure_desktop_icon
sync_database

# التأكد من صلاحيات الـ Root
if [ "$EUID" -ne 0 ]; then
    zenity --error --text "الرجاء تشغيل الأداة باستخدام sudo it-aman" --width=300 2>/dev/null
    exit 1
fi

# --- [ 4. الواجهة الرئيسية ] ---
while true; do
    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" --window-icon="printer" \
    --text "اختر الخدمة المطلوبة من القائمة المركزية:" \
    --radiolist --column "اختر" --column "ID" --column "الوصف" \
    FALSE "1" "➕ تعريف طابعة جديدة (البحث في GitHub List)" \
    FALSE "2" "🛠️ فحص وإصلاح خدمات الطباعة (Smart Fix)" \
    FALSE "3" "🧹 مسح ذاكرة الطابعات (Clear Spooler)" \
    FALSE "4" "📋 عرض تقرير حالة الطابعات" \
    FALSE "5" "🚪 خروج" \
    --width=600 --height=450 2>/dev/null)

    [ -z "$CHOICE" ] || [ "$CHOICE" == "5" ] && exit 0

    case "$CHOICE" in
        1) # --- إضافة وتعريف طابعة مع فحص الشبكة ---
            if [ ! -s "$DB_FILE" ]; then
                zenity --error --text "فشل سحب القائمة من GitHub. تأكد من الإنترنت." 2>/dev/null
                continue
            fi

            SELECTED=$(cat "$DB_FILE" | zenity --list --title "قاعدة البيانات المركزية" \
                --text "ابحث عن الفرع (Search Aswan, Cairo, etc.):" \
                --column "فرع | IP | موديل" \
                --width=750 --height=550 2>/dev/null)

            if [ -n "$SELECTED" ]; then
                # استخراج الـ IP والاسم
                IP=$(echo "$SELECTED" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
                BRANCH=$(echo "$SELECTED" | cut -d'|' -f1 | xargs)
                PR_NAME="Printer_${BRANCH// /_}"

                (
                echo "10" ; echo "# جاري فحص اتصال الطابعة $IP..."
                if ping -c 1 -W 2 "$IP" >/dev/null; then
                    echo "40" ; echo "# جاري تصفير خدمات CUPS..."
                    systemctl restart cups
                    echo "70" ; echo "# جاري تعريف الطابعة $BRANCH..."
                    # أمر التعريف الفعلي
                    lpadmin -p "$PR_NAME" -E -v "socket://$IP" -m driverless:socket://$IP
                    lpdefault -d "$PR_NAME"
                    echo "100"
                else
                    echo "# الطابعة غير متصلة بالشبكة!" ; sleep 3 ; exit 1
                fi
                ) | zenity --progress --title "تثبيت مركزي" --auto-close --width=400 2>/dev/null
                
                [ $? -eq 0 ] && zenity --info --text "تم تعريف طابعة ($BRANCH) بنجاح." 2>/dev/null
            fi
            ;;

        2) # --- Smart Fix ---
            (
            echo "30" ; systemctl restart cups
            echo "60" ; cancel -a
            echo "100"
            ) | zenity --progress --title "إصلاح الخدمات" --auto-close 2>/dev/null
            zenity --info --text "تمت إعادة تشغيل الخدمات بنجاح." 2>/dev/null
            ;;

        3) # --- Clear Spooler ---
            systemctl stop cups && rm -rf /var/spool/cups/* && systemctl start cups
            zenity --info --text "تم تنظيف ذاكرة الطباعة." 2>/dev/null
            ;;

        4) # --- Status ---
            zenity --info --title "الحالة" --text "$(lpstat -p)\n\n$(lpstat -o)" --width=500 2>/dev/null
            ;;
    esac
done
