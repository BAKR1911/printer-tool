#!/bin/bash
# ===============================================================
#  Script: printers.sh (Final Production Edition - BAKR1911)
# ===============================================================

OFFICIAL_NAME="Help Desk Operations Support"
CURRENT_VERSION="4.0"
SYS_ICON="printer"

# --- [ الروابط المباشرة لـ GitHub ] ---
URL_VER="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/version.txt"
URL_LIST="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.list"
URL_CODE="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.sh"

# --- [ 1. وظيفة التحديث التلقائي ] ---
check_updates() {
    REMOTE_V=$(curl -sL --connect-timeout 2 "$URL_VER" | tr -d '[:space:]')
    
    if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
        if zenity --question --title "Update Available" \
           --text "يتوفر إصدار جديد ($REMOTE_V) للأداة.\nهل تريد التحديث الآن لضمان عمل الطابعات؟" --width=350; then
            
            (
            echo "20"; curl -sL "$URL_CODE" -o /tmp/printers_new.sh
            echo "80"; sudo mv /tmp/printers_new.sh /usr/local/bin/it-aman
            sudo chmod +x /usr/local/bin/it-aman
            echo "100"
            ) | zenity --progress --title "جاري التحديث..." --auto-close --pulsate
            
            zenity --info --text "تم التحديث بنجاح! سيتم إعادة تشغيل الأداة."
            /usr/local/bin/it-aman & exit 0
        fi
    fi
}

# --- [ 2. وظيفة جلب البيانات للذاكرة المؤقتة ] ---
sync_data() {
    curl -sL "$URL_LIST" -o /tmp/.printer_db
    # لو الملف فاضي أو مفيش نت، استخدم النسخة المحلية الاحتياطية
    if [ ! -s /tmp/.printer_db ]; then
        cp /usr/local/bin/printers.list /tmp/.printer_db 2>/dev/null
    fi
    DB_FILE="/tmp/.printer_db"
}

# --- [ 3. وظيفة فحص الاتصال بالطابعة ] ---
check_connection() {
    local ip=$1
    if ! ping -c 1 -W 2 "$ip" &>/dev/null; then
        zenity --warning --title "تنبيه اتصال" \
        --text "⚠️ الطابعة ($ip) غير متصلة بالشبكة حالياً.\nتأكد من توصيل كابل الـ LAN في الطابعة." --width=400
        return 1
    fi
    return 0
}

# --- [ 4. وظيفة تعريف الطابعة مع البحث ] ---
install_printer() {
    # ميزة البحث مدمجة في zenity بمجرد الكتابة
    SELECTED=$(column -s'|' -t "$DB_FILE" | zenity --list --title "$OFFICIAL_NAME" \
        --text "ابحث عن فرعك أو طابعتك (مثال: Aswan):" \
        --column "قائمة الفروع المعتمدة" --width=700 --height=500 --print-column=1)

    if [ -n "$SELECTED" ]; then
        PR_NAME=$(echo "$SELECTED" | awk '{print $1}')
        PR_IP=$(grep "^$PR_NAME|" "$DB_FILE" | cut -d'|' -f2)

        if check_connection "$PR_IP"; then
            (
            echo "30"; lpadmin -x "$PR_NAME" 2>/dev/null
            echo "70"; lpadmin -p "$PR_NAME" -E -v "socket://$PR_IP" -m "everywhere" -L "$PR_NAME"
            echo "100"
            ) | zenity --progress --title "جاري التثبيت..." --auto-close --pulsate
            zenity --info --text "تم تعريف طابعة فرع ($PR_NAME) بنجاح ✅"
        fi
    fi
}

# --- [ 5. المحرك الأساسي للأداة ] ---
check_updates
sync_data

# فحص وجود طابعات معرفة
if [ -z "$(lpstat -v)" ]; then
    zenity --info --title "$OFFICIAL_NAME" --text "مرحباً بك. لم يتم العثور على طابعات.\nسنقوم الآن بالبحث عن طابعتك."
    install_printer
else
    while true; do
        MAIN_CHOICE=$(zenity --list --title "$OFFICIAL_NAME" --window-icon="$SYS_ICON" \
            --text "نظام الدعم الفني لعمليات الفروع - اختر الخدمة:" \
            --column "ID" --column "الخدمة" --hide-column=1 \
            "1" "🛠️ إصلاح طابعة متعطلة (Smart Repair)" \
            "2" "🧹 مسح أوامر الطباعة العالقة (Clear Spooler)" \
            "3" "🆕 تعريف طابعة فرع إضافية / Install New" \
            "4" "📊 عرض حالة جميع الطابعات / View Status" \
            "5" "🚪 خروج / Exit" --width=550 --height=450)

        case "$MAIN_CHOICE" in
            1) 
                DEF_PRINTER=$(lpstat -d | cut -d: -f2 | xargs)
                if [ -n "$DEF_PRINTER" ]; then
                    sudo systemctl restart cups
                    cupsenable "$DEF_PRINTER" && cupsaccept "$DEF_PRINTER"
                    zenity --info --text "تم تنشيط محرك الطباعة لـ $DEF_PRINTER ✅"
                else
                    zenity --error --text "لا توجد طابعة افتراضية لإصلاحها!"
                fi ;;
            2) cancel -a -x; zenity --info --text "تم تنظيف ذاكرة الأوامر العالقة." ;;
            3) install_printer ;;
            4) zenity --info --title "حالة الطابعات" --text "$(lpstat -p)" --width=500 ;;
            *) exit 0 ;;
        esac
    done
fi
#!/bin/bash

# 1. نسخ ملف البرنامج الأساسي للمسار العام وتغيير اسمه لـ it-aman
# (تأكد أن الملف المرفوع اسمه printers.sh)
sudo cp printers.sh /usr/local/bin/it-aman
sudo chmod +x /usr/local/bin/it-aman

# 2. إنشاء أيقونة سطح المكتب أتوماتيكياً (بدل النسخ)
DESKTOP_PATH=$(xdg-user-dir DESKTOP)
[ -z "$DESKTOP_PATH" ] && DESKTOP_PATH="$HOME/Desktop"

cat <<EOF > "$DESKTOP_PATH/it-aman.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Printer Tool
Comment=Help Desk Operations Support
Exec=/usr/local/bin/it-aman
Icon=printer
Terminal=false
Categories=System;Utility;
EOF

# 3. إعطاء صلاحية التشغيل للأيقونة
chmod +x "$DESKTOP_PATH/it-aman.desktop"

# 4. نسخ ملف القائمة الاحتياطي (اختياري)
sudo cp printers.list /usr/local/bin/printers.list 2>/dev/null

echo "Done! The tool is now on your Desktop."
