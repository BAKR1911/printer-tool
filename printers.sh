#!/bin/bash
# ===============================================================
# it_aman_printer_fix.sh
# Version: 11.2-focused
# Purpose: Branch-first UI with Search-filter; Network-only printer deploy + test
# ===============================================================
CURRENT_VERSION="11.2-focused"
TOOL_NAME="IT Aman - Printer Tool"
SYS_ICON="printer-error"

# Central DB (optional): ضع هنا repo/raw URL الخاص بك إن أردت
CENTRAL_DB_URL="https://raw.githubusercontent.com/BAKR1911/printer-tool/main/printers.list"
LOCAL_DB="/etc/it-aman/printers.list"
TMP_DB="/tmp/.printer_db"
DB_FILE=""

LOG_FILE="/var/log/it-aman.log"
REAL_USER=${SUDO_USER:-$(whoami)}

# Driver search dirs (يمكن تعديلها لتشير لمكان الدرايفرز عندك)
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" "/usr/share/cups/drv" )

# -------------------------
# Basic checks & logging
# -------------------------
ensure_root() {
  if [ "$EUID" -ne 0 ]; then
    zenity --error --title "Error" --text "مطلوب صلاحيات المدير. استخدم sudo.\nAdmin rights required." 2>/dev/null
    exit 1
  fi
}
_log(){ echo "$(date +'%F %T') - $1" >> "$LOG_FILE"; }

ensure_root
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 0644 "$LOG_FILE" 2>/dev/null || true

# -------------------------
# Fetch DB (try central then local)
# -------------------------
fetch_db() {
  rm -f "$TMP_DB" 2>/dev/null || true
  # try central if online
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    if curl -fsS --connect-timeout 5 "$CENTRAL_DB_URL" -o "$TMP_DB" 2>/dev/null; then
      if [ -s "$TMP_DB" ]; then DB_FILE="$TMP_DB"; _log "Fetched central DB"; return; fi
    fi
  fi
  # else use local
  if [ -f "$LOCAL_DB" ] && [ -s "$LOCAL_DB" ]; then
    DB_FILE="$LOCAL_DB"; _log "Using local DB: $LOCAL_DB"; return
  fi
  # fallback sample
  cat > /tmp/.printer_db_sample <<'EOF'
# Sample printers.list
# Format: Branch|PrinterLabel|Address|Type|Driver(optional)
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
  DB_FILE="/tmp/.printer_db_sample"
  _log "Created sample DB"
}

# -------------------------
# Normalize DB: trim, remove comments/empty
# Each line expected: Branch|Label|Address|Type|Driver(optional)
# -------------------------
normalize_db() {
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > /tmp/.printer_db_clean
  DB_FILE="/tmp/.printer_db_clean"
}

# Legacy support: if record has 3 fields Branch|IP|Model => convert to Branch|Model|IP|network
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
# Validate network printer (ping + port 9100)
# returns 0 ok, 1 ping fail, 2 port closed
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
# Find driver PPD (search directories, else ask admin)
# -------------------------
find_driver() {
  local hint="$1"
  for d in "${DRIVER_DIRS[@]}"; do
    [ -d "$d" ] || continue
    if [ -n "$hint" ]; then
      # try to match hint name inside files
      found=$(grep -ril --null -e "$hint" "$d" 2>/dev/null | tr '\0' '\n' | head -n1)
      if [ -n "$found" ]; then echo "$found"; return 0; fi
    fi
    # fallback first .ppd
    f=$(ls "$d"/*.ppd 2>/dev/null | head -n1)
    [ -n "$f" ] && { echo "$f"; return 0; }
  done
  # ask admin to choose
  driver_file=$(zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null)
  if [ -n "$driver_file" ]; then echo "$driver_file"; return 0; fi
  echo ""
  return 1
}

# -------------------------
# Deploy network printer (ONLY network)
# - Uses Label as display name (no user rename)
# - Creates safe CUPS name internally
# - Searches driver, lpadmin, set default, send quick test + open CUPS printer page
# -------------------------
deploy_network_printer() {
  local branch="$1"
  local label="$2"
  local addr="$3"
  local driver_hint="$4"

  # display name is label; internal safe name:
  local cups_name="ITA_${branch// /_}_${label// /_}"
  cups_name=$(echo "$cups_name" | tr -s '_')

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --title "Info" --text "الطابعة معرفة بالفعل: $label\nAlready exists." 2>/dev/null
    _log "skip-deploy: already exists $cups_name"
    return 0
  fi

  # Validate network
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
  if [ -n "$driver_file" ]; then
    lpadmin -p "$cups_name" -E -v "$uri" -P "$driver_file" 2>/dev/null || lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null
  else
    # try 'everywhere' or fallback raw
    lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null || lpadmin -p "$cups_name" -E -v "$uri" -m raw 2>/dev/null || true
  fi
  lpdefault -d "$cups_name" 2>/dev/null || true

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    zenity --info --title "Done" --text "تم تعريف الطابعة بنجاح: $label\nPrinter added." 2>/dev/null
    _log "deployed $cups_name -> $uri"
    # send simple test print (non-blocking) and open CUPS page
    if command -v lp >/dev/null; then
      echo -e "IT Aman Test Page\nPrinter: $label\nDate: $(date)" | lp -d "$cups_name" 2>/dev/null || true
    fi
    # open CUPS printer page for user
    if [ -n "$REAL_USER" ]; then
      # urlencode name
      PR_NAME_URL=$(python3 - <<PY
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
"$cups_name" 2>/dev/null)
      [ -z "$PR_NAME_URL" ] && PR_NAME_URL=$(echo "$cups_name" | sed 's/ /%20/g')
      sudo -u "$REAL_USER" xdg-open "http://localhost:631/printers/${PR_NAME_URL}" &>/dev/null || true
    fi
    zenity --info --title "Test Page" --text "تم إرسال اختبار وفتحت صفحة CUPS للطابعة. اضغط Print Test Page في الواجهة إن احتجت." 2>/dev/null
    return 0
  else
    zenity --error --title "Failed" --text "فشل تعريف الطابعة: $label\nAdd failed." 2>/dev/null
    _log "deploy-failed $cups_name"
    return 1
  fi
}

# -------------------------
# UI: Branch-first with Search/Filter (branch list appears first)
# - Show branches list plus top "Search / فلترة" entry
# - If user picks Search => show entry box and then filtered list (starts-with then contains)
# -------------------------
branch_list_ui() {
  # build branches unique
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u)
  tmp=$(mktemp)
  echo "Search / فلترة الفروع" > "$tmp"
  echo "$branches" >> "$tmp"
  SELECTED=$(cat "$tmp" | zenity --list --title "Branches - اختر فرع" --column "Branch or Search" --height=420 --width=420 2>/dev/null)
  rm -f "$tmp"
  [ -z "$SELECTED" ] && echo "" && return
  if [ "$SELECTED" == "Search / فلترة الفروع" ]; then
    SEARCH=$(zenity --entry --title "Search Branch - ابحث عن فرع" --text "اكتب حروف الفرع لتصفية (مثال: As):" --width=520 2>/dev/null)
    [ -z "$SEARCH" ] && echo "" && return
    # starts-with first
    starts=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u)
    contains=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u)
    LIST=""
    if [ -n "$starts" ]; then while read -r b; do LIST+="$b"$'\n'; done <<< "$starts"; fi
    if [ -n "$contains" ]; then while read -r b; do if ! echo "$LIST" | grep -qx "$b"; then LIST+="$b"$'\n'; fi; done <<< "$contains"; fi
    if [ -z "$LIST" ]; then zenity --info --text "لا توجد نتائج مطابقة. حاول كلمة أخرى." --width=380 2>/dev/null; echo "" && return; fi
    PICK=$(echo -n "$LIST" | sed '/^[[:space:]]*$/d' | zenity --list --title "اختر فرع" --column "Branch" --height=420 --width=420 2>/dev/null)
    echo "$PICK"
    return
  else
    echo "$SELECTED"
    return
  fi
}

# -------------------------
# Branch -> Printers -> Deploy flow
# -------------------------
search_branch_and_deploy() {
  while true; do
    branch=$(branch_list_ui)
    [ -z "$branch" ] && return
    # list printers for branch
    printers=$(awk -F'|' -v b="$branch" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b)) print $0 }' "$DB_FILE")
    if [ -z "$printers" ]; then
      zenity --info --text "لا توجد طابعات مسجلة لهذا الفرع." --width=380 2>/dev/null
      continue
    fi
    DISP=""
    while IFS= read -r line; do
      label=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
      typ=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
      DISP+="${label} | ${typ}"$'\n'
    done <<< "$printers"
    SEL=$(echo -n "$DISP" | sed '/^[[:space:]]*$/d' | zenity --list --title "طابعات الفرع - Printers of $branch" --text "اختر الطابعة (سيُستخدم الاسم كما هو):" --column "Label | Type" --width=720 --height=420 2>/dev/null)
    [ -z "$SEL" ] && continue
    sel_label=$(echo "$SEL" | awk -F'|' '{print $1}' | xargs)
    # find full record
    record=$(awk -F'|' -v b="$branch" -v l="$sel_label" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE")
    if [ -z "$record" ]; then
      zenity --error --text "سجل الطابعة غير موجود." --width=380 2>/dev/null
      _log "record-missing $branch | $sel_label"
      continue
    fi
    # parse
    addr=$(echo "$record" | awk -F'|' '{print $3}' | xargs)
    typ=$(echo "$record" | awk -F'|' '{print $4}' | xargs)
    driver_hint=$(echo "$record" | awk -F'|' '{print $5}' | xargs)
    # only network allowed: convert any non-network to network if address looks like IP/host
    if [ "$typ" != "network" ]; then
      # warn and attempt treating as network if addr looks like ip or hostname
      if echo "$addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|[A-Za-z0-9.-]+$'; then
        zenity --question --text "This printer is marked as '$typ'. Treat as network printer using address: $addr ?\nسيتم التعامل كطابعة شبكة." --ok-label "Yes/نعم" --cancel-label "No/لا" 2>/dev/null
        if [ $? -ne 0 ]; then continue; fi
      else
        zenity --error --text "الطابعة ليست موسومة كشبكة والعنوان غير صالح لمعالجتها كشبكة. تواصل مع الدعم." --width=480 2>/dev/null
        continue
      fi
    fi
    # confirm deploy
    if ! zenity --question --text "هل تريد تعريف الطابعة: $sel_label (فرع: $branch)؟\nالاسم سيُستخدم كما هو." --ok-label "نعم" --cancel-label "لا" 2>/dev/null; then
      continue
    fi
    deploy_network_printer "$branch" "$sel_label" "$addr" "$driver_hint"
    return
  done
}

# -------------------------
# Main init & loop
# -------------------------
fetch_db
normalize_db
normalize_legacy

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
      zenity --info --title "Paper Jam / خطوات إزالة الورق" --text "اتبع التعليمات بدقة.\nFollow the safety steps." --width=520 2>/dev/null
      sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null &
      ;;
    2)
      DIAG=$(mktemp)
      (
        echo "10"
        if ! systemctl is-active --quiet cups; then systemctl restart cups; echo "- restarted CUPS" >> "$DIAG"; fi
        echo "40"
        if [ -n "$(lpstat -o 2>/dev/null)" ]; then cancel -a 2>/dev/null; echo "- cleared stuck jobs" >> "$DIAG"; fi
        echo "70"
        disabled=$(lpstat -p 2>/dev/null | grep "disabled" | awk '{print $2}')
        if [ -n "$disabled" ]; then for p in $disabled; do cupsenable "$p"; cupsaccept "$p"; done; echo "- re-enabled printers" >> "$DIAG"; fi
        echo "100"
      ) | zenity --progress --title "$TOOL_NAME - Smart Fix" --text "Running..." --auto-close 2>/dev/null
      if [ -s "$DIAG" ]; then zenity --info --title "تقرير الإصلاح" --text "$(cat $DIAG)" --width=450 2>/dev/null; else zenity --info --title "تقرير الإصلاح" --text "النظام يعمل جيدًا." --width=450 2>/dev/null; fi
      rm -f "$DIAG"
      _log "smart-fix executed"
      ;;
    3) search_branch_and_deploy ;;
    4) (echo "50"; systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; echo "100") | zenity --progress --text "Cleaning spooler..." --auto-close 2>/dev/null; zenity --info --text "تم مسح الأوامر." --width=380 2>/dev/null; _log "spooler cleaned" ;;
    5) STATUS=$(lpstat -p 2>/dev/null); JOBS=$(lpstat -o 2>/dev/null); zenity --info --title "Status" --text "<b>الحالة العامة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null ;;
  esac
done
