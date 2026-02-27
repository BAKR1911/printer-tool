#!/bin/bash
# ===============================================================
# it_aman_printer_fix.sh
# Version: 11.6-focused (Integrated Sudo & Desktop Fix)
# ===============================================================

# 1. طلب صلاحيات الـ Sudo تلقائياً واجهة رسومية
if [ "$EUID" -ne 0 ]; then
  pkexec "$0" "$@"
  exit $?
fi

CURRENT_VERSION="11.6-focused"
TOOL_NAME="IT Aman - Printer Tool"
SYS_ICON="printer-error"

# Central DB
CENTRAL_DB_URL="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.list"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

LOG_FILE="/var/log/it-aman.log"
# تحديد المستخدم الحقيقي لتجنب مشاكل الـ Root في المسارات
REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ==============================
# Auto Create Desktop Shortcut & Persistent Path
# ==============================
FINAL_BIN="/usr/local/bin/it-aman"

# تثبيت السكربت في مسار ثابت بالسيستم لضمان عمل الأيقونة دائماً
if [ "$0" != "$FINAL_BIN" ]; then
    cp "$0" "$FINAL_BIN"
    chmod +x "$FINAL_BIN"
fi

# تحديد مجلد سطح المكتب للمستخدم الفعلي
DESKTOP_DIR=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP || echo "$REAL_HOME/Desktop")
DESKTOP_FILE="$DESKTOP_DIR/Printer-Tool.desktop"

if [ ! -f "$DESKTOP_FILE" ]; then
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Printer Tool
Comment=IT Printer Management Tool
Exec=sudo $FINAL_BIN
Icon=printer
Terminal=true
Type=Application
Categories=Utility;
EOF

chmod +x "$DESKTOP_FILE"
chown "$REAL_USER":"$REAL_USER" "$DESKTOP_FILE"
# جعل الأيقونة موثوقة لأنظمة Ubuntu
sudo -u "$REAL_USER" gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || true

echo "Desktop shortcut created for $REAL_USER."
fi

# -------------------------
# Basic checks & logging
# -------------------------
_log(){ echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 0644 "$LOG_FILE" 2>/dev/null || true

# Driver search dirs
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" "/usr/share/cups/drv" )

# -------------------------
# Fetch DB (try central then local)
# -------------------------
fetch_db() {
  rm -f "$TMP_DB" 2>/dev/null || true
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    if curl -fsS --connect-timeout 5 "$CENTRAL_DB_URL" -o "$TMP_DB" 2>/dev/null; then
      if [ -s "$TMP_DB" ]; then DB_FILE="$TMP_DB"; _log "Fetched central DB"; return; fi
    fi
  fi
  if [ -f "$LOCAL_DB" ] && [ -s "$LOCAL_DB" ]; then
    DB_FILE="$LOCAL_DB"; _log "Using local DB: $LOCAL_DB"; return
  fi
  cat > /tmp/.printer_db_sample <<'EOF'
# Sample printers.list
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
  DB_FILE="/tmp/.printer_db_sample"
}

normalize_db() {
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > /tmp/.printer_db_clean
  DB_FILE="/tmp/.printer_db_clean"
}

normalize_legacy() {
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    if (NF==3) {
      b=$1; a=$2; m=$3;
      gsub(/^[ \t]+|[ \t]+$/,"",b); gsub(/^[ \t]+|[ \t]+$/,"",a); gsub(/^[ \t]+|[ \t]+$/,"",m);
      print b "|" m "|" a "|network"
    } else print $0
  }' "$DB_FILE" > /tmp/.printer_db_norm
  DB_FILE="/tmp/.printer_db_norm"
}

validate_network() {
  local target="$1"
  if ! ping -c1 -W2 "$target" &>/dev/null; then return 1; fi
  if command -v nc &>/dev/null; then
    if nc -z -w2 "$target" 9100 &>/dev/null; then return 0; else return 2; fi
  fi
  return 0
}

find_driver() {
  local hint="$1"
  for d in "${DRIVER_DIRS[@]}"; do
    [ -d "$d" ] || continue
    if [ -n "$hint" ]; then
      found=$(grep -ril --null -e "$hint" "$d" 2>/dev/null | tr '\0' '\n' | head -n1)
      if [ -n "$found" ]; then echo "$found"; return 0; fi
    fi
    f=$(ls "$d"/*.ppd 2>/dev/null | head -n1)
    [ -n "$f" ] && { echo "$f"; return 0; }
  done
  driver_file=$(zenity --file-selection --title "Select driver PPD" 2>/dev/null)
  if [ -n "$driver_file" ]; then echo "$driver_file"; return 0; fi
  echo "" ; return 1
}

deploy_network_printer() {
  local branch="$1"
  local label="$2"
  local addr="$3"
  local driver_hint="$4"
  local cups_name="ITA_${branch// /_}_${label// /_}"
  cups_name=$(echo "$cups_name" | tr -s '_')

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --text "الطابعة معرفة بالفعل." 2>/dev/null
    return 0
  fi

  validate_network "$addr"
  local vres=$?
  if [ $vres -eq 1 ]; then
    zenity --error --text "تعذر الوصول للطابعة (Ping failed)." 2>/dev/null
    return 1
  fi

  local uri="socket://${addr}"
  local driver_file=$(find_driver "$driver_hint")
  if [ -n "$driver_file" ]; then
    lpadmin -p "$cups_name" -E -v "$uri" -P "$driver_file" 2>/dev/null || lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null
  else
    lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null || lpadmin -p "$cups_name" -E -v "$uri" -m raw 2>/dev/null
  fi
  lpdefault -d "$cups_name" 2>/dev/null

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --text "تم تعريف الطابعة بنجاح: $label" 2>/dev/null
    if [ -n "$REAL_USER" ]; then
        sudo -u "$REAL_USER" xdg-open "http://localhost:631/printers/${cups_name}" &>/dev/null || true
    fi
    return 0
  fi
}

branch_list_ui() {
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u)
  tmp=$(mktemp)
  echo "Search / فلترة الفروع" > "$tmp"
  echo "$branches" >> "$tmp"
  SELECTED=$(cat "$tmp" | zenity --list --title "Branches" --column "Branch" --height=420 --width=420 2>/dev/null)
  rm -f "$tmp"
  if [ "$SELECTED" == "Search / فلترة الفروع" ]; then
    SEARCH=$(zenity --entry --title "Search" --text "اكتب حروف الفرع:" 2>/dev/null)
    [ -z "$SEARCH" ] && echo "" && return
    LIST=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ tolower(s) {print $1}' "$DB_FILE" | sort -u)
    PICK=$(echo -n "$LIST" | zenity --list --column "Branch" --height=420 2>/dev/null)
    echo "$PICK"
  else
    echo "$SELECTED"
  fi
}

search_branch_and_deploy() {
  while true; do
    branch=$(branch_list_ui)
    [ -z "$branch" ] && return
    printers=$(awk -F'|' -v b="$branch" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b)) print $0 }' "$DB_FILE")
    DISP=$(echo "$printers" | awk -F'|' '{print $2 " | " $4}')
    SEL=$(echo -n "$DISP" | zenity --list --title "$branch" --column "Label | Type" --width=700 --height=420 2>/dev/null)
    [ -z "$SEL" ] && continue
    sel_label=$(echo "$SEL" | awk -F'|' '{print $1}' | xargs)
    record=$(awk -F'|' -v b="$branch" -v l="$sel_label" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE")
    addr=$(echo "$record" | awk -F'|' '{print $3}' | xargs)
    typ=$(echo "$record" | awk -F'|' '{print $4}' | xargs)
    driver_hint=$(echo "$record" | awk -F'|' '{print $5}' | xargs)
    deploy_network_printer "$branch" "$sel_label" "$addr" "$driver_hint"
    return
  done
}

# -------------------------
# Main Execution
# -------------------------
fetch_db
normalize_db
normalize_legacy

while true; do
  CHOICE=$(zenity --list --title "$TOOL_NAME" --window-icon="$SYS_ICON" --text "قائمة الخدمات المتاحة:" \
    --radiolist --column "Select" --column "ID" --column "Option" \
    FALSE "1" "معالجة حشر الورق / Paper Jam Guide" \
    FALSE "2" "فحص النظام الذكي / Smart System Diagnostic" \
    FALSE "3" "تعريف طابعة (بحث فرع + تعريف) / Define Printer" \
    FALSE "4" "إصلاح أوامر الطباعة (مسح الذاكرة) / Quick Fix Spooler" \
    FALSE "5" "عرض الحالة العامة للطابعات / View Status" \
    FALSE "6" "خروج / Exit" \
    --width=780 --height=520 2>/dev/null)
  
  [ -z "$CHOICE" ] || [ "$CHOICE" == "6" ] && exit 0
  case "$CHOICE" in
    1) sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view" & ;;
    2) ( systemctl restart cups; cancel -a; ) | zenity --progress --auto-close 2>/dev/null ;;
    3) search_branch_and_deploy ;;
    4) systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; zenity --info --text "تم المسح." ;;
    5) zenity --info --text "<b>الحالة:</b>\n$(lpstat -p)" --width=600 2>/dev/null ;;
  esac
done
