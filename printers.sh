#!/bin/bash
# ===============================================================
# printers.sh - IT Aman / Printer Tool
# Version: 11.3
# Purpose: Branch-first UI, network-only deploy, self-update, desktop shortcut
# Author: (assembled per request)
# ===============================================================
set -euo pipefail

# -----------------------
# Config - عدّل هنا لو احتجت
# -----------------------
CURRENT_VERSION="11.3"
REPO_RAW="https://raw.githubusercontent.com/BAKR1911/printer-tool/main"
LOG_FILE="/var/log/printer-tool.log"
DESKTOP_FILENAME="printer-tool.desktop"
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" "/usr/share/cups/drv" )
# -----------------------

# Helpers
_info(){ echo "[INFO] $*"; printf '%s - %s\n' "$(date +'%F %T')" "[INFO] $*" >> "$LOG_FILE" 2>/dev/null || true; }
_warn(){ echo "[WARN] $*"; printf '%s - %s\n' "$(date +'%F %T')" "[WARN] $*" >> "$LOG_FILE" 2>/dev/null || true; }
_err(){ echo "[ERROR] $*" >&2; printf '%s - %s\n' "$(date +'%F %T')" "[ERROR] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# Ensure log file exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

# Determine script location (works even if run via symlink or from PATH)
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
INSTALL_DIR="$SCRIPT_DIR"    # canonical local install dir unless overridden by wrapper

# Determine interactive user
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "$HOME")"

# Detect Desktop directory (XDG aware, supports Arabic)
detect_desktop_dir(){
  if [ -f "$USER_HOME/.config/user-dirs.dirs" ]; then
    xdg_desktop=$(grep XDG_DESKTOP_DIR "$USER_HOME/.config/user-dirs.dirs" | cut -d= -f2- | tr -d '"' | sed 's|\$HOME|'"$USER_HOME"'|g')
    if [ -n "$xdg_desktop" ] && [ -d "$xdg_desktop" ]; then
      echo "$xdg_desktop" && return
    fi
  fi
  if [ -d "$USER_HOME/Desktop" ]; then echo "$USER_HOME/Desktop" && return; fi
  if [ -d "$USER_HOME/سطح المكتب" ]; then echo "$USER_HOME/سطح المكتب" && return; fi
  mkdir -p "$USER_HOME/Desktop" 2>/dev/null || true
  echo "$USER_HOME/Desktop"
}
DESKTOP_DIR="$(detect_desktop_dir)"
DESKTOP_PATH="$DESKTOP_DIR/$DESKTOP_FILENAME"

# Create or update desktop shortcut idempotently
ensure_desktop_shortcut(){
  [ -n "$DESKTOP_DIR" ] || return 0
  ICON_PATH="$INSTALL_DIR/printer.png"
  [ -f "$ICON_PATH" ] || ICON_PATH="printer"

  # Exec should point to the script path so that the desktop launches that exact file
  # Use pkexec wrapper via a small wrapper in-place if needed; here Exec uses pkexec with env
  # But to keep it simple, Exec runs the script directly (user's DE will prompt for auth if needed)
  cat > "$DESKTOP_PATH.tmp" <<EOF
[Desktop Entry]
Name=Printer Tool
Comment=IT Printer Management Tool
Exec=env DISPLAY=\$DISPLAY XAUTHORITY=\$XAUTHORITY "$SCRIPT_PATH"
Icon=$ICON_PATH
Terminal=false
Type=Application
Categories=Utility;
EOF

  mv -f "$DESKTOP_PATH.tmp" "$DESKTOP_PATH"
  chown "$REAL_USER:$REAL_USER" "$DESKTOP_PATH" 2>/dev/null || true
  chmod +x "$DESKTOP_PATH" 2>/dev/null || true

  # For GNOME/Ubuntu mark trusted (best-effort)
  sudo -u "$REAL_USER" gio set "$DESKTOP_PATH" "metadata::trusted" true 2>/dev/null || true

  _info "Desktop shortcut ensured at: $DESKTOP_PATH"
}

# Version utilities
version_gt(){
  # returns true if $1 > $2
  if command -v sort >/dev/null 2>&1; then
    maj=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)
    [ "$maj" = "$1" ] && [ "$1" != "$2" ]
    return
  fi
  [ "$1" != "$2" ] && [ "$1" \> "$2" ]
  return
}

get_remote_version(){
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 5 "$REPO_RAW/version.txt" 2>/dev/null | tr -d '[:space:]'
  else
    echo ""
  fi
}

# Self-update routine (safe)
self_update(){
  REMOTE_V="$(get_remote_version)"
  [ -z "$REMOTE_V" ] && return 1
  if version_gt "$REMOTE_V" "$CURRENT_VERSION"; then
    DO_UPDATE=0
    if [ "${AUTO_UPDATE:-0}" -eq 1 ]; then
      DO_UPDATE=1
    else
      if command -v zenity >/dev/null 2>&1; then
        if sudo -u "$REAL_USER" zenity --question --title "Update available" --text "New version $REMOTE_V is available. Update now?" 2>/dev/null; then
          DO_UPDATE=1
        fi
      else
        # CLI fallback: ask in terminal if interactive
        if [ -t 1 ]; then
          read -p "New version $REMOTE_V available. Update now? [y/N]: " ans
          case "$ans" in [Yy]*) DO_UPDATE=1 ;; esac
        fi
      fi
    fi

    if [ "$DO_UPDATE" -eq 1 ]; then
      TMP_NEW="$(mktemp)"
      if curl -fsS --connect-timeout 10 "$REPO_RAW/printers.sh" -o "$TMP_NEW"; then
        cp -f "$SCRIPT_PATH" "${SCRIPT_PATH}.bak" 2>/dev/null || true
        chmod +x "$TMP_NEW"
        mv -f "$TMP_NEW" "$SCRIPT_PATH"
        chown root:root "$SCRIPT_PATH" 2>/dev/null || true
        _info "Updated to $REMOTE_V ; restarting new script..."
        exec "$SCRIPT_PATH" "$@"
      else
        _err "Failed to download update."
        [ -f "$TMP_NEW" ] && rm -f "$TMP_NEW"
        return 2
      fi
    fi
  fi
  return 0
}

# Background non-blocking update check (so UI not delayed)
trigger_background_update_check(){
  if command -v curl >/dev/null 2>&1 && ping -c1 -W2 8.8.8.8 &>/dev/null; then
    ( self_update "$@" ) & disown
  fi
}

# -------------------------
# Dependencies check (soft)
# -------------------------
check_requirements(){
  local miss=()
  for cmd in zenity lp lpadmin lpstat cancel cupsenable cupsaccept systemctl awk sed grep curl ping date xargs; do
    command -v $cmd >/dev/null 2>&1 || miss+=($cmd)
  done
  if [ ${#miss[@]} -ne 0 ]; then
    _warn "Missing commands: ${miss[*]} . Some features may not work."
  fi
}
check_requirements

# Ensure desktop shortcut exists (idempotent)
ensure_desktop_shortcut

# Run background update check
trigger_background_update_check

# -------------------------
# DB handling
# -------------------------
TMP_DB="/tmp/.printer_db.$$"
DB_FILE="$INSTALL_DIR/printers.list"

fetch_db(){
  rm -f "$TMP_DB" 2>/dev/null || true
  if ping -c1 -W2 8.8.8.8 &>/dev/null && command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 5 "$REPO_RAW/printers.list" -o "$TMP_DB" 2>/dev/null || true
    if [ -s "$TMP_DB" ]; then
      DB_FILE="$TMP_DB"
      _info "Fetched central printers.list"
      return 0
    fi
  fi
  # fallback: use local bundled printers.list if exists, else the INSTALL_DIR copy (i.e., repo file)
  if [ -f "$INSTALL_DIR/printers.list" ] && [ -s "$INSTALL_DIR/printers.list" ]; then
    DB_FILE="$INSTALL_DIR/printers.list"
    _info "Using local printers.list in script folder"
    return 0
  fi
  # else create sample DB in tmp
  cat > "$TMP_DB" <<'EOF'
# Sample printers.list
# Format: Branch|PrinterLabel|Address|Type|Driver(optional)
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
  DB_FILE="$TMP_DB"
  _info "Created sample DB"
  return 0
}

normalize_db(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > /tmp/.printer_db_clean.$$ 2>/dev/null || cp "$DB_FILE" /tmp/.printer_db_clean.$$ 2>/dev/null || true
  DB_FILE="/tmp/.printer_db_clean.$$"
}

# -------------------------
# Network validation
# -------------------------
validate_network(){
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
# Driver lookup
# -------------------------
find_driver(){
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
  # ask admin to pick
  if command -v zenity >/dev/null 2>&1; then
    driver_file=$(sudo -u "$REAL_USER" zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null || true)
    [ -n "$driver_file" ] && { echo "$driver_file"; return 0; }
  fi
  echo ""
  return 1
}

# -------------------------
# Deploy / Add network printer
# -------------------------
deploy_network_printer(){
  local branch="$1"
  local label="$2"
  local addr="$3"
  local driver_hint="$4"

  local cups_name="ITA_${branch// /_}_${label// /_}"
  cups_name=$(echo "$cups_name" | tr -s '_')

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    sudo -u "$REAL_USER" zenity --info --title "Info" --text "الطابعة معرفة بالفعل: $label" 2>/dev/null || echo "Printer already exists: $label"
    _info "skip deploy: $cups_name exists"
    return 0
  fi

  validate_network "$addr"
  local vres=$?
  if [ $vres -eq 1 ]; then
    sudo -u "$REAL_USER" zenity --error --title "Network Error" --text "تعذر الوصول للطابعة (Ping failed): $addr\nPlease check network/cable." 2>/dev/null || _err "Ping failed for $addr"
    _log="ping-fail $addr"
    return 1
  elif [ $vres -eq 2 ]; then
    sudo -u "$REAL_USER" zenity --warning --title "Port Warning" --text "الطابعة ترد لكن منفذ 9100 مغلق: $addr\nWill attempt to add with warning." 2>/dev/null || _warn "Port closed"
  fi

  local uri="socket://${addr}"
  local driver_file
  driver_file=$(find_driver "$driver_hint" || echo "")

  if [ -n "$driver_file" ]; then
    lpadmin -p "$cups_name" -E -v "$uri" -P "$driver_file" 2>/dev/null || lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null || true
  else
    lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>/dev/null || lpadmin -p "$cups_name" -E -v "$uri" -m raw 2>/dev/null || true
  fi

  lpdefault -d "$cups_name" 2>/dev/null || true

  if lpstat -p "$cups_name" >/dev/null 2>&1; then
    sudo -u "$REAL_USER" zenity --info --title "Done" --text "تم تعريف الطابعة بنجاح: $label" 2>/dev/null || echo "Added $label"
    _info "deployed $cups_name -> $uri"
    run_test_and_open_cups "$cups_name" "$addr"
    return 0
  else
    sudo -u "$REAL_USER" zenity --error --title "Failed" --text "فشل تعريف الطابعة: $label" 2>/dev/null || echo "Add failed: $label"
    _err "deploy failed $cups_name"
    return 1
  fi
}

# -------------------------
# Test print + open CUPS page
# -------------------------
run_test_and_open_cups(){
  local cups_name="$1"
  local addr="$2"
  if command -v lp >/dev/null 2>&1; then
    echo -e "IT Aman Test Page\nPrinter: $cups_name\nDate: $(date)" | lp -d "$cups_name" 2>/dev/null || true
  fi

  # open printer page for user
  if [ -n "$REAL_USER" ]; then
    PR_NAME_URL=$(python3 - <<PY
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
"$cups_name" 2>/dev/null || echo "")
    [ -z "$PR_NAME_URL" ] && PR_NAME_URL=$(echo "$cups_name" | sed 's/ /%20/g')
    sudo -u "$REAL_USER" xdg-open "http://localhost:631/printers/${PR_NAME_URL}" &>/dev/null || true
  fi

  sudo -u "$REAL_USER" zenity --info --title "Test Page" --text "تم إرسال اختبار وفتحت صفحة CUPS للطابعة. اضغط Print Test Page في الواجهة إن احتجت." 2>/dev/null || true
  _info "Test sent & opened CUPS page for $cups_name"
}

# -------------------------
# UI: Branch-first then search/filter (starts-with then contains)
# -------------------------
branch_list_ui(){
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u)
  tmp=$(mktemp)
  echo "Search / فلترة الفروع" > "$tmp"
  echo "$branches" >> "$tmp"
  SELECTED=$(cat "$tmp" | sudo -u "$REAL_USER" zenity --list --title "Branches - اختر فرع" --column "Branch or Search" --height=420 --width=420 2>/dev/null || true)
  rm -f "$tmp"
  [ -z "$SELECTED" ] && echo "" && return
  if [ "$SELECTED" == "Search / فلترة الفروع" ]; then
    SEARCH=$(sudo -u "$REAL_USER" zenity --entry --title "Search Branch - ابحث عن فرع" --text "اكتب حروف الفرع لتصفية (مثال: As):" --width=520 2>/dev/null || true)
    [ -z "$SEARCH" ] && echo "" && return
    starts=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u)
    contains=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u)
    LIST=""
    if [ -n "$starts" ]; then while read -r b; do LIST+="$b"$'\n'; done <<< "$starts"; fi
    if [ -n "$contains" ]; then while read -r b; do if ! echo "$LIST" | grep -qx "$b"; then LIST+="$b"$'\n'; fi; done <<< "$contains"; fi
    if [ -z "$LIST" ]; then sudo -u "$REAL_USER" zenity --info --text "لا توجد نتائج مطابقة. حاول كلمة أخرى." --width=380 2>/dev/null || true; echo ""; return; fi
    PICK=$(echo -n "$LIST" | sed '/^[[:space:]]*$/d' | sudo -u "$REAL_USER" zenity --list --title "اختر فرع" --column "Branch" --height=420 --width=420 2>/dev/null || true)
    echo "$PICK"
    return
  else
    echo "$SELECTED"
    return
  fi
}

search_branch_and_deploy(){
  while true; do
    fetch_db
    normalize_db
    branch=$(branch_list_ui)
    [ -z "$branch" ] && return
    printers=$(awk -F'|' -v b="$branch" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b)) print $0 }' "$DB_FILE")
    if [ -z "$printers" ]; then sudo -u "$REAL_USER" zenity --info --text "لا توجد طابعات مسجلة لهذا الفرع." --width=380 2>/dev/null || true; continue; fi
    DISP=""
    while IFS= read -r line; do
      label=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
      typ=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
      DISP+="${label} | ${typ}"$'\n'
    done <<< "$printers"
    SEL=$(echo -n "$DISP" | sed '/^[[:space:]]*$/d' | sudo -u "$REAL_USER" zenity --list --title "طابعات الفرع - Printers of $branch" --text "اختر الطابعة (سيُستخدم الاسم كما هو):" --column "Label | Type" --width=720 --height=420 2>/dev/null || true)
    [ -z "$SEL" ] && continue
    sel_label=$(echo "$SEL" | awk -F'|' '{print $1}' | xargs)
    record=$(awk -F'|' -v b="$branch" -v l="$sel_label" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE")
    if [ -z "$record" ]; then sudo -u "$REAL_USER" zenity --error --text "سجل الطابعة غير موجود." --width=380 2>/dev/null || true; _err "record missing $branch | $sel_label"; continue; fi
    addr=$(echo "$record" | awk -F'|' '{print $3}' | xargs)
    typ=$(echo "$record" | awk -F'|' '{print $4}' | xargs)
    driver_hint=$(echo "$record" | awk -F'|' '{print $5}' | xargs)
    if [ "$typ" != "network" ]; then
      if echo "$addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|[A-Za-z0-9.-]+$'; then
        if ! sudo -u "$REAL_USER" zenity --question --text "This printer is marked as '$typ'. Treat as network printer using address: $addr ?\nسيتم التعامل كطابعة شبكة." --ok-label "Yes/نعم" --cancel-label "No/لا" 2>/dev/null; then continue; fi
      else
        sudo -u "$REAL_USER" zenity --error --text "الطابعة ليست موسومة كشبكة والعنوان غير صالح لمعالجتها كشبكة." --width=480 2>/dev/null || true
        continue
      fi
    fi
    if ! sudo -u "$REAL_USER" zenity --question --text "هل تريد تعريف الطابعة: $sel_label (فرع: $branch)؟\nالاسم سيُستخدم كما هو." --ok-label "نعم" --cancel-label "لا" 2>/dev/null; then continue; fi
    deploy_network_printer "$branch" "$sel_label" "$addr" "$driver_hint"
    return
  done
}

# -------------------------
# Smart fix, clean spooler, status
# -------------------------
smart_fix(){
  DIAG=$(mktemp)
  (
    echo "10"
    if ! systemctl is-active --quiet cups; then systemctl restart cups; echo "- restarted CUPS" >> "$DIAG"; fi
    echo "40"
    if [ -n "$(lpstat -o 2>/dev/null)" ]; then cancel -a 2>/dev/null; echo "- cleared stuck jobs" >> "$DIAG"; fi
    echo "70"
    DIS=$(lpstat -p 2>/dev/null | grep "disabled" | awk '{print $2}')
    if [ -n "$DIS" ]; then for p in $DIS; do cupsenable "$p"; cupsaccept "$p"; done; echo "- re-enabled printers" >> "$DIAG"; fi
    echo "100"
  ) | sudo -u "$REAL_USER" zenity --progress --title "Smart Fix" --text "Running..." --auto-close 2>/dev/null || true
  if [ -s "$DIAG" ]; then sudo -u "$REAL_USER" zenity --info --title "تقرير الإصلاح" --text "$(cat $DIAG)" --width=450 2>/dev/null || true; else sudo -u "$REAL_USER" zenity --info --title "تقرير الإصلاح" --text "النظام يعمل جيدًا." --width=450 2>/dev/null || true; fi
  rm -f "$DIAG" 2>/dev/null || true
  _info "smart-fix executed"
}

clean_spooler(){
  (echo "50"; systemctl stop cups; rm -rf /var/spool/cups/*; systemctl start cups; echo "100") | sudo -u "$REAL_USER" zenity --progress --text "Cleaning spooler..." --auto-close 2>/dev/null || true
  sudo -u "$REAL_USER" zenity --info --text "تم مسح أوامر الطباعة المعلقة." --width=380 2>/dev/null || true
  _info "spooler cleaned"
}

view_status(){
  STATUS=$(lpstat -p 2>/dev/null || true)
  JOBS=$(lpstat -o 2>/dev/null || true)
  sudo -u "$REAL_USER" zenity --info --title "حالة الطابعات" --text "<b>الحالة العامة:</b>\n$STATUS\n\n<b>الأوامر العالقة:</b>\n$JOBS" --width=700 2>/dev/null || true
}

# -------------------------
# CLI arg: --update
# -------------------------
if [ "${1:-}" = "--update" ]; then
  _info "Manual update requested..."
  self_update "$@"
  exit 0
fi

# -------------------------
# Main menu (Zenity)
# -------------------------
fetch_db
normalize_db

while true; do
  CHOICE=$(sudo -u "$REAL_USER" zenity --list --title "IT Aman - Printer Tool ($CURRENT_VERSION)" --window-icon="printer" --text "قائمة الخدمات المتاحة:" \
    --radiolist --column "Select" --column "ID" --column "Option" \
    FALSE "1" "معالجة حشر الورق / Paper Jam Guide" \
    FALSE "2" "فحص النظام الذكي / Smart System Diagnostic" \
    FALSE "3" "تعريف طابعة (بحث فرع + تعريف) / Define Printer (Branch search)" \
    FALSE "4" "إصلاح أوامر الطباعة (مسح الذاكرة) / Quick Fix Spooler" \
    FALSE "5" "عرض الحالة العامة للطابعات / View Printer Status" \
    FALSE "6" "تحديث يدوي من GitHub / Update from GitHub" \
    FALSE "7" "خروج / Exit" \
    --width=780 --height=520 2>/dev/null || true)
  [ -z "$CHOICE" ] && exit 0
  case "$CHOICE" in
    1)
      sudo -u "$REAL_USER" zenity --info --title "خطوات إزالة الورق / Paper Jam" --text "اتبع التعليمات بدقة.\nFollow the safety steps." --width=520 2>/dev/null || true
      sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null || true
      ;;
    2) smart_fix ;;
    3) search_branch_and_deploy ;;
    4) clean_spooler ;;
    5) view_status ;;
    6) self_update "$@" ;;
    7) exit 0 ;;
  esac
done
