#!/bin/bash
# ===============================================================
#  Script: it_aman_centralized.sh (Version 4.2)
#  Status: Centralized Control via GitHub
# ===============================================================

CURRENT_VERSION="4.2"
OFFICIAL_NAME="IT Aman Central System v4.2"
USER="BAKR1911"
REPO="printer-tool"
BRANCH="main"

# --- [ روابط السيرفر المركزي ] ---
URL_VER="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/version.txt?v=$(date +%s)"
URL_CODE="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.sh?v=$(date +%s)"
URL_LIST="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.list?v=$(date +%s)"

# --- [ 1. وظيفة السيطرة على سطح المكتب ] ---
# عشان الأيقونة تظهر للموظف وتفتح البرنامج المركزي
create_central_icon() {
    local REAL_USER=${SUDO_USER:-$USER}
    local DESKTOP_PATH=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP)
    [ -z "$DESKTOP_PATH" ] && DESKTOP_PATH="/home/$REAL_USER/Desktop"
    
    local ICON_FILE="$DESKTOP_PATH/it-aman.desktop"
    
    # إنشاء الأيقونة لو مش موجودة أو لو النسخة قديمة
    cat <<EOF > "$ICON_FILE"
[Desktop Entry]
Version=4.2
Type=Application
Name=Printer Tool 4.2
Comment=Centralized IT Support
Exec=sudo /usr/local/bin/it-aman
Icon=printer
Terminal=false
Categories=System;Utility;
EOF
    chown "$REAL_USER":"$REAL_USER" "$ICON_FILE"
    chmod +x "$ICON_FILE"
    sudo -u "$REAL_USER" gio set "$ICON_FILE" metadata::trusted true 2>/dev/null
}

# --- [ 2. تحديث البرنامج من GitHub ] ---
check_system_update() {
    if ! ping -c 1 -W 2 google.com &>/dev/null; then return; fi
    REMOTE_VERSION=$(curl -sL "$URL_VER" | tr -d '[:space:]')
    
    if [[ -n "$REMOTE_VERSION" && "$REMOTE_VERSION" != "$CURRENT_VERSION" ]]; then
        # تحديث صامت وسريع للمخ
        sudo curl -sL "$URL_CODE" -o /usr/local/bin/it-aman
        sudo chmod +x /usr/local/bin/it-aman
        pkill -f it-aman
        /usr/local/bin/it-aman &
        exit 0
    fi
}

# --- [ 3. سحب القائمة المركزية (الربط المباشر بالـ list) ] ---
fetch_central_list() {
    # مسح النسخة المؤقتة لضمان أحدث بيانات من GitHub
    rm -f /tmp/.printer_db
    curl -sL --connect-timeout 5 "$URL_LIST" -o /tmp/.printer_db
    
    if [ ! -s /tmp/.printer_db ]; then
        zenity --error --text "خطأ: تعذر الاتصال بقاعدة البيانات المركزية على GitHub!" 2>/dev/null
        exit 1
    fi
    DB_FILE="/tmp/.printer_db"
}

# التنفيذ الأولي
check_system_update
create_central_icon
fetch_central_list

if [ "$EUID" -ne 0 ]; then
    zenity --error --text "الرجاء التشغيل بصلاحية sudo." 2>/dev/null
    exit 1
fi

# --- [ واجهة البرنامج المركزية ] ---
while true; do
    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" --window-icon="printer" \
    --text "النظام المركزي لإدارة الطابعات - المهندس محمود ربيع" \
    --radiolist --column "اختر" --column "ID" --column "الخدمة" \
    FALSE "1" "🔍 البحث في القائمة المركزية (GitHub List)" \
    FALSE "2" "⚙️ إصلاح وتصفير خدمات CUPS" \
    FALSE "3" "🧹 مسح ذاكرة الطابعات (Spooler)" \
    FALSE "4" "📊 عرض تقرير الحالة" \
    FALSE "5" "🚪 خروج" \
    --width=600 --height=450 2>/dev/null)

    [ -z "$CHOICE" ] || [ "$CHOICE" == "5" ] && exit 0

    case "$CHOICE" in
        1)
            # عرض القائمة المسحوبة من GitHub مباشرة
            SELECTED=$(cat "$DB_FILE" | zenity --list --title "Central Database" \
                --text "القائمة التالية مسحوبة من GitHub الآن:" \
                --column "Branch | IP | Model" --width=700 --height=450 2>/dev/null)

            if [ -n "$SELECTED" ]; then
                IP=$(echo "$SELECTED" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
                BRANCH=$(echo "$SELECTED" | awk -F'|' '{print $1}')
                
                (
                echo "20" ; systemctl restart cups
                echo "50" ; ping -c 1 -W 1 "$IP" >/dev/null
                if [ $? -eq 0 ]; then
                    echo "80" ; lpadmin -p "Printer_${BRANCH// /_}" -E -v "socket://$IP" -m driverless:socket://$IP
                    echo "100"
                else
                    exit 1
                fi
                ) | zenity --progress --title "جاري التثبيت المركزي" --auto-close 2>/dev/null
                
                [ $? -eq 0 ] && zenity --info --text "تم تعريف الطابعة بنجاح من السيرفر." 2>/dev/null
            fi
            ;;
        2)
            systemctl restart cups && cancel -a && zenity --info --text "تمت صيانة الخدمات." 2>/dev/null
            ;;
        3)
            systemctl stop cups && rm -rf /var/spool/cups/* && systemctl start cups && zenity --info --text "تم تنظيف الذاكرة." 2>/dev/null
            ;;
        4)
            zenity --info --text "$(lpstat -p)\n\n$(lpstat -o)" --width=500 2>/dev/null
            ;;
    esac
done
