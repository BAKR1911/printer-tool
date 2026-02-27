#!/bin/bash
# ===============================================================
#  Script: printers.sh (Final Fixed Edition)
#  Identity: Help Desk Operations Support
# ===============================================================

OFFICIAL_NAME="Help Desk Operations Support"
SYS_ICON="printer"

# --- [ حل مشكلة البحث عن قاعدة البيانات ] ---
# السكربت سيبحث الآن في 3 مسارات مختلفة بالترتيب
if [ -f "/usr/local/bin/printers.list" ]; then
    DB_FILE="/usr/local/bin/printers.list"
elif [ -f "$HOME/Downloads/IT-Tool/printers.list" ]; then
    DB_FILE="$HOME/Downloads/IT-Tool/printers.list"
elif [ -f "./printers.list" ]; then
    DB_FILE="./printers.list"
else
    # إذا لم يجد الملف في أي مكان، يظهر رسالة الخطأ ويخرج
    zenity --error --title "$OFFICIAL_NAME" --text "⚠️ خطأ: ملف (printers.list) غير موجود!\nيرجى التأكد من وجود ملف قاعدة البيانات في مجلد IT-Tool."
    exit 1
fi

# --- [ وظيفة فحص الاتصال ] ---
check_connection() {
    local ip=$1
    if ! ping -c 1 -W 2 "$ip" &>/dev/null; then
        zenity --warning --title "تنبيه اتصال" \
        --text "⚠️ الطابعة ($ip) غير متصلة بالشبكة.\nتأكد من توصيل كابل الإنترنت (LAN) بالطابعة." --width=400
        return 1
    fi
    return 0
}

# --- [ وظيفة تعريف طابعة جديدة ] ---
install_printer() {
    SELECTED=$(column -s'|' -t "$DB_FILE" | zenity --list --title "$OFFICIAL_NAME" \
        --text "اختر الفرع أو الطابعة المراد تعريفها:" \
        --column "قائمة الطابعات المتاحة" --width=650 --height=500 --print-column=1)

    if [ -n "$SELECTED" ]; then
        PR_NAME=$(echo "$SELECTED" | awk '{print $1}')
        PR_IP=$(grep "^$PR_NAME|" "$DB_FILE" | cut -d'|' -f2)

        if check_connection "$PR_IP"; then
            (
            echo "30"; lpadmin -x "$PR_NAME" 2>/dev/null
            echo "60"; lpadmin -p "$PR_NAME" -E -v "socket://$PR_IP" -m "everywhere" -L "$PR_NAME"
            echo "100"
            ) | zenity --progress --title "$OFFICIAL_NAME" --auto-close --pulsate
            zenity --info --text "تم تعريف طابعة ($PR_NAME) بنجاح ✅"
        fi
    fi
}

# --- [ الواجهة الرئيسية ] ---
INSTALLED_CHECK=$(lpstat -v)

if [ -z "$INSTALLED_CHECK" ]; then
    zenity --info --title "$OFFICIAL_NAME" --text "مرحباً بك. لم يتم العثور على طابعات معرفة.\nسنبدأ الآن بتعريف طابعة الفرع."
    install_printer
else
    while true; do
        MAIN_CHOICE=$(zenity --list --title "$OFFICIAL_NAME" --window-icon="$SYS_ICON" \
            --text "نظام الدعم الفني - اختر الخدمة المطلوبة:" \
            --column "ID" --column "الخدمة" --hide-column=1 \
            "1" "🛠️ إصلاح طابعة متعطلة (Smart Repair)" \
            "2" "🧹 مسح أوامر الطباعة العالقة (Clear Spooler)" \
            "3" "🆕 تعريف طابعة فرع إضافية / Install New" \
            "4" "📊 عرض حالة الطابعات / View Status" \
            "5" "🚪 خروج / Exit" --width=550 --height=450)

        case "$MAIN_CHOICE" in
            1) 
                DEF_PRINTER=$(lpstat -d | cut -d: -f2 | xargs)
                if [ -n "$DEF_PRINTER" ]; then
                    sudo systemctl restart cups
                    cupsenable "$DEF_PRINTER" && cupsaccept "$DEF_PRINTER"
                    zenity --info --text "تمت إعادة تنشيط الطابعة $DEF_PRINTER ✅"
                else
                    zenity --error --text "لا توجد طابعة افتراضية لإصلاحها!"
                fi ;;
            2) cancel -a -x; zenity --info --text "تم تنظيف الذاكرة بنجاح." ;;
            3) install_printer ;;
            4) STATUS=$(lpstat -p); zenity --info --text "$STATUS" --width=500 ;;
            *) exit 0 ;;
        esac
    done
fi
