#!/bin/bash
# ===============================================================
#  Script: IT_Aman_Ultimate_System (Version 6.0)
#  Merged: Mahmoud Rabia + Centralized Management
# ===============================================================

CURRENT_VERSION="6.0"
OFFICIAL_NAME="IT Aman - نظام الدعم الفني للطابعات"
USER_GH="BAKR1911"
REPO_GH="printer-tool"
BRANCH_GH="main"

# الروابط المركزية
URL_VER="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/version.txt?v=$(date +%s)"
URL_CODE="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.sh?v=$(date +%s)"
URL_LIST="https://raw.githubusercontent.com/$USER_GH/$REPO_GH/$BRANCH_GH/printers.list?v=$(date +%s)"

# 1. نظام التحديث التلقائي الصامت (عند فتح البرنامج)
auto_sync_system() {
    if ping -c 1 -W 2 google.com &>/dev/null; then
        REMOTE_V=$(curl -sL "$URL_VER" | tr -d '[:space:]')
        if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
            # سحب الكود الجديد واستبداله فوراً
            sudo curl -sL "$URL_CODE" -o /usr/local/bin/it-aman
            sudo chmod +x /usr/local/bin/it-aman
            # إعادة تشغيل النسخة الجديدة وإغلاق الحالية
            exec /usr/local/bin/it-aman
        fi
    fi
}

# 2. سحب الداتا بيز المركزية
fetch_central_db() {
    rm -f /tmp/.printer_db
    curl -sL --connect-timeout 5 "$URL_LIST" -o /tmp/.printer_db
    DB_FILE="/tmp/.printer_db"
}

# تشغيل الفحوصات
auto_sync_system
fetch_central_db

if [ "$EUID" -ne 0 ]; then
    zenity --error --text "يرجى تشغيل الأداة بصلاحية المدير (sudo it-aman)" --width=300 2>/dev/null
    exit 1
fi

# الواجهة الرئيسية (دمج كامل)
while true; do
    CHOICE=$(zenity --list --title "$OFFICIAL_NAME" --window-icon="printer" \
    --text "مرحباً بك في نظام الدعم الفني. اختر الخدمة المطلوبة:" \
    --radiolist --column "اختر" --column "ID" --column "الخدمة" \
    FALSE "1" "➕ تعريف طابعة جديدة (بحث في دليل الفروع)" \
    FALSE "2" "🛠️ الإصلاح الذكي للخدمات (Smart Fix)" \
    FALSE "3" "🧹 تنظيف الذاكرة ومسح أوامر الطباعة المعلقة" \
    FALSE "4" "📜 خطوات إزالة الورق العالق (فيديو توضيحي)" \
    FALSE "5" "📠 تعريف وصيانة الطابعات الحرارية (Thermal/Serial)" \
    FALSE "6" "📊 عرض تقرير الحالة العام" \
    FALSE "7" "🚪 خروج" \
    --width=650 --height=550 2>/dev/null)

    [ -z "$CHOICE" ] || [ "$CHOICE" == "7" ] && exit 0

    case "$CHOICE" in
        1) # تعريف حقيقي مربوط بالـ IP والشبكة
            SELECTED=$(cat "$DB_FILE" | zenity --list --title "دليل طابعات الفروع" \
                --text "اكتب اسم الفرع للبحث والفلترة (مثال: Aswan):" \
                --column "الفرع | العنوان الرقمي | الموديل" \
                --width=750 --height=500 2>/dev/null)

            if [ -n "$SELECTED" ]; then
                IP=$(echo "$SELECTED" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
                BRANCH=$(echo "$SELECTED" | cut -d'|' -f1 | xargs)
                PR_NAME="Printer_${BRANCH// /_}"

                (
                echo "20" ; echo "# جاري فحص اتصال الطابعة بالشبكة ($IP)..."
                if ping -c 1 -W 2 "$IP" >/dev/null; then
                    echo "50" ; echo "# جاري تنشيط المحرك وتثبيت التعريف..."
                    systemctl restart cups
                    # الكومند الفعلي للتعريف
                    lpadmin -p "$PR_NAME" -E -v "socket://$IP" -m driverless:socket://$IP
                    lpdefault -d "$PR_NAME"
                    echo "100"
                else
                    echo "# خطأ: الطابعة غير متصلة بالشبكة حالياً!" ; sleep 3 ; exit 1
                fi
                ) | zenity --progress --title "جاري التثبيت" --auto-close --width=400 2>/dev/null
                
                [ $? -eq 0 ] && zenity --info --text "تم تعريف طابعة $BRANCH بنجاح." 2>/dev/null
            fi
            ;;

        2) # الإصلاح الذكي (محمود ربيع)
            (
            echo "30" ; systemctl restart cups
            echo "60" ; cancel -a
            echo "90" ; for p in $(lpstat -p | grep "disabled" | awk '{print $2}'); do cupsenable "$p"; cupsaccept "$p"; done
            echo "100"
            ) | zenity --progress --title "إصلاح ذكي" --auto-close 2>/dev/null
            zenity --info --text "تمت صيانة جميع خدمات الطباعة وتفعيل الطابعات المعطلة." 2>/dev/null
            ;;

        3) # مسح الذاكرة
            systemctl stop cups && rm -rf /var/spool/cups/* && systemctl start cups
            zenity --info --text "تم مسح ذاكرة أوامر الطباعة (Spooler) بنجاح." 2>/dev/null
            ;;

        4) # فيديو حشر الورق
            xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view" &
            ;;

        5) # الطابعات الحرارية (Serial Fix)
            zenity --info --text "جاري فحص وتنشيط منافذ الطابعات الحرارية..." --width=300
            sudo chmod 666 /dev/usb/lp* 2>/dev/null
            sudo usermod -a -G lpadmin $USER
            zenity --info --text "تم تحديث صلاحيات المنافذ. إذا لم تعمل، يرجى إعادة توصيل كابل الـ USB." 2>/dev/null
            ;;

        6) # تقرير الحالة
            zenity --info --title "حالة النظام" --text "$(lpstat -p)\n\n$(lpstat -o)" --width=550 2>/dev/null
            ;;
    esac
done
