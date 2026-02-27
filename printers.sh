#!/bin/bash
# ===============================================================
#  Script: it_aman_printer_fix.sh
#  Version: 11.1
#  Update: Treat USB as Network for thermal printers; show system test page
# ===============================================================
CURRENT_VERSION="11.1"
TOOL_NAME="IT Aman - Printer Tool v11.1"
SYS_ICON="printer-error"

CENTRAL_DB_URL="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.list"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

LOG_FILE="/var/log/it-aman.log"
REAL_USER=${SUDO_USER:-$(whoami)}

# safety
if [ "$EUID" -ne 0 ]; then
  zenity --error --title "Error" --text "مطلوب صلاحيات المدير. استخدم sudo." 2>/dev/null
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 0644 "$LOG_FILE" 2>/dev/null || true
log_event(){ echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

# fetch DB
fetch_db(){
  rm -f "$TMP_DB" 2>/dev/null || true
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    curl -fsS --connect-timeout 5 "$CENTRAL_DB_URL" -o "$TMP_DB" 2>/dev/null || true
    if [ -s "$TMP_DB" ]; then DB_FILE="$TMP_DB"; log_event "Fetched central DB"; return; fi
  fi
  if [ -f "$LOCAL_DB" ] && [ -s "$LOCAL_DB" ]; then DB_FILE="$LOCAL_DB"; log_event "Using local DB: $LOCAL_DB"; return; fi
  cat > /tmp/.printer_db_sample <<'EOF'
# Sample printers.list
# Format: Branch|PrinterLabel|Address|Type|Driver(optional)
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
  DB_FILE="/tmp/.printer_db_sample"
  log_event "Created sample DB"
}

# normalize db
normalize_db(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > /tmp/.printer_db_clean
  DB_FILE="/tmp/.printer_db_clean"
}

# legacy conversion
normalize_legacy(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    if (NF==3) { branch=$1; addr=$2; model=$3; gsub(/^[ \t]+|[ \t]+$/,"",branch); gsub(/^[ \t]+|[ \t]+$/,"",addr); gsub(/^[ \t]+|[ \t]+$/,"",model); print branch "|" model "|" addr "|network" } else { print $0 }
  }' "$DB_FILE" > /tmp/.printer_db_norm
  DB_FILE="/tmp/.printer_db_norm"
}

# validate network (ping + port)
validate_network(){
  TARGET="$1"
  if ! ping -c1 -W2 "$TARGET" &>/dev/null; then return 1; fi
  if command -v nc &>/dev/null; then
    if nc -z -w2 "$TARGET" 9100 &>/dev/null; then return 0; else return 2; fi
  fi
  return 0
}

# find driver PPD
find_driver(){
  DRIVER_HINT="$1"
  search_paths=( "/usr/share/cups/model" "/usr/share/ppd" "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/drv" )
  for d in "${search_paths[@]}"; do
    if [ -d "$d" ]; then
      if [ -n "$DRIVER_HINT" ]; then
        found=$(grep -ril --null -e "$DRIVER_HINT" "$d" 2>/dev/null | tr '\0' '\n' | head -n1)
        if [ -n "$found" ]; then echo "$found"; return 0; fi
      fi
      f=$(ls "$d"/*.ppd 2>/dev/null | head -n1)
      [ -n "$f" ] && { echo "$f"; return 0; }
    fi
  done
  driver_file=$(zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null)
  if [ -n "$driver_file" ]; then echo "$driver_file"; return 0; fi
  echo ""
  return 1
}

# deploy (USB removed as separate path; usb will be treated as network)
deploy_printer_from_record(){
  RECORD="$1"
  BRANCH=$(echo "$RECORD" | awk -F'|' '{print $1}' | xargs)
  LABEL=$(echo "$RECORD" | awk -F'|' '{print $2}' | xargs)
  ADDR=$(echo "$RECORD" | awk -F'|' '{print $3}' | xargs)
  TYPE=$(echo "$RECORD" | awk -F'|' '{print $4}' | xargs)
  DRIVER_HINT=$(echo "$RECORD" | awk -F'|' '{print $5}' | xargs)

  PR_NAME="${LABEL}"               # use exact label as printer name displayed to user (no edit)
  # sanitize PR_NAME for CUPS internal use (but keep display)
  CUPS_NAME="ITA_${BRANCH// /_}_${LABEL// /_}"
  CUPS_NAME=$(echo "$CUPS_NAME" | tr -s '_')

  if lpstat -p "$CUPS_NAME" >/dev/null 2>&1; then
    zenity --info --text "الطابعة معرفة بالفعل: $LABEL" --width=360 2>/dev/null
    log_event "Skip - already exists: $CUPS_NAME"
    return
  fi

  # If serial -> handle as serial (raw)
  if [[ "$TYPE" == "serial" ]]; then
    LP_URI="file:$ADDR"
    DRIVER_PATH=$(find_driver "$DRIVER_HINT")
    if [ -n "$DRIVER_PATH" ]; then
      lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -P "$DRIVER_PATH" 2>/dev/null || lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m "${DRIVER_HINT:-raw}" 2>/dev/null
    else
      lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m "${DRIVER_HINT:-raw}" 2>/dev/null || true
    fi
    lpdefault -d "$CUPS_NAME" 2>/dev/null || true
    if lpstat -p "$CUPS_NAME" >/dev/null 2>&1; then
      zenity --info --text "تم تعريف طابعة Serial: $LABEL" --width=420 2>/dev/null
      log_event "Serial added: $CUPS_NAME ($LP_URI)"
      run_test_and_open_cups "$CUPS_NAME" "$TYPE" "$ADDR"
    else
      zenity --error --text "فشل تعريف طابعة Serial: $LABEL" --width=420 2>/dev/null
      log_event "Serial add failed: $CUPS_NAME"
    fi
    return
  fi

  # For everything else (network OR previously usb) treat as network
  # Expect ADDR to be an IP or hostname
  validate_network "$ADDR"
  RES=$?
  if [ $RES -eq 1 ]; then
    zenity --error --text "تعذر الوصول للطابعة (Ping فشل): $ADDR\nتأكد من الشبكة" --width=420 2>/dev/null
    log_event "Ping failed for $CUPS_NAME ($ADDR)"
    return
  elif [ $RES -eq 2 ]; then
    zenity --warning --text "الطابعة ترد لكن منفذ 9100 مغلق: $ADDR\nستتم المحاولة مع تحذير" --width=480 2>/dev/null
    log_event "Port 9100 closed for $CUPS_NAME ($ADDR)"
  fi

  LP_URI="socket://$ADDR"
  DRIVER_PATH=$(find_driver "$DRIVER_HINT")
  if [ -n "$DRIVER_PATH" ]; then
    lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -P "$DRIVER_PATH" 2>/dev/null || lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null
  else
    lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null || true
  fi
  lpdefault -d "$CUPS_NAME" 2>/dev/null || true

  if lpstat -p "$CUPS_NAME" >/dev/null 2>&1; then
    zenity --info --text "تم تعريف الطابعة الشبكية بنجاح: $LABEL" --width=420 2>/dev/null
    log_event "Network added: $CUPS_NAME ($LP_URI)"
    run_test_and_open_cups "$CUPS_NAME" "network" "$ADDR"
  else
    zenity --error --text "فشل تعريف الطابعة الشبكية: $LABEL" --width=420 2>/dev/null
    log_event "Network add failed: $CUPS_NAME ($LP_URI)"
  fi
}

# run test print + open CUPS printer page for system "Print Test Page" UI
run_test_and_open_cups(){
  CUPS_NAME="$1"
  TYPE="$2"
  ADDR="$3"

  # First try to send a small test print via lp (non-blocking)
  if command -v lp >/dev/null; then
    echo -e "IT Aman Test Page\nPrinter: $CUPS_NAME\nDate: $(date)" | lp -d "$CUPS_NAME" 2>/dev/null || true
  fi

  # Open CUPS printer page in user's session so they can use the system test page UI
  # Try to open with the real user's desktop
  if [ -n "$REAL_USER" ]; then
    # build CUPS printer URL (escape spaces)
    PR_NAME_URL=$(python3 - <<PY
import sys,urllib.parse
name=sys.argv[1]
print(urllib.parse.quote(name))
PY
"$(echo "$CUPS_NAME")" 2>/dev/null)
    if [ -z "$PR_NAME_URL" ]; then PR_NAME_URL=$(echo "$CUPS_NAME" | sed 's/ /%20/g'); fi
    URL="http://localhost:631/printers/$PR_NAME_URL"
    sudo -u "$REAL_USER" xdg-open "$URL" &>/dev/null || true
  fi

  zenity --info --text "تم إرسال اختبار والطابعة متاحة في صفحة النظام (CUPS). يمكنك الضغط على Print Test Page من واجهة النظام." --width=520 2>/dev/null
  log_event "Opened CUPS page and sent test for $CUPS_NAME"
}

# Branch-first UI (branch list then printers)
branch_list_ui(){
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u)
  TMP_MENU=$(mktemp)
  echo "Search / فلترة الفروع" > "$TMP_MENU"
  echo "$branches" >> "$TMP_MENU"
  SELECTED=$(cat "$TMP_MENU" | zenity --list --title "Branches - اختر فرع" --column "Branch or Search" --height=420 --width=420 2>/dev/null)
  rm -f "$TMP_MENU"
  if [ -z "$SELECTED" ]; then echo ""; return; fi
  if [ "$SELECTED" == "Search / فلترة الفروع" ]; then
    SEARCH=$(zenity --entry --title "Search Branch - ابحث عن فرع" --text "اكتب حروف الفرع لتصفية القائمة (مثال: As):" --width=520 2>/dev/null)
    [ -z "$SEARCH" ] && echo "" && return
    starts=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u)
    contains=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u)
    LIST=""
    if [ -n "$starts" ]; then while read -r b; do LIST+="$b"$'\n'; done <<< "$starts"; fi
    if [ -n "$contains" ]; then while read -r b; do if ! echo "$LIST" | grep -qx "$b"; then LIST+="$b"$'\n'; fi; done <<< "$contains"; fi
    if [ -z "$LIST" ]; then zenity --info --text "لا توجد نتائج مطابقة. حاول كلمة أخرى." --width=380 2>/dev/null; echo ""; return; fi
    SELECTED_BRANCH=$(echo -n "$LIST" | sed '/^[[:space:]]*$/d' | zenity --list --title "اختر فرع" --column "Branch" --height=420 --width=420 2>/dev/null)
    echo "$SELECTED_BRANCH"
    return
  else
    echo "$SELECTED"
    return
  fi
}

search_branch_and_deploy(){
  while true; do
    BR=$(branch_list_ui)
    [ -z "$BR" ] && return
    PRS=$(awk -F'|' -v b="$BR" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b)) print $0 }' "$DB_FILE")
    if [ -z "$PRS" ]; then zenity --info --text "لا توجد طابعات مسجلة لهذا الفرع." --width=380 2>/dev/null; continue; fi
    DISP=""
    while IFS= read -r r; do
      label=$(echo "$r" | awk -F'|' '{print $2}' | xargs)
      typ=$(echo "$r" | awk -F'|' '{print $4}' | xargs)
      DISP+="${label} | ${typ}"$'\n'
    done <<< "$PRS"
    SEL=$(echo -n "$DISP" | sed '/^[[:space:]]*$/d' | zenity --list --title "طابعات الفرع - Printers of $BR" --text "اختر الطابعة (اسم الطابعة سيستخدم كما هو):" --column "Label | Type" --width=720 --height=420 2>/dev/null)
    [ -z "$SEL" ] && continue
    SEL_LABEL=$(echo "$SEL" | awk -F'|' '{print $1}' | xargs)
    RECORD=$(awk -F'|' -v b="$BR" -v l="$SEL_LABEL" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE")
    if [ -z "$RECORD" ]; then zenity --error --text "سجل الطابعة غير موجود في قاعدة البيانات." --width=380 2>/dev/null; log_event "Record missing for $BR | $SEL_LABEL"; continue; fi
    if ! zenity --question --text "هل تريد تعريف الطابعة: $SEL_LABEL (فرع: $BR)؟\n(الاسم سيُستخدم كما هو ولن يُسمح للمستخدم بتعديله)" --ok-label "نعم" --cancel-label "لا" 2>/dev/null; then continue; fi
    deploy_printer_from_record "$RECORD"
    return
  done
}

# init
fetch_db
normalize_db
normalize_legacy

# main menu (preserve layout)
while true; do
  CHOICE=$(zenity --list --title "$TOOL_NAME" --window-icon="$SYS_ICON" --text "قائمة الخدمات المتاحة:" \
    --radiolist --column "Select" --column "ID" --column "Option" \
    FALSE "1" "معالجة حشر الورق / Paper Jam Guide" \
    FALSE "2" "فحص النظام الذكي / Smart System Diagnostic" \
    FALSE "3" "تعريف طابعة (بحث فرع + تعريف) / Define Printer (Branch search)" \
    FALSE "4" "إصلاح أوامر الطباعة (مسح الذاكرة) / Quick Fix Spooler" \
    FALSE "5" "عرض الحالة العامة للطابعات / View Printer Status" \
    FALSE "6" "خروج / Exit" \
    --width=700 --height=480 2>/dev/null)
  [ -z "$CHOICE" ] && exit 0
  if [ "$CHOICE" == "6" ]; then exit 0; fi

  case "$CHOICE" in
    1)
      zenity --info --title "خطوات إزالة الورق / Paper Jam" --text "اتبع التعليمات بدقة.\n(Arabic + English help shown)" --width=520 2>/dev/null
      sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null &
      ;;
    2)
      DIAG_LOG=$(mktemp)
      (
        echo "10"
        if ! systemctl is-active --quiet cups; then systemctl restart cups; echo "- restarted CUPS" >> "$DIAG_LOG"; fi
        echo "40"
        if [ -n "$(lpstat -o 2>/dev/null)" ]; then cancel -a 2>/dev/null; echo "- cleared stuck jobs" >> "$DIAG_LOG"; fi
        echo "70"
        DISABLED=$(lpstat -p 2>/dev/null | grep "disabled" | awk '{print $2}')
        if [ -n "$DISABLED" ]; then for p in $DISABLED; do cupsenable "$p"; cupsaccept "$p"; done; echo "- re-enabled printers" >> "$DIAG_LOG"; fi
        echo "100"
      ) | zenity --progress --title "$TOOL_NAME - Smart Fix" --text "Running..." --auto-close 2>/dev/null
      if [ -s "$DIAG_LOG" ]; then zenity --info --title "تقرير الإصلاح" --text "$(cat $DIAG_LOG)" --width=450 2>/dev/null; else zenity --info --title "تقرير الإصلاح" --text "النظام يعمل جيدًا." --width=450 2>/dev/null; fi
      rm -f "$DIAG_LOG"
      log_event "Smart fix executed"
      ;;
    3)
      search_branch_and_deploy
      ;;
    4)
      (echo "50"; systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; echo "100") | zenity --progress --text "Cleaning spooler..." --auto-close 2>/dev/null
      zenity --info --text "تم مسح أوامر الطباعة المعلقة." --width=380 2>/dev/null
      log_event "Spooler cleaned"
      ;;
    5)
      STATUS=$(lpstat -p 2>/dev/null); JOBS=$(lpstat -o 2>/dev/null)
      zenity --info --title "حالة الطابعات" --text "<b>الحالة العامة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null
      ;;
  esac
done
