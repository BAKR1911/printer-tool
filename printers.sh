#!/bin/bash
# ===============================================================
# it_aman_printer_fix.sh (v13.3 - THE ORIGINAL FULL CODE)
# ===============================================================

CURRENT_VERSION="13.3-FULL"
TOOL_NAME="IT Aman - Printer Tool"
SYS_ICON="printer-error"

# [1] تعريف الهوية والمسارات (لضمان عمل الـ Sudo الصامت)
REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
LOG_FILE="/var/log/it-aman.log"

# [2] روابط وقواعد البيانات
CENTRAL_DB_URL="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.list"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

# مسارات تعريفات الطابعات
DRIVER_DIRS=( 
    "/usr/local/share/it_aman/drivers" 
    "/opt/it_aman/drivers" 
    "/usr/share/cups/model" 
    "/usr/share/ppd" 
    "/usr/share/cups/drv" 
)

_log(){ echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

# -------------------------
# [3] دوال جلب البيانات وتنسيقها (بكامل قوتها الأصلية)
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
  # Fallback sample
  cat > /tmp/.printer_db_sample <<'EOF'
# Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
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

# -------------------------
# [4] دوال الشبكة والفحص (بكامل التفاصيل)
# -------------------------
validate_network() {
  local target="$1"
  if ! ping -c1 -W2 "$target" &>/dev/null; then return 1; fi
  if command -v nc &>/dev/null; then
    nc -z -w2 "$target" 9100 &>/dev/null || return 2
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
  # Fallback UI Selection
  driver_file=$(zenity --file-selection --title "Select driver PPD (اختيار يدوي)" 2>/dev/null)
  [ -n "$driver_file" ] && echo "$driver_file" || echo ""
}

# -------------------------
# [5] دالة تعريف الطابعة (Deploy) - معدلة بـ sudo داخلي فقط
# -------------------------
deploy_network_printer() {
  local branch="$1" label="$2" addr="$3" driver_hint="$4"
  local cups_name="ITA_${branch// /_}_${label// /_}"
  cups_name=$(echo "$cups_name" | tr -s '_')

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --title "Info" --text "الطابعة معرفة بالفعل: $label" 2>/dev/null
    return 0
  fi

  validate_network "$addr"
  local vres=$?
  if [ $vres -eq 1 ]; then
    zenity --error --text "تعذر الوصول للطابعة (Ping failed): $addr" 2>/dev/null
    return 1
  elif [ $vres -eq 2 ]; then
    zenity --warning --text "الطابعة ترد لكن منفذ 9100 مغلق: $addr" 2>/dev/null
  fi

  local driver_file=$(find_driver "$driver_hint")
  
  # تنفيذ الأوامر بـ sudo (الذي تم استثناؤه في Setup)
  if [ -n "$driver_file" ]; then
    sudo lpadmin -p "$cups_name" -E -v "socket://$addr" -P "$driver_file" 2>/dev/null || sudo lpadmin -p "$cups_name" -E -v "socket://$addr" -m everywhere 2>/dev/null
  else
    sudo lpadmin -p "$cups_name" -E -v "socket://$addr" -m everywhere 2>/dev/null || sudo lpadmin -p "$cups_name" -E -v "socket://$addr" -m raw 2>/dev/null
  fi
  sudo lpdefault -d "$cups_name" 2>/dev/null

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --text "تم تعريف $label بنجاح." 2>/dev/null
    _log "Successfully deployed $cups_name"
    # صفحة اختبار
    echo -e "IT Aman Test Page\nPrinter: $label\nBranch: $branch\nDate: $(date)" | lp -d "$cups_name" 2>/dev/null || true
  else
    zenity --error --text "فشل تعريف الطابعة." 2>/dev/null
  fi
}

# -------------------------
# [6] واجهات البحث والفروع (التفصيلية كاملة)
# -------------------------
branch_list_ui() {
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u)
  tmp=$(mktemp)
  echo "Search / فلترة الفروع" > "$tmp"
  echo "$branches" >> "$tmp"
  SELECTED=$(cat "$tmp" | zenity --list --title "Branches" --column "Branch" --height=420 --width=420 2>/dev/null)
  rm -f "$tmp"
  [ -z "$SELECTED" ] && echo "" && return
  
  if [ "$SELECTED" == "Search / فلترة الفروع" ]; then
    SEARCH=$(zenity --entry --title "Search" --text "اكتب حروف الفرع:" --width=520 2>/dev/null)
    [ -z "$SEARCH" ] && echo "" && return
    starts=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u)
    contains=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u)
    LIST=$(echo -e "$starts\n$contains" | sed '/^[[:space:]]*$/d')
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
    driver_hint=$(echo "$record" | awk -F'|' '{print $5}' | xargs)
    deploy_network_printer "$branch" "$sel_label" "$addr" "$driver_hint"
    return
  done
}

# -------------------------
# [7] القائمة الرئيسية وجميع الأدوات (Tools)
# -------------------------
fetch_db; normalize_db; normalize_legacy

while true; do
  CHOICE=$(zenity --list --title "$TOOL_NAME" --window-icon="$SYS_ICON" --text "قائمة الخدمات المتاحة (v$CURRENT_VERSION):" \
    --radiolist --column "Select" --column "ID" --column "Option" \
    FALSE "1" "معالجة حشر الورق / Paper Jam Guide" \
    FALSE "2" "فحص النظام الذكي / Smart System Diagnostic" \
    FALSE "3" "تعريف طابعة (بحث فرع + تعريف) / Define Printer" \
    FALSE "4" "إصلاح أوامر الطباعة (مسح الذاكرة) / Quick Fix Spooler" \
    FALSE "5" "عرض الحالة العامة للطابعات / View Status" \
    FALSE "6" "خروج / Exit" --width=780 --height=520 2>/dev/null)
  
  [ -z "$CHOICE" ] || [ "$CHOICE" == "6" ] && exit 0
  
  case "$CHOICE" in
    1) # دليل حشر الورق
       xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view" & ;;
    
    2) # فحص النظام وإعادة تشغيل الخدمة
       (
        echo "10"; sudo systemctl restart cups
        echo "50"; sudo cancel -a
        echo "80"; for p in $(lpstat -p | grep "disabled" | awk '{print $2}'); do sudo cupsenable "$p"; sudo cupsaccept "$p"; done
        echo "100"
       ) | zenity --progress --title "Smart Fix" --auto-close 2>/dev/null
       zenity --info --text "تم فحص وإصلاح خدمات الطباعة بنجاح." 2>/dev/null ;;
    
    3) # البحث والتعريف
       search_branch_and_deploy ;;
    
    4) # مسح Spooler
       (
        echo "20"; sudo systemctl stop cups
        echo "60"; sudo rm -rf /var/spool/cups/*
        echo "90"; sudo systemctl start cups
        echo "100"
       ) | zenity --progress --text "جاري مسح الذاكرة..." --auto-close 2>/dev/null
       zenity --info --text "تم مسح أوامر الطباعة العالقة." 2>/dev/null ;;
    
    5) # عرض الحالة
       STATUS=$(lpstat -p)
       JOBS=$(lpstat -o)
       zenity --info --title "Printer Status" --text "<b>حالة الطابعات:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null ;;
  esac
done
