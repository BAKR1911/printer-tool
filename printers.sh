#!/bin/bash
# ===============================================================
#  Script: it_aman_printer_fix.sh
#  Version: 11.1 - Final Merged (Enhanced)
#  Purpose: IT Aman - Printer support (original UI preserved + advanced features)
# ===============================================================
CURRENT_VERSION="11.1"
USER="BAKR1911"
REPO="printer-tool"
BRANCH="main"

# public raw URLs (no tokens stored)
VERSION_URL="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/version.txt"
SCRIPT_URL="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.sh"
DB_URL="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/printers.list"

LOG_FILE="/var/log/it-aman.log"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

REAL_USER=${SUDO_USER:-$(whoami)}
SYS_ICON="printer-error"
TOOL_NAME="IT Aman - Printer Tool v11.1"

# -------------------------
# safety / env
# -------------------------
if [ "$EUID" -ne 0 ]; then
  zenity --error --title "Error" --text "مطلوب صلاحيات المدير. استخدم sudo." 2>/dev/null
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 0644 "$LOG_FILE" 2>/dev/null || true
log_event(){ echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

# -------------------------
# Auto-update (public raw only; no token)
# -------------------------
auto_sync_system(){
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    REMOTE_V=$(curl -fsS --connect-timeout 5 "$VERSION_URL" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$REMOTE_V" && "$REMOTE_V" != "$CURRENT_VERSION" ]]; then
      tmpf=$(mktemp)
      if curl -fsS --connect-timeout 5 "$SCRIPT_URL" -o "$tmpf" 2>/dev/null; then
        chmod +x "$tmpf"
        mv "$tmpf" /usr/local/bin/it-aman
        log_event "Auto-updated to $REMOTE_V"
        exec /usr/local/bin/it-aman
      else
        rm -f "$tmpf" 2>/dev/null || true
        log_event "Auto-update failed"
      fi
    fi
  fi
}

# -------------------------
# Fetch DB with fallback
# -------------------------
fetch_db(){
  rm -f "$TMP_DB" 2>/dev/null || true
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    curl -fsS --connect-timeout 5 "$DB_URL" -o "$TMP_DB" 2>/dev/null || true
    if [ -s "$TMP_DB" ]; then DB_FILE="$TMP_DB"; log_event "Fetched central DB"; return; fi
  fi
  if [ -f "$LOCAL_DB" ] && [ -s "$LOCAL_DB" ]; then DB_FILE="$LOCAL_DB"; log_event "Using local DB: $LOCAL_DB"; return; fi
  # create small sample so UI won't break
  cat > /tmp/.printer_db_sample <<'EOF'
# Sample printers.list
# Format: Branch|PrinterLabel|Address|Type|Driver(optional)
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Aswan|POS Thermal 1|/dev/ttyUSB0|serial|tm-raw
Aswan|POS Thermal USB|USB_POS_01|usb|tm-raw
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
  DB_FILE="/tmp/.printer_db_sample"
  log_event "Created sample DB"
}

# -------------------------
# Normalize DB
# -------------------------
normalize_db(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > /tmp/.printer_db_clean
  DB_FILE="/tmp/.printer_db_clean"
}

# -------------------------
# Legacy support: Branch|IP|Model -> Branch|Model|IP|network
# -------------------------
normalize_legacy(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    if (NF==3) {
      branch=$1; addr=$2; model=$3;
      gsub(/^[ \t]+|[ \t]+$/,"",branch); gsub(/^[ \t]+|[ \t]+$/,"",addr); gsub(/^[ \t]+|[ \t]+$/,"",model);
      print branch "|" model "|" addr "|network"
    } else { print $0 }
  }' "$DB_FILE" > /tmp/.printer_db_norm
  DB_FILE="/tmp/.printer_db_norm"
}

# -------------------------
# Validate network printer: ping + port 9100
# return: 0 ok, 1 ping failed, 2 port closed
# -------------------------
validate_network(){
  TARGET="$1"
  if ! ping -c1 -W2 "$TARGET" &>/dev/null; then return 1; fi
  if command -v nc &>/dev/null; then
    if nc -z -w2 "$TARGET" 9100 &>/dev/null; then return 0; else return 2; fi
  fi
  return 0
}

# -------------------------
# Find driver: search common locations, else prompt file chooser
# -------------------------
find_driver(){
  DRIVER_NAME="$1"   # optional friendly name
  # common driver locations
  for d in /usr/share/cups/model /usr/share/ppd /usr/local/share/it_aman/drivers /opt/it_aman/drivers; do
    if [ -d "$d" ]; then
      found=$(grep -ril --null -e "$DRIVER_NAME" "$d" 2>/dev/null | tr '\0' '\n' | head -n1)
      if [ -n "$found" ]; then echo "$found"; return 0; fi
      # fallback to any ppd
      found2=$(ls "$d"/*.ppd 2>/dev/null | head -n1)
      if [ -n "$found2" ]; then echo "$found2"; return 0; fi
    fi
  done
  # ask admin to choose file (friendly)
  driver_file=$(zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null)
  if [ -n "$driver_file" ]; then echo "$driver_file"; return 0; fi
  # no driver
  echo ""
  return 1
}

# -------------------------
# Deploy printer from record
# -------------------------
deploy_printer_from_record(){
  RECORD="$1"
  BRANCH=$(echo "$RECORD" | awk -F'|' '{print $1}' | xargs)
  LABEL=$(echo "$RECORD" | awk -F'|' '{print $2}' | xargs)
  ADDR=$(echo "$RECORD" | awk -F'|' '{print $3}' | xargs)
  TYPE=$(echo "$RECORD" | awk -F'|' '{print $4}' | xargs)
  DRIVER_HINT=$(echo "$RECORD" | awk -F'|' '{print $5}' | xargs)

  PR_NAME="ITA_${BRANCH// /_}_${LABEL// /_}"
  PR_NAME=$(echo "$PR_NAME" | tr -s '_')

  if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
    zenity --info --text "الطابعة معرفة بالفعل: $PR_NAME" 2>/dev/null
    log_event "Skip - already exists: $PR_NAME"
    return
  fi

  if [[ "$TYPE" == "usb" ]]; then
    if [[ "$ADDR" =~ ^/dev/ ]]; then LP_URI="file:$ADDR"; else LP_URI="usb://$ADDR"; fi
    DRIVER_PATH=$(find_driver "$DRIVER_HINT")
    if [ -n "$DRIVER_PATH" ]; then
      lpadmin -p "$PR_NAME" -E -v "$LP_URI" -P "$DRIVER_PATH" 2>/dev/null || lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER_HINT:-raw}" 2>/dev/null
    else
      lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER_HINT:-raw}" 2>/dev/null || true
    fi
    lpdefault -d "$PR_NAME" 2>/dev/null || true
    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
      zenity --info --text "تم تعريف طابعة USB: $LABEL" 2>/dev/null
      log_event "USB added: $PR_NAME ($LP_URI)"
      run_test_print "$PR_NAME" "$TYPE" "$ADDR"
    else
      zenity --error --text "فشل تعريف طابعة USB: $LABEL" 2>/dev/null
      log_event "USB add failed: $PR_NAME"
    fi
    return
  fi

  if [[ "$TYPE" == "serial" ]]; then
    LP_URI="file:$ADDR"
    DRIVER_PATH=$(find_driver "$DRIVER_HINT")
    if [ -n "$DRIVER_PATH" ]; then
      lpadmin -p "$PR_NAME" -E -v "$LP_URI" -P "$DRIVER_PATH" 2>/dev/null || lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER_HINT:-raw}" 2>/dev/null
    else
      lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m "${DRIVER_HINT:-raw}" 2>/dev/null || true
    fi
    lpdefault -d "$PR_NAME" 2>/dev/null || true
    if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
      zenity --info --text "تم تعريف طابعة Serial: $LABEL" 2>/dev/null
      log_event "Serial added: $PR_NAME ($LP_URI)"
      run_test_print "$PR_NAME" "$TYPE" "$ADDR"
    else
      zenity --error --text "فشل تعريف طابعة Serial: $LABEL" 2>/dev/null
      log_event "Serial add failed: $PR_NAME"
    fi
    return
  fi

  # network
  validate_network "$ADDR"
  RES=$?
  if [ $RES -eq 1 ]; then
    zenity --error --text "تعذر الوصول للطابعة (Ping فشل). تحقق من الشبكة." 2>/dev/null
    log_event "Ping failed for $PR_NAME ($ADDR)"
    return
  elif [ $RES -eq 2 ]; then
    zenity --warning --text "الطابعة ترد لكن منفذ 9100 مغلق — قد لا تعمل الطباعة." 2>/dev/null
    log_event "Port 9100 closed for $PR_NAME ($ADDR)"
    # we continue but warn
  fi

  LP_URI="socket://$ADDR"
  DRIVER_PATH=$(find_driver "$DRIVER_HINT")
  if [ -n "$DRIVER_PATH" ]; then
    lpadmin -p "$PR_NAME" -E -v "$LP_URI" -P "$DRIVER_PATH" 2>/dev/null || lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null
  else
    lpadmin -p "$PR_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null || true
  fi
  lpdefault -d "$PR_NAME" 2>/dev/null || true

  if lpstat -p "$PR_NAME" >/dev/null 2>&1; then
    zenity --info --text "تم تعريف الطابعة الشبكية بنجاح: $LABEL" 2>/dev/null
    log_event "Network added: $PR_NAME ($LP_URI)"
    run_test_print "$PR_NAME" "network" "$ADDR"
  else
    zenity --error --text "فشل تعريف الطابعة الشبكية: $LABEL" 2>/dev/null
    log_event "Network add failed: $PR_NAME ($LP_URI)"
  fi
}

# -------------------------
# Run test print (Zorin-style test / fallback)
# -------------------------
run_test_print(){
  PR_NAME="$1"; TYPE="$2"; ADDR="$3"
  # If network or general cups printer -> use lp test print
  if [[ "$TYPE" == "network" || "$TYPE" == "usb" ]]; then
    # attempt to print CUPS testpage if available
    if [ -f /usr/share/cups/data/testprint ]; then
      echo "IT Aman Test Page - $(date)" | lp -d "$PR_NAME" 2>/dev/null
    else
      echo -e "IT Aman Test Page\nPrinter: $PR_NAME\nDate: $(date)" | lp -d "$PR_NAME" 2>/dev/null
    fi
    zenity --info --text "تم إرسال صفحة اختبار إلى: $PR_NAME" 2>/dev/null
    log_event "Test page sent to $PR_NAME"
    return
  fi

  if [[ "$TYPE" == "serial" || "$TYPE" == "usb" ]]; then
    # direct raw write for thermal (best-effort; requires permission)
    if [[ "$ADDR" =~ ^/dev/ ]]; then
      if [ -w "$ADDR" ]; then
        echo -e "IT AMAN RAW TEST\n\n\n" > "$ADDR" 2>/dev/null && zenity --info --text "تم إرسال اختبار RAW إلى $ADDR" 2>/dev/null
        log_event "Raw test sent to device $ADDR"
      else
        zenity --warning --text "لا توجد صلاحية لكتابة الجهاز $ADDR. تأكد من صلاحيات /dev." 2>/dev/null
        log_event "No permission for raw test to $ADDR"
      fi
    else
      # unknown device string (usb://...), fallback to lp
      echo -e "IT Aman Test Page\nPrinter: $PR_NAME" | lp -d "$PR_NAME" 2>/dev/null
      zenity --info --text "تم إرسال صفحة اختبار (fallback) إلى: $PR_NAME" 2>/dev/null
      log_event "Fallback test sent to $PR_NAME"
    fi
  fi
}

# -------------------------
# Search UI: branch-first flow (user requested)
#  - user types search term
#  - we show branch list filtered (starts-with prioritized)
#  - user picks branch -> we show printers for branch -> user picks printer -> deploy
# -------------------------
search_branch_and_deploy(){
  local search=""
  while true; do
    search=$(zenity --entry --title "بحث عن فرع - Search Branch" --text "اكتب حروف الفرع لتصفية القائمة (مثال: As):" --entry-text "$search" --width=520 2>/dev/null)
    [ -z "$search" ] && return
    # Build starts-with then contains list
    starts=$(awk -F'|' -v s="$search" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u)
    contains=$(awk -F'|' -v s="$search" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u)
    LIST=""
    if [ -n "$starts" ]; then
      while read -r b; do LIST+="$b"$'\n'; done <<< "$starts"
    fi
    if [ -n "$contains" ]; then
      while read -r b; do
        if ! echo "$LIST" | grep -qx "$b"; then LIST+="$b"$'\n'; fi
      done <<< "$contains"
    fi
    if [ -z "$LIST" ]; then
      zenity --info --text "لا توجد نتائج مطابقة. جرب كلمة أخرى." --width=380 2>/dev/null
      continue
    fi
    SELECTED_BRANCH=$(echo -n "$LIST" | sed '/^[[:space:]]*$/d' | zenity --list --title "اختر فرع - Select Branch" --column "Branch" --width=420 --height=350 2>/dev/null)
    [ -z "$SELECTED_BRANCH" ] && continue

    # show printers for that branch
    PRS=$(awk -F'|' -v b="$SELECTED_BRANCH" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b)) print $0 }' "$DB_FILE")
    if [ -z "$PRS" ]; then
      zenity --info --text "لا توجد طابعات مسجلة لهذا الفرع." --width=380 2>/dev/null
      continue
    fi
    # build display list: Label | Type
    DISP=""
    while IFS= read -r r; do
      label=$(echo "$r" | awk -F'|' '{print $2}' | xargs)
      typ=$(echo "$r" | awk -F'|' '{print $4}' | xargs)
      DISP+="${label} | ${typ}"$'\n'
    done <<< "$PRS"

    SEL=$(echo -n "$DISP" | sed '/^[[:space:]]*$/d' | zenity --list --title "طابعات الفرع - Printers" --text "اختر الطابعة:" --column "Label | Type" --width=700 --height=420 2>/dev/null)
    [ -z "$SEL" ] && continue
    # parse selected label (before ' | ')
    SEL_LABEL=$(echo "$SEL" | awk -F'|' '{print $1}' | xargs)
    # get full record
    RECORD=$(awk -F'|' -v b="$SELECTED_BRANCH" -v l="$SEL_LABEL" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE")
    if [ -z "$RECORD" ]; then
      zenity --error --text "سجل الطابعة غير موجود في قاعدة البيانات." --width=380 2>/dev/null
      log_event "Record missing for $SELECTED_BRANCH | $SEL_LABEL"
      continue
    fi

    # confirm deploy
    if ! zenity --question --text "هل تريد تعريف الطابعة: $SEL_LABEL (فرع: $SELECTED_BRANCH)؟" --ok-label "نعم" --cancel-label "لا" 2>/dev/null; then
      continue
    fi

    deploy_printer_from_record "$RECORD"
    return
  done
}

# -------------------------
# Smart fix (legacy)
# -------------------------
smart_fix_engine(){
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
}

clean_spooler(){
  (echo "50"; systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; echo "100") | zenity --progress --text "Cleaning spooler..." --auto-close 2>/dev/null
  zenity --info --text "تم مسح أوامر الطباعة المعلقة." --width=380 2>/dev/null
  log_event "Spooler cleaned"
}

status_view(){
  STATUS=$(lpstat -p 2>/dev/null)
  JOBS=$(lpstat -o 2>/dev/null)
  zenity --info --title "حالة الطابعات" --text "<b>الحالة العامة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null
}

# -------------------------
# init
# -------------------------
auto_sync_system
fetch_db
normalize_db
normalize_legacy

# Preserve original menu strings (Arabic + English side-by-side)
if zenity --question --text "اختيار اللغة؟ / Choose language?\nنعم = العربية (Arabic) ; لا = English" --ok-label "العربية" --cancel-label "English" 2>/dev/null; then
  # arabic selected: keep original TXT variables (reuse previous wording)
  :
fi

# Original menu flow (keeps your layout)
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
      zenity --info --title "خطوات إزالة الورق / Paper Jam" --text "⚠️ اتبع التعليمات بدقة.\n(Arabic + English help shown)" --width=520 2>/dev/null
      sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null &
      ;;
    2)
      smart_fix_engine
      ;;
    3)
      search_branch_and_deploy
      ;;
    4)
      clean_spooler
      ;;
    5)
      status_view
      ;;
  esac
done
