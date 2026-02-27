#!/bin/bash
# ===============================================================
# it_aman_printer_fix.sh
# Version: 12.6-FULL-POWER
# Purpose: Branch-first UI; Network-only deploy; Sudo-less for Users
# ===============================================================

# [1] إعداد صلاحيات التنفيذ بدون باسورد (تنفذ مرة واحدة صامتاً لو أمكن)
setup_nopasswd() {
    if [ ! -f "/etc/sudoers.d/it-aman" ]; then
        # سيطلب الباسورد هنا "مرة واحدة فقط" في حياة الجهاز لتثبيت الصلاحيات
        echo "IT Aman: Initializing Secure Permissions..."
        echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/lpadmin, /usr/bin/lpstat, /usr/sbin/cupsenable, /usr/sbin/cupsaccept, /usr/bin/systemctl, /usr/bin/cancel, /usr/bin/lp, /usr/bin/cp, /usr/bin/chmod, /usr/bin/rm" | sudo tee /etc/sudoers.d/it-aman > /dev/null
        sudo chmod 0440 /etc/sudoers.d/it-aman
    fi
}
setup_nopasswd

CURRENT_VERSION="12.6-FULL"
TOOL_NAME="Printers "
SYS_ICON="printer-error"

# Central DB 
CENTRAL_DB_URL="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.list"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

LOG_FILE="/var/log/it-aman.log"
REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Driver search dirs
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" "/usr/share/cups/drv" )

# ==============================
# Auto Create Desktop Shortcut & Persistence
# ==============================
FINAL_BIN="/usr/local/bin/it-aman"
# التأكد من بقاء السكربت في مسار السيستم
if [ "$0" != "$FINAL_BIN" ]; then
    sudo cp "$0" "$FINAL_BIN"
    sudo chmod +x "$FINAL_BIN"
fi

DESKTOP_DIR=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP || echo "$REAL_HOME/Desktop")
DESKTOP_FILE="$DESKTOP_DIR/Printer-Tool.desktop"

if [ ! -f "$DESKTOP_FILE" ]; then
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Printer Tool
Comment=IT Printer Management Tool
Exec=$FINAL_BIN
Icon=printer
Terminal=false
Type=Application
Categories=Utility;
EOF
chmod +x "$DESKTOP_FILE"
chown "$REAL_USER":"$REAL_USER" "$DESKTOP_FILE"
sudo -u "$REAL_USER" gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || true
fi

# -------------------------
# Basic checks & logging
# -------------------------
_log(){ echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

# إنشاء ملف اللوج بصلاحيات تسمح بالكتابة
sudo mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
sudo touch "$LOG_FILE" 2>/dev/null
sudo chmod 0666 "$LOG_FILE" 2>/dev/null

# -------------------------
# Fetch DB (Complete Logic)
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
  _log "Created sample DB"
}

# -------------------------
# Normalize DB (Full Logic)
# -------------------------
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

# -------------------------
# Network Validation
# -------------------------
validate_network() {
  local target="$1"
  if ! ping -c1 -W2 "$target" &>/dev/null; then
    return 1
  fi
  if command -v nc &>/dev/null; then
    if nc -z -w2 "$target" 9100 &>/dev/null; then
      return 0
    else
      return 2
    fi
  fi
  return 0
}

# -------------------------
# Find Driver PPD
# -------------------------
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
  driver_file=$(zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null)
  if [ -n "$driver_file" ]; then echo "$driver_file"; return 0; fi
  echo ""
  return 1
}

# -------------------------
# Deploy Printer (The Real Work)
# -------------------------
deploy_network_printer() {
  local branch="$1"
  local label="$2"
  local addr="$3"
  local driver_hint="$4"

  local cups_name="ITA_${branch// /_}_${label// /_}"
  cups_name=$(echo "$cups_name" | tr -s '_')

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --title "Info" --text "الطابعة معرفة بالفعل: $label\nAlready exists." 2>/dev/null
    _log "skip-deploy: already exists $cups_name"
    return 0
  fi

  validate_network "$addr"
  local vres=$?
  if [ $vres -eq 1 ]; then
    zenity --error --title "Network Error" --text "تعذر الوصول للطابعة (Ping failed): $addr\nPlease check network/cable." 2>/dev/null
    _log "ping-fail $addr for $cups_name"
    return 1
  elif [ $vres -eq 2 ]; then
    zenity --warning --title "Port Warning" --text "الطابعة ترد لكن منفذ 9100 مغلق: $addr\nWill attempt add with warning." 2>/dev/null
    _log "port-closed $addr for $cups_name"
  fi

  local uri="socket://${addr}"
  local driver_file=$(find_driver "$driver_hint")
  
  # استخدام SUDO الصامت للأوامر التنفيذية
  if [ -n "$driver_file" ]; then
    sudo lpadmin -p "$cups_name" -E -v "$uri" -P "$driver_file" 2>/dev/null || sudo lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null
  else
    sudo lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null || sudo lpadmin -p "$cups_name" -E -v "$uri" -m raw 2>/dev/null || true
  fi
  sudo lpdefault -d "$cups_name" 2>/dev/null || true

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --title "Done" --text "تم تعريف الطابعة بنجاح: $label\nPrinter added." 2>/dev/null
    _log "deployed $cups_name -> $uri"
    
    # صفحة الاختبار
    echo -e "IT Aman Test Page\nPrinter: $label\nBranch: $branch\nDate: $(date)" | lp -d "$cups_name" 2>/dev/null || true
    
    # فتح صفحة CUPS
    if [ -n "$REAL_USER" ]; then
      sudo -u "$REAL_USER" xdg-open "http://localhost:631/printers/${cups_name}" &>/dev/null || true
    fi
    return 0
  else
    zenity --error --title "Failed" --text "فشل تعريف الطابعة: $label" 2>/dev/null
    _log "deploy-failed $cups_name"
    return 1
  fi
}

# -------------------------
# UI Functions (Branches & Searching)
# -------------------------
branch_list_ui() {
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u)
  tmp=$(mktemp)
  echo "Search / فلترة الفروع" > "$tmp"
  echo "$branches" >> "$tmp"
  SELECTED=$(cat "$tmp" | zenity --list --title "Branches - اختر فرع" --column "Branch or Search" --height=420 --width=420 2>/dev/null)
  rm -f "$tmp"
  [ -z "$SELECTED" ] && echo "" && return
  if [ "$SELECTED" == "Search / فلترة الفروع" ]; then
    SEARCH=$(zenity --entry --title "Search Branch" --text "اكتب حروف الفرع:" --width=520 2>/dev/null)
    [ -z "$SEARCH" ] && echo "" && return
    starts=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u)
    contains=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u)
    LIST=""
    if [ -n "$starts" ]; then while read -r b; do LIST+="$b"$'\n'; done <<< "$starts"; fi
    if [ -n "$contains" ]; then while read -r b; do if ! echo "$LIST" | grep -qx "$b"; then LIST+="$b"$'\n'; fi; done <<< "$contains"; fi
    PICK=$(echo -n "$LIST" | sed '/^[[:space:]]*$/d' | zenity --list --title "اختر فرع" --column "Branch" --height=420 --width=420 2>/dev/null)
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
    DISP=""
    while IFS= read -r line; do
      label=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
      typ=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
      DISP+="${label} | ${typ}"$'\n'
    done <<< "$printers"
    SEL=$(echo -n "$DISP" | sed '/^[[:space:]]*$/d' | zenity --list --title "طابعات $branch" --column "Label | Type" --width=720 --height=420 2>/dev/null)
    [ -z "$SEL" ] && continue
    sel_label=$(echo "$SEL" | awk -F'|' '{print $1}' | xargs)
    record=$(awk -F'|' -v b="$branch" -v l="$sel_label" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE")
    addr=$(echo "$record" | awk -F'|' '{print $3}' | xargs)
    driver_hint=$(echo "$record" | awk -F'|' '{print $5}' | xargs)
    deploy_network_printer "$branch" "$sel_label" "$addr" "$driver_hint"
    return
  done
}

# -------------------------
# Main Execution Loop
# -------------------------
fetch_db
normalize_db
normalize_legacy

while true; do
  CHOICE=$(zenity --list --title "$TOOL_NAME" --window-icon="$SYS_ICON" --text "قائمة الخدمات المتاحة (v$CURRENT_VERSION):" \
    --radiolist --column "Select" --column "ID" --column "Option" \
    FALSE "1" "معالجة حشر الورق / Paper Jam Guide" \
    FALSE "2" "فحص النظام الذكي / Smart System Diagnostic" \
    FALSE "3" "تعريف طابعة (بحث فرع + تعريف) / Define Printer" \
    FALSE "4" "إصلاح أوامر الطباعة (مسح الذاكرة) / Quick Fix Spooler" \
    FALSE "5" "عرض الحالة العامة للطابعات / View Printer Status" \
    FALSE "6" "خروج / Exit" \
    --width=780 --height=520 2>/dev/null)

  [ -z "$CHOICE" ] || [ "$CHOICE" == "6" ] && exit 0
  
  case "$CHOICE" in
    1) sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view" & ;;
    2)
      DIAG=$(mktemp)
      (
        echo "10"; sudo systemctl restart cups
        echo "50"; sudo cancel -a
        echo "80"; for p in $(lpstat -p | grep "disabled" | awk '{print $2}'); do sudo cupsenable "$p"; sudo cupsaccept "$p"; done
        echo "100"
      ) | zenity --progress --title "Smart Fix" --auto-close 2>/dev/null
      zenity --info --text "تم فحص وإصلاح خدمات الطباعة." --width=400 2>/dev/null
      ;;
    3) search_branch_and_deploy ;;
    4) 
      (echo "50"; sudo systemctl stop cups; sudo rm -rf /var/spool/cups/*; sudo systemctl start cups; echo "100") | zenity --progress --text "Cleaning..." --auto-close 2>/dev/null
      zenity --info --text "تم مسح الذاكرة المعلقة." 2>/dev/null
      ;;
    5) 
      STATUS=$(lpstat -p)
      JOBS=$(lpstat -o)
      zenity --info --title "Status" --text "<b>حالة الطابعات:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null
      ;;
  esac
done
