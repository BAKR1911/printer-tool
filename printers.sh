#!/bin/bash
# ===============================================================
#  Script: IT_Aman_Pro_System.sh (Version 5.0)
#  Goal: Professional Centralized Printer Management
# ===============================================================

CURRENT_VERSION="5.0"
OFFICIAL_NAME="IT Aman - Printer Management System"
USER="BAKR1911"
REPO="printer-tool"
BRANCH="main"

# روابط السيرفر المركزي
URL_VER="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/version.txt?v=$(date +%s)"
URL_CODE="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.sh?v=$(date +%s)"
URL_LIST="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.list?v=$(date +%s)"

# --- [ 1. وظيفة الأيقونة الإجبارية ] ---
create_desktop_launcher() {
    local REAL_USER=${SUDO_USER:-$USER}
    local DESKTOP_PATH=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP)
    [ -z "$DESKTOP_PATH" ] && DESKTOP_PATH="/home/$REAL_USER/Desktop"
    local ICON_FILE="$DESKTOP_PATH/it-aman.desktop"
    
    cat <<EOF > "$ICON_FILE"
[Desktop Entry]
Version=1.0
Type=Application
Name=تعريف الطابعات - IT Aman
Comment=نظام تعريف الطابعات المركزي
Exec=sudo /usr/local/bin/it-aman
Icon=printer
Terminal=false
Categories=System;Utility;
EOF
    chown "$REAL_USER":"$REAL_USER" "$ICON_FILE"
    chmod +x "$ICON_FILE"
    sudo -u "$REAL_USER" gio set "$ICON_FILE" metadata::trusted true 2>/dev/null
}

# --- [ 2. تحديث النظام الصامت ] ---
sync_system() {
    if ping -c 1 -W 2 google.com &>/dev/null; then
        REMOTE_V=$(curl -sL "$URL_VER" | tr -d '[:space:]')
        if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
            sudo curl -sL "$URL_CODE" -o /usr/local/bin/it-aman
            sudo chmod +x /usr/local/bin/it-aman
            pkill -f it-aman ; /usr/local/bin/it-aman & exit 0
        fi
    fi
}

# --- [ 3. سحب قاعدة البيانات ] ---
fetch_db() {
    rm -f /tmp/.printer_db
    curl -sL --connect-timeout 5 "$URL_LIST" -o /tmp/.printer_db
    if [ ! -s /tmp/.printer_db ]; then
        zenity --error --text "خطأ: تعذر الاتصال بالسيرفر لجلب القائمة!" --width=300 2>/dev/null
        exit 1
    fi
    DB_FILE="/tmp/.printer_db"
}

# التنفيذ الأولي
sync_system
create_desktop_launcher
fetch_db

if [ "$EUID" -ne 0 ]; then
    zenity --error --text "يرجى تشغيل البرنامج بصلاحية المدير (sudo)." 2>/dev/null
    exit 1
fi

# --- [ 4. الواجهة الرئيسية - لغة واضحة لليوزر ] ---
while true; do
    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" --window-icon="printer" \
    --text "مرحباً بك في نظام الدعم الفني للطابعات. اختر المهمة:" \
    --radiolist --column "اختر" --column "ID" --column "الوصف" \
    FALSE "1" "➕ إضافة وتعريف طابعة جديدة" \
    FALSE "2" "🛠️ الإصلاح الذكي لمشاكل التوقف (Smart Fix)" \
    FALSE "3" "🧹 مسح ذاكرة أوامر الطباعة المعلقة" \
    FALSE "4" "📋 عرض حالة جميع الطابعات الحالية" \
    FALSE "5" "⚠️ إرشادات إزالة الورق العالق (فيديو)" \
    FALSE "6" "🚪 خروج" \
    --width=600 --height=500 2>/dev/null)

    [ -z "$CHOICE" ] || [ "$CHOICE" == "6" ] && exit 0

    case "$CHOICE" in
        1) # --- إضافة وتعريف طابعة (مع فلترة حقيقية) ---
            # السطر ده بيخلي البحث يفلتر النتائج مش بس يعلم عليها
            SELECTED=$(cat "$DB_FILE" | zenity --list --title "قائمة الطابعات المركزية" \
                --text "اكتب اسم الفرع للبحث (مثال: Aswan):" \
                --column "الفرع | عنوان IP | موديل الطابعة" \
                --width=750 --height=550 --search-column=1 2>/dev/null)

            if [ -n "$SELECTED" ]; then
                # استخراج البيانات بدقة
                IP=$(echo "$SELECTED" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
                BRANCH=$(echo "$SELECTED" | awk -F'|' '{print $1}' | xargs)
                PR_NAME="Printer_${BRANCH// /_}"

                (
                echo "10" ; echo "# جاري التحقق من اتصال الطابعة بالشبكة ($IP)..."
                if ping -c 2 -W 2 "$IP" >/dev/null; then
                    echo "40" ; echo "# الطابعة متصلة. جاري تنشيط خدمة CUPS..."
                    systemctl restart cups
                    echo "70" ; echo "# جاري إرسال أوامر التعريف الفني للنظام..."
                    # التعريف الحقيقي (Force Install)
                    lpadmin -p "$PR_NAME" -E -v "socket://$IP" -m driverless:socket://$IP || \
                    lpadmin -p "$PR_NAME" -E -v "socket://$IP" -m manyereleasestag.ppd
                    
                    echo "90" ; echo "# تعيين كطابعة افتراضية..."
                    lpdefault -d "$PR_NAME"
                    echo "100"
                else
                    echo "# خطأ: الطابعة لا تستجيب على IP: $IP" ; sleep 3 ; exit 1
                fi
                ) | zenity --progress --title "جاري التثبيت والتعريف" --auto-close --width=400 2>/dev/null

                if [ $? -eq 0 ]; then
                    zenity --info --text "نجاح: تم تعريف طابعة فرع ($BRANCH) وهي جاهزة للعمل الآن." --width=350 2>/dev/null
                else
                    zenity --error --text "فشل التعريف: تأكد من كابل الشبكة في الطابعة أو صحة الـ IP." --width=350 2>/dev/null
                fi
            fi
            ;;

        2) # --- Smart Fix (شامل كل نقاط محمود ربيع) ---
            (
            echo "20" ; echo "# إعادة تشغيل محرك الطباعة..." ; systemctl restart cups
            echo "50" ; echo "# تنظيف المهام العالقة..." ; cancel -a
            echo "80" ; echo "# إعادة تنشيط الطابعات المعطلة..." 
            for p in $(lpstat -p | grep "disabled" | awk '{print $2}'); do cupsenable "$p"; cupsaccept "$p"; done
            echo "100"
            ) | zenity --progress --title "إصلاح تلقائي" --auto-close --width=400 2>/dev/null
            zenity --info --text "تم إجراء الفحص الذكي وتنشيط جميع الطابعات." 2>/dev/null
            ;;

        3) # --- Spooler Clean ---
            systemctl stop cups && rm -rf /var/spool/cups/* && systemctl start cups
            zenity --info --text "تم مسح الذاكرة المؤقتة لجميع الطابعات بنجاح." 2>/dev/null
            ;;

        4) # --- Status Report ---
            STATUS=$(lpstat -p); JOBS=$(lpstat -o)
            zenity --info --title "تقرير الحالة" --text "<b>الطابعات المعرفة:</b>\n$STATUS\n\n<b>أوامر الطباعة المنتظرة:</b>\n$JOBS" --width=550 2>/dev/null
            ;;

        5) # --- فيديو حشر الورق ---
            xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view" &
            ;;
    esac
done
