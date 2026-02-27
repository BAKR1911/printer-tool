#!/bin/bash
# ===============================================================
# it_aman_printer_fix.sh
# Version: 11.2 - Tools Strong (Branch-first, robust search, driver lookup)
# Purpose: Advanced printer support tool (Arabic/English UI preserved)
# ===============================================================
CURRENT_VERSION="11.2"
TOOL_NAME="IT Aman - Printer Tool v11.2"
SYS_ICON="printer-error"

# DB sources
CENTRAL_DB_URL="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.list"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

# logs & runtime
LOG_FILE="/var/log/it-aman.log"
REAL_USER=${SUDO_USER:-$(whoami)}
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" )

# Dependencies check
_requirements_check() {
  local miss=()
  for cmd in zenity lp lpadmin lpstat cancel cupsenable cupsaccept systemctl awk sed grep curl ping date xargs; do
    command -v $cmd >/dev/null 2>&1 || miss+=($cmd)
  done
  if [ ${#miss[@]} -ne 0 ]; then
    zenity --warning --title "Missing tools" --text "Missing: ${miss[*]}\nPlease install them (apt install ...) and re-run." 2>/dev/null
  fi
}

# Logging helper
_log(){ echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

# Ensure run as root
if [ "$EUID" -ne 0 ]; then
  zenity --error --title "Error" --text "مطلوب صلاحيات المدير. استخدم sudo." 2>/dev/null
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 0644 "$LOG_FILE" 2>/dev/null || true

_requirements_check

# -------------------------
# DB fetching & normalization
# -------------------------
_fetch_db() {
  rm -f "$TMP_DB" 2>/dev/null || true
  # try central
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    if curl -fsS --connect-timeout 5 "$CENTRAL_DB_URL" -o "$TMP_DB" 2>/dev/null; then
      if [ -s "$TMP_DB" ]; then DB_FILE="$TMP_DB"; _log "Fetched central DB"; return; fi
    fi
  fi
  # fallback local
  if [ -f "$LOCAL_DB" ] && [ -s "$LOCAL_DB" ]; then
    DB_FILE="$LOCAL_DB"; _log "Using local DB: $LOCAL_DB"; return
  fi
  # sample
  cat > /tmp/.printer_db_sample <<'EOF'
# Sample printers.list
# Format: Branch|PrinterLabel|Address|Type|Driver(optional)
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
  DB_FILE="/tmp/.printer_db_sample"; _log "Created sample DB"
}

_normalize_db() {
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > /tmp/.printer_db_clean
  DB_FILE="/tmp/.printer_db_clean"
}

# legacy convert Branch|IP|Model -> Branch|Model|IP|network
_normalize_legacy() {
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    if (NF==3) {
      branch=$1; addr=$2; model=$3;
      gsub(/^[ \t]+|[ \t]+$/,"",branch); gsub(/^[ \t]+|[ \t]+$/,"",addr); gsub(/^[ \t]+|[ \t]+$/,"",model);
      print branch "|" model "|" addr "|network"
    } else print $0
  }' "$DB_FILE" > /tmp/.printer_db_norm
  DB_FILE="/tmp/.printer_db_norm"
}

# -------------------------
# network validation
# -------------------------
_validate_network() {
  local tgt="$1"
  if ! ping -c1 -W2 "$tgt" &>/dev/null; then return 1; fi
  if command -v nc &>/dev/null; then
    if nc -z -w2 "$tgt" 9100 &>/dev/null; then return 0; else return 2; fi
  fi
  return 0
}

# -------------------------
# driver lookup
# -------------------------
_find_driver() {
  local hint="$1"
  # search driver dirs
  for d in "${DRIVER_DIRS[@]}"; do
    [ -d "$d" ] || continue
    if [ -n "$hint" ]; then
      local f=$(grep -ril --null -e "$hint" "$d" 2>/dev/null | tr '\0' '\n' | head -n1)
      [ -n "$f" ] && { echo "$f"; return 0; }
    fi
    local f2=$(ls "$d"/*.ppd 2>/dev/null | head -n1)
    [ -n "$f2" ] && { echo "$f2"; return 0; }
  done
  # interactive choice if not found
  local chosen=$(zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null)
  [ -n "$chosen" ] && { echo "$chosen"; return 0; }
  echo ""
  return 1
}

# -------------------------
# deploy printer (network-first; serial supported)
# -------------------------
_deploy_from_record() {
  local rec="$1"
  local BR=$(echo "$rec" | awk -F'|' '{print $1}' | xargs)
  local LABEL=$(echo "$rec" | awk -F'|' '{print $2}' | xargs)
  local ADDR=$(echo "$rec" | awk -F'|' '{print $3}' | xargs)
  local TYPE=$(echo "$rec" | awk -F'|' '{print $4}' | xargs)
  local DRIVER_HINT=$(echo "$rec" | awk -F'|' '{print $5}' | xargs)

  # Display name = exact Label (user cannot edit)
  local DISPLAY_NAME="$LABEL"
  # CUPS internal safe name
  local CUPS_NAME="ITA_${BR// /_}_${LABEL// /_}"
  CUPS_NAME=$(echo "$CUPS_NAME" | tr -s '_')

  if lpstat -p "$CUPS_NAME" >/dev/null 2>&1; then
    zenity --info --text "الطابعة معرفة بالفعل: $DISPLAY_NAME" --width=360 2>/dev/null
    _log "Skip already exists: $CUPS_NAME"
    return
  fi

  # If serial -> treat as serial (raw)
  if [[ "$TYPE" == "serial" ]]; then
    local LP_URI="file:$ADDR"
    local DRIVER_FILE=$(_find_driver "$DRIVER_HINT")
    if [ -n "$DRIVER_FILE" ]; then
      lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -P "$DRIVER_FILE" 2>/dev/null || lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m raw 2>/dev/null
    else
      lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m raw 2>/dev/null || true
    fi
    lpdefault -d "$CUPS_NAME" 2>/dev/null || true
    if lpstat -p "$CUPS_NAME" >/dev/null 2>&1; then
      zenity --info --text "تم تعريف طابعة Serial: $DISPLAY_NAME" --width=420 2>/dev/null
      _log "Serial added: $CUPS_NAME ($LP_URI)"
      _run_test_and_open_cups "$CUPS_NAME" "serial" "$ADDR"
    else
      zenity --error --text "فشل تعريف طابعة Serial: $DISPLAY_NAME" --width=420 2>/dev/null
      _log "Serial add failed: $CUPS_NAME"
    fi
    return
  fi

  # Treat usb as network for thermal flow per your instruction
  # Expect ADDR is IP/hostname; if not, warn admin
  _validate_network "$ADDR"
  local vres=$?
  if [ $vres -eq 1 ]; then
    zenity --error --text "تعذر الوصول للطابعة (Ping فشل): $ADDR\nتأكد من الشبكة" --width=420 2>/dev/null
    _log "Ping failed for $CUPS_NAME ($ADDR)"
    return
  elif [ $vres -eq 2 ]; then
    zenity --warning --text "الطابعة ترد لكن منفذ 9100 مغلق: $ADDR\nسيستمر الإجراء مع تحذير" --width=480 2>/dev/null
    _log "Port 9100 closed for $CUPS_NAME ($ADDR)"
  fi

  local LP_URI="socket://$ADDR"
  local DRIVER_FILE=$(_find_driver "$DRIVER_HINT")
  if [ -n "$DRIVER_FILE" ]; then
    lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -P "$DRIVER_FILE" 2>/dev/null || lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null
  else
    lpadmin -p "$CUPS_NAME" -E -v "$LP_URI" -m everywhere 2>/dev/null || true
  fi
  lpdefault -d "$CUPS_NAME" 2>/dev/null || true

  if lpstat -p "$CUPS_NAME" >/dev/null 2>&1; then
    zenity --info --text "تم تعريف الطابعة الشبكية بنجاح: $DISPLAY_NAME" --width=420 2>/dev/null
    _log "Network added: $CUPS_NAME ($LP_URI)"
    _run_test_and_open_cups "$CUPS_NAME" "network" "$ADDR"
  else
    zenity --error --text "فشل تعريف الطابعة الشبكية: $DISPLAY_NAME" --width=420 2>/dev/null
    _log "Network add failed: $CUPS_NAME ($LP_URI)"
  fi
}

# -------------------------
# Test print + open CUPS printer page (system Print Test Page)
# -------------------------
_run_test_and_open_cups() {
  local CUPS_NAME="$1"; local TYPE="$2"; local ADDR="$3"

  # send a small test print via lp if possible
  if command -v lp >/dev/null; then
    echo -e "IT Aman Test Page\nPrinter: $CUPS_NAME\nDate: $(date)" | lp -d "$CUPS_NAME" 2>/dev/null || true
  fi

  # open CUPS printers page for the user session so they can press Print Test Page
  if [ -n "$REAL_USER" ]; then
    # try to urlencode name
    local encoded=$(python3 - <<PY
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
"$CUPS_NAME" 2>/dev/null)
    [ -z "$encoded" ] && encoded=$(echo "$CUPS_NAME" | sed 's/ /%20/g')
    local url="http://localhost:631/printers/$encoded"
    sudo -u "$REAL_USER" xdg-open "$url" &>/dev/null || true
  fi

  zenity --info --text "تم إرسال اختبار (إذا أمكن) وفتحت صفحة النظام للطابعة. يمكنك الضغط على Print Test Page من واجهة CUPS." --width=560 2>/dev/null
  _log "Opened CUPS page and attempted test for $CUPS_NAME"
}

# -------------------------
# Branch-first search UI (improved)
# Emulates live filtering: user sees branches first, can choose Search item to type filter,
# then filtered list shows starts-with first then contains; user selects branch -> printers list
# -------------------------
_branch_list_ui() {
  # build unique branches
  local branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u)
  local tmp=$(mktemp)
  echo "Search / فلترة الفروع" > "$tmp"
  echo "$branches" >> "$tmp"
  local sel=$(cat "$tmp" | zenity --list --title "Branches - اختر فرع" --column "Branch or Search" --height=420 --width=420 2>/dev/null)
  rm -f "$tmp"
  if [ -z "$sel" ]; then echo ""; return; fi
  if [ "$sel" == "Search / فلترة الفروع" ]; then
    local search=$(zenity --entry --title "Search Branch - ابحث عن فرع" --text "اكتب حروف الفرع لتصفية القائمة (مثال: As):" --width=520 2>/dev/null)
    [ -z "$search" ] && echo "" && return
    # starts-with
    local starts=$(awk -F'|' -v s="$search" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u)
    local contains=$(awk -F'|' -v s="$search" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u)
    local LIST=""
    if [ -n "$starts" ]; then while read -r b; do LIST+="$b"$'\n'; done <<< "$starts"; fi
    if [ -n "$contains" ]; then while read -r b; do if ! echo "$LIST" | grep -qx "$b"; then LIST+="$b"$'\n'; fi; done <<< "$contains"; fi
    if [ -z "$LIST" ]; then zenity --info --text "لا توجد نتائج مطابقة. حاول كلمة أخرى." --width=380 2>/dev/null; echo ""; return; fi
    local picked=$(echo -n "$LIST" | sed '/^[[:space:]]*$/d' | zenity --list --title "اختر فرع" --column "Branch" --height=420 --width=420 2>/dev/null)
    echo "$picked"
    return
  else
    echo "$sel"
    return
  fi
}

_search_branch_and_deploy() {
  while true; do
    local BR=$(_branch_list_ui)
    [ -z "$BR" ] && return
    # list printers for branch
    local PRS=$(awk -F'|' -v b="$BR" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b)) print $0 }' "$DB_FILE")
    if [ -z "$PRS" ]; then zenity --info --text "لا توجد طابعات مسجلة لهذا الفرع." --width=380 2>/dev/null; continue; fi
    local DISP=""
    while IFS= read -r r; do
      local label=$(echo "$r" | awk -F'|' '{print $2}' | xargs)
      local typ=$(echo "$r" | awk -F'|' '{print $4}' | xargs)
      DISP+="${label} | ${typ}"$'\n'
    done <<< "$PRS"
    local selp=$(echo -n "$DISP" | sed '/^[[:space:]]*$/d' | zenity --list --title "طابعات الفرع - Printers of $BR" --text "اختر الطابعة (اسم الطابعة سيُستخدم كما هو):" --column "Label | Type" --width=720 --height=420 2>/dev/null)
    [ -z "$selp" ] && continue
    local SEL_LABEL=$(echo "$selp" | awk -F'|' '{print $1}' | xargs)
    local RECORD=$(awk -F'|' -v b="$BR" -v l="$SEL_LABEL" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE")
    if [ -z "$RECORD" ]; then zenity --error --text "سجل الطابعة غير موجود في قاعدة البيانات." --width=380 2>/dev/null; _log "Record missing for $BR | $SEL_LABEL"; continue; fi
    if ! zenity --question --text "هل تريد تعريف الطابعة: $SEL_LABEL (فرع: $BR)؟\n(الاسم سيُستخدم كما هو ولن يُسمح للمستخدم بتعديله)" --ok-label "نعم" --cancel-label "لا" 2>/dev/null; then continue; fi
    _deploy_from_record "$RECORD"
    return
  done
}

# -------------------------
# Smart Fix / Spooler / Status (original features kept)
# -------------------------
_smart_fix() {
  DIAG=$(mktemp)
  (
    echo "10"
    if ! systemctl is-active --quiet cups; then systemctl restart cups; echo "- restarted CUPS" >> "$DIAG"; fi
    echo "40"
    if [ -n "$(lpstat -o 2>/dev/null)" ]; then cancel -a 2>/dev/null; echo "- cleared stuck jobs" >> "$DIAG"; fi
    echo "70"
    local DIS=$(lpstat -p 2>/dev/null | grep "disabled" | awk '{print $2}')
    if [ -n "$DIS" ]; then for p in $DIS; do cupsenable "$p"; cupsaccept "$p"; done; echo "- re-enabled printers" >> "$DIAG"; fi
    echo "100"
  ) | zenity --progress --title "$TOOL_NAME - Smart Fix" --text "Running..." --auto-close 2>/dev/null
  if [ -s "$DIAG" ]; then zenity --info --title "تقرير الإصلاح" --text "$(cat $DIAG)" --width=450 2>/dev/null; else zenity --info --title "تقرير الإصلاح" --text "النظام يعمل جيدًا." --width=450 2>/dev/null; fi
  rm -f "$DIAG"
  _log "Smart fix executed"
}

_clean_spooler() {
  (echo "50"; systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; echo "100") | zenity --progress --text "Cleaning spooler..." --auto-close 2>/dev/null
  zenity --info --text "تم مسح أوامر الطباعة المعلقة." --width=380 2>/dev/null
  _log "Spooler cleaned"
}

_view_status() {
  local STATUS=$(lpstat -p 2>/dev/null); local JOBS=$(lpstat -o 2>/dev/null)
  zenity --info --title "حالة الطابعات" --text "<b>الحالة العامة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null
}

# -------------------------
# Init DB & main loop
# -------------------------
_fetch_db
_normalize_db
_normalize_legacy

while true; do
  CHOICE=$(zenity --list --title "$TOOL_NAME" --window-icon="$SYS_ICON" --text "قائمة الخدمات المتاحة:" \
    --radiolist --column "Select" --column "ID" --column "Option" \
    FALSE "1" "معالجة حشر الورق / Paper Jam Guide" \
    FALSE "2" "فحص النظام الذكي / Smart System Diagnostic" \
    FALSE "3" "تعريف طابعة (بحث فرع + تعريف) / Define Printer (Branch search)" \
    FALSE "4" "إصلاح أوامر الطباعة (مسح الذاكرة) / Quick Fix Spooler" \
    FALSE "5" "عرض الحالة العامة للطابعات / View Printer Status" \
    FALSE "6" "خروج / Exit" \
    --width=780 --height=520 2>/dev/null)
  [ -z "$CHOICE" ] && exit 0
  if [ "$CHOICE" == "6" ]; then exit 0; fi
  case "$CHOICE" in
    1)
      zenity --info --title "خطوات إزالة الورق / Paper Jam" --text "اتبع التعليمات بدقة.\n(Arabic + English help shown)" --width=520 2>/dev/null
      sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null &
      ;;
    2) _smart_fix ;;
    3) _search_branch_and_deploy ;;
    4) _clean_spooler ;;
    5) _view_status ;;
  esac
done
