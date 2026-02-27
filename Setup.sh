#!/bin/bash
# ===============================================================
#  Script: setup.sh (The Installer)
#  Purpose: Create Admin, Install Tool, Create Silent Desktop Icon
# ===============================================================

# التأكد من التشغيل كجذر
if [[ $EUID -ne 0 ]]; then
   echo "Please run with sudo"
   exit 1
fi

FIXED_ADMIN="admin"

echo "--- [1] Checking Admin User Status ---"

# التأكد من يوزر الإدارة (admin)
if id "$FIXED_ADMIN" &>/dev/null; then
    echo "User '$FIXED_ADMIN' already exists. Skipping creation."
else
    echo "------------------------------------------------"
    read -s -p "Enter NEW local password for $FIXED_ADMIN: " ADMIN_PASS
    echo ""
    
    echo "Creating local admin user: $FIXED_ADMIN..."
    useradd -m -s /bin/bash "$FIXED_ADMIN"
    
    # تحديث الـ Shadow وتعيين الباسورد
    pwconv
    echo "$FIXED_ADMIN:$ADMIN_PASS" | chpasswd --force-shadow 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "Password for '$FIXED_ADMIN' set successfully."
    else
        echo "Standard bypass failed, using direct shadow update..."
        echo "$FIXED_ADMIN:$ADMIN_PASS" | chpasswd -c SHA512
    fi
fi

# إضافة اليوزر لمجموعة الـ sudo
usermod -aG sudo "$FIXED_ADMIN" 2>/dev/null || usermod -aG wheel "$FIXED_ADMIN"
echo "Permissions verified for $FIXED_ADMIN."

echo "------------------------------------------------"

# [2] تحديد يوزر الموظف الحالي ومسار سطح المكتب
REAL_LOGIN_USER=$(logname 2>/dev/null || echo $SUDO_USER)
USER_HOME=$(getent passwd "$REAL_LOGIN_USER" | cut -d: -f6)

# البحث عن مجلد سطح المكتب (يدعم العربي والإنجليزي)
if [ -d "$USER_HOME/Desktop" ]; then
    DESKTOP_PATH="$USER_HOME/Desktop"
elif [ -d "$USER_HOME/سطح المكتب" ]; then
    DESKTOP_PATH="$USER_HOME/سطح المكتب"
else
    DESKTOP_PATH="$USER_HOME/Desktop"
    mkdir -p "$DESKTOP_PATH"
fi

echo "Installing IT Aman Tool for user: $REAL_LOGIN_USER"

# [3] تثبيت السكربت الأساسي (printers.sh) في مسار النظام الثابت
if [ -f "printers.sh" ]; then
    cp printers.sh /usr/local/bin/it-aman
    chmod +x /usr/local/bin/it-aman
    chown root:root /usr/local/bin/it-aman
    echo "Main script installed to /usr/local/bin/it-aman"
else
    echo "Error: printers.sh not found in current folder!"
    exit 1
fi

# [4] إضافة استثناء في الـ Sudoers (عشان يفتح بدون باسورد للموظف)
echo "$REAL_LOGIN_USER ALL=(ALL) NOPASSWD: /usr/local/bin/it-aman" > /etc/sudoers.d/it-aman-tool
chmod 0440 /etc/sudoers.d/it-aman-tool

# [5] إنشاء الأيقونة الاحترافية (بدون تيرمنال)
cat <<EOF > "$DESKTOP_PATH/IT-Aman.desktop"
[Desktop Entry]
Version=12.6
Type=Application
Name=Printers
Comment=Printer Repair Tool
Exec=sudo /usr/local/bin/it-aman
Icon=printer
Terminal=false
StartupNotify=true
Categories=System;Utility;
X-GNOME-Autostart-enabled=true
EOF

# ضبط ملكية الأيقونة للموظف
chown "$REAL_LOGIN_USER":"$REAL_LOGIN_USER" "$DESKTOP_PATH/IT-Aman.desktop"
chmod +x "$DESKTOP_PATH/IT-Aman.desktop"

# إجبار السيستم على الوثوق في الأيقونة (لأجهزة Ubuntu الحديثة)
sudo -u "$REAL_LOGIN_USER" gio set "$DESKTOP_PATH/IT-Aman.desktop" metadata::trusted true 2>/dev/null || true

echo "------------------------------------------------"
echo "Installation Complete Successfully!"
echo "The tool is now on $REAL_LOGIN_USER's Desktop."
