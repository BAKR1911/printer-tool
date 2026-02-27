#!/bin/bash
# ===============================================================
# printers.sh - IT Aman / Printer Tool (Full, production-ready)
# Version: 11.4
# Purpose: Branch-first UI, network-only deploy, self-update, desktop shortcut,
#          installs itself to /opt/printer-tool, robust logging, zenity+CLI.
# Author: Assembled per request
# ===============================================================
set -euo pipefail
IFS=$'\n\t'

# -----------------------
# Config (tweak these if needed)
# -----------------------
CURRENT_VERSION="11.4"
REPO_RAW="https://raw.githubusercontent.com/BAKR1911/printer-tool/main"   # change if repo differs
APP_NAME="printer-tool"
INSTALL_DIR="/opt/$APP_NAME"
DESKTOP_FILENAME="printer-tool.desktop"
LOG_FILE="/var/log/$APP_NAME.log"
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" "/usr/share/cups/drv" )
PRINTERS_LIST_NAME="printers.list"
VERSION_FILE_NAME="version.txt"
ICON_NAME="printer.png"
# -----------------------

# -----------------------
# Helpers: logging + print
# -----------------------
_info(){ printf '%s [INFO] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE" 2>/dev/null; }
_warn(){ printf '%s [WARN] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE" 2>/dev/null; }
_err(){ printf '%s [ERROR] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE" >&2 2>/dev/null; }

# Ensure log exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 644 "$LOG_FILE" 2>/dev/null || true

# -----------------------
# Resolve paths & user
# -----------------------
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
# canonical install dir is INSTALL_DIR unless wrapper changes it
# (script will self-install into INSTALL_DIR if not already there)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "$HOME")"
DESKTOP_DIR=""
# detect desktop dir (XDG aware and Arabic)
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

# Determine DB file path (may be overwritten after fetch_db)
DB_FILE="$SCRIPT_DIR/$PRINTERS_LIST_NAME"

# -----------------------
# Self-install to INSTALL_DIR if not already there
# Behavior: if user runs local copy (Downloads/Desktop), script will copy itself to /opt/printer-tool/printers.sh
# and re-exec from there. This ensures single canonical runtime location and consistent behavior.
# -----------------------
self_install(){
  # If current script is not the installed script, perform install
  if [ "$SCRIPT_PATH" != "$INSTALL_DIR/printers.sh" ]; then
    _info "Installing $APP_NAME to $INSTALL_DIR ..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp -f "$SCRIPT_PATH" "$INSTALL_DIR/printers.sh"
    sudo chmod +x "$INSTALL_DIR/printers.sh"
    # copy bundled printers.list/version/icon if present next to original script
    if [ -f "$SCRIPT_DIR/$PRINTERS_LIST_NAME" ]; then
      sudo cp -f "$SCRIPT_DIR/$PRINTERS_LIST_NAME" "$INSTALL_DIR/$PRINTERS_LIST_NAME"
    fi
    if [ -f "$SCRIPT_DIR/$VERSION_FILE_NAME" ]; then
      sudo cp -f "$SCRIPT_DIR/$VERSION_FILE_NAME" "$INSTALL_DIR/$VERSION_FILE_NAME"
    fi
    if [ -f "$SCRIPT_DIR/$ICON_NAME" ]; then
      sudo cp -f "$SCRIPT_DIR/$ICON_NAME" "$INSTALL_DIR/$ICON_NAME"
    fi
    # create symlink in /usr/local/bin for convenience
    sudo ln -sf "$INSTALL_DIR/printers.sh" "/usr/local/bin/$APP_NAME"
    sudo chmod +x "/usr/local/bin/$APP_NAME"
    _info "Installed. Restarting from $INSTALL_DIR/printers.sh ..."
    exec sudo "$INSTALL_DIR/printers.sh" "$@"
    exit 0
  fi
}

# -----------------------
# Desktop shortcut: create single idempotent desktop entry (avoid duplicates)
# Removes known legacy desktop names, then creates single $$DESKTOP_FILENAME
# -----------------------
create_single_desktop_shortcut(){
  [ -n "$DESKTOP_DIR" ] || return 0
  OLD_NAMES=( "IT-Aman.desktop" "IT-Aman-Tool.desktop" "Printer-Tool.desktop" "$DESKTOP_FILENAME" )
  # remove any old variants (best-effort)
  for n in "${OLD_NAMES[@]}"; do
    if [ -f "$DESKTOP_DIR/$n" ]; then
      rm -f "$DESKTOP_DIR/$n" 2>/dev/null || true
    fi
  done

  # determine icon path
  ICON_PATH="$INSTALL_DIR/$ICON_NAME"
  if [ ! -f "$ICON_PATH" ]; then
    ICON_PATH="printer"
  fi

  # Exec: use env to preserve DISPLAY/XAUTHORITY so GUI apps work when launched from desktop
  EXEC_CMD="env DISPLAY=\$DISPLAY XAUTHORITY=\$XAUTHORITY \"$INSTALL_DIR/printers.sh\""

  cat > "$DESKTOP_DIR/$DESKTOP_FILENAME" <<EOF
[Desktop Entry]
Name=Printer Tool
Comment=IT Printer Management Tool
Exec=$EXEC_CMD
Icon=$ICON_PATH
Terminal=false
Type=Application
Categories=Utility;
EOF

  chown "$REAL_USER:$REAL_USER" "$DESKTOP_DIR/$DESKTOP_FILENAME" 2>/dev/null || true
  chmod +x "$DESKTOP_DIR/$DESKTOP_FILENAME" 2>/dev/null || true
  # mark trusted if possible (GNOME)
  sudo -u "$REAL_USER" gio set "$DESKTOP_DIR/$DESKTOP_FILENAME" "metadata::trusted" true 2>/dev/null || true

  _info "Desktop shortcut ensured: $DESKTOP_DIR/$DESKTOP_FILENAME"
}

# -----------------------
# Version utilities + self-update
# -----------------------
version_gt(){
  # returns true if $1 > $2 (using sort -V)
  if command -v sort >/dev/null 2>&1; then
    local maj
    maj=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)
    [ "$maj" = "$1" ] && [ "$1" != "$2" ]
    return
  fi
  [ "$1" != "$2" ] && [ "$1" \> "$2" ]
  return
}

get_remote_version(){
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 5 "$REPO_RAW/$VERSION_FILE_NAME" 2>/dev/null | tr -d '[:space:]' || echo ""
  else
    echo ""
  fi
}

self_update(){
  local remote_v
  remote_v="$(get_remote_version)"
  [ -z "$remote_v" ] && return 1
  if version_gt "$remote_v" "$CURRENT_VERSION"; then
    local do_update=0
    if [ "${AUTO_UPDATE:-0}" -eq 1 ]; then
      do_update=1
    else
      if command -v zenity >/dev/null 2>&1; then
        if sudo -u "$REAL_USER" zenity --question --title "Update available" --text "New version $remote_v available. Update now?" 2>/dev/null; then
          do_update=1
        fi
      else
        if [ -t 1 ]; then
          read -p "New version $remote_v available. Update now? [y/N]: " ans
          case "$ans" in [Yy]*) do_update=1 ;; esac
        fi
      fi
    fi

    if [ "$do_update" -eq 1 ]; then
      _info "Updating to $remote_v ..."
      tmpf="$(mktemp)"
      if curl -fsS --connect-timeout 10 "$REPO_RAW/printers.sh" -o "$tmpf"; then
        cp -f "$SCRIPT_PATH" "${SCRIPT_PATH}.bak" 2>/dev/null || true
        chmod +x "$tmpf"
        mv -f "$tmpf" "$SCRIPT_PATH"
        chown root:root "$SCRIPT_PATH" 2>/dev/null || true
        _info "Updated to $remote_v; executing new script..."
        exec "$SCRIPT_PATH" "$@"
      else
        _err "Failed to download update"
        [ -f "$tmpf" ] && rm -f "$tmpf"
        return 2
      fi
    fi
  fi
  return 0
}

# run background update check non-blocking
trigger_background_update_check(){
  if command -v curl >/dev/null 2>&1 && ping -c1 -W2 8.8.8.8 &>/dev/null; then
    ( self_update "$@" ) & disown
  fi
}

# -----------------------
# Requirements check (soft)
# -----------------------
check_requirements(){
  local missing=()
  for cmd in zenity lp lpadmin lpstat cancel cupsenable cupsaccept systemctl awk sed grep curl ping nc xdg-open python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -ne 0 ]; then
    _warn "Missing commands: ${missing[*]}. Some features may not work (zenity/CUPS/netcat)."
  fi
}
check_requirements

# -----------------------
# DB handling: fetch / normalize
# -----------------------
TMP_DB="/tmp/.${APP_NAME}_db.$$"
fetch_db(){
  rm -f "$TMP_DB" 2>/dev/null || true
  # try central if online
  if ping -c1 -W2 8.8.8.8 &>/dev/null && command -v curl >/dev/null 2>&1; then
    if curl -fsS --connect-timeout 5 "$REPO_RAW/$PRINTERS_LIST_NAME" -o "$TMP_DB" 2>/dev/null; then
      if [ -s "$TMP_DB" ]; then
        DB_FILE="$TMP_DB"
        _info "Fetched central printers.list"
        return 0
      fi
    fi
  fi
  # fallback: use any printers.list beside script or in INSTALL_DIR
  if [ -f "$SCRIPT_DIR/$PRINTERS_LIST_NAME" ] && [ -s "$SCRIPT_DIR/$PRINTERS_LIST_NAME" ]; then
    DB_FILE="$SCRIPT_DIR/$PRINTERS_LIST_NAME"
    _info "Using printers.list next to script"
    return 0
  fi
  if [ -f "$INSTALL_DIR/$PRINTERS_LIST_NAME" ] && [ -s "$INSTALL_DIR/$PRINTERS_LIST_NAME" ]; then
    DB_FILE="$INSTALL_DIR/$PRINTERS_LIST_NAME"
    _info "Using printers.list in $INSTALL_DIR"
    return 0
  fi
  # create sample
  cat > "$TMP_DB" <<'EOF'
# Sample printers.list
# Format: Branch|PrinterLabel|Address|Type|Driver(optional)
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
Luxor|Admin HP P2035|printer-luxor.local|network|hp-p2035
EOF
  DB_FILE="$TMP_DB"
  _info "Created sample printers DB"
  return 0
}

normalize_db(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > "/tmp/.${APP_NAME}_db_clean.$$" 2>/dev/null || cp -f "$DB_FILE" "/tmp/.${APP_NAME}_db_clean.$$" 2>/dev/null || true
  DB_FILE="/tmp/.${APP_NAME}_db_clean.$$"
}

# Legacy support: if file has 3 columns Branch|IP|Model -> convert to Branch|Model|IP|network
normalize_legacy(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    if (NF==3) {
      b=$1; a=$2; m=$3
      gsub(/^[ \t]+|[ \t]+$/,"",b); gsub(/^[ \t]+|[ \t]+$/,"",a); gsub(/^[ \t]+|[ \t]+$/,"",m);
      print b "|" m "|" a "|network"
    } else print $0
  }' "$DB_FILE" > "/tmp/.${APP_NAME}_db_norm.$$" 2>/dev/null || cp -f "$DB_FILE" "/tmp/.${APP_NAME}_db_norm.$$" 2>/dev/null || true
  DB_FILE="/tmp/.${APP_NAME}_db_norm.$$"
}

# -----------------------
# Network validation
# returns: 0 ok, 1 ping fail, 2 port closed (port reachable false)
# -----------------------
validate_network(){
  local target="$1"
  if ! ping -c1 -W2 "$target" &>/dev/null; then
    return 1
  fi
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w2 "$target" 9100 &>/dev/null; then
      return 0
    else
      return 2
    fi
  fi
  return 0
}

# -----------------------
# Driver lookup
# -----------------------
find_driver(){
  local hint="$1"
  for d in "${DRIVER_DIRS[@]}"; do
    [ -d "$d" ] || continue
    if [ -n "$hint" ]; then
      found=$(grep -ril --null -e "$hint" "$d" 2>/dev/null | tr '\0' '\n' | head -n1 || true)
      if [ -n "$found" ]; then echo "$found"; return 0; fi
    fi
    f=$(ls "$d"/*.ppd 2>/dev/null | head -n1 || true)
    if [ -n "$f" ]; then echo "$f"; return 0; fi
  done
  # fallback: ask user to pick via zenity if available
  if command -v zenity >/dev/null 2>&1; then
    driver_file=$(sudo -u "$REAL_USER" zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null || true)
    if [ -n "$driver_file" ]; then echo "$driver_file"; return 0; fi
  fi
  echo ""
  return 1
}

# -----------------------
# Deploy network printer robust
# -----------------------
deploy_network_printer(){
  local branch="$1"
  local label="$2"
  local addr="$3"
  local driver_hint="$4"

  local cups_name="ITA_${branch// /_}_${label// /_}"
  cups_name=$(echo "$cups_name" | tr -s '_' )

  if sudo lpstat -p "$cups_name" >/dev/null 2>&1; then
    sudo -u "$REAL_USER" zenity --info --title "Info" --text "الطابعة معرفة بالفعل: $label" 2>/dev/null || echo "Printer exists: $cups_name"
    _info "skip deploy: $cups_name exists"
    return 0
  fi

  # validate network
  validate_network "$addr"
  local vres=$?
  if [ $vres -eq 1 ]; then
    sudo -u "$REAL_USER" zenity --error --title "Network Error" --text "تعذر الوصول للطابعة (Ping failed): $addr\nPlease check network/cable." 2>/dev/null || true
    _warn "ping failed for $addr"
    return 1
  elif [ $vres -eq 2 ]; then
    sudo -u "$REAL_USER" zenity --warning --title "Port Warning" --text "الطابعة ترد لكن منفذ 9100 مغلق: $addr\nAttempting add with warning." 2>/dev/null || true
    _warn "port 9100 closed on $addr"
  fi

  local uri="socket://${addr}:9100"
  local driver_file
  driver_file=$(find_driver "$driver_hint" 2>/dev/null || echo "")

  local tmp_err="/tmp/${APP_NAME}_lpadmin_err.$$"
  rm -f "$tmp_err" 2>/dev/null || true

  if [ -n "$driver_file" ]; then
    _info "Using driver: $driver_file"
    if ! sudo lpadmin -p "$cups_name" -E -v "$uri" -P "$driver_file" 2>"$tmp_err"; then
      local errtxt
      errtxt=$(cat "$tmp_err" 2>/dev/null || true)
      _err "lpadmin failed with driver: $errtxt"
      sudo -u "$REAL_USER" zenity --error --title "lpadmin failed" --text "Failed to add printer:\n$errtxt" 2>/dev/null || true
      rm -f "$tmp_err" 2>/dev/null || true
      return 2
    fi
  else
    _info "No driver found; trying 'everywhere' then raw"
    sudo lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>"$tmp_err" || sudo lpadmin -p "$cups_name" -E -v "$uri" -m raw 2>"$tmp_err" || true
    if ! sudo lpstat -p "$cups_name" >/dev/null 2>&1; then
      local errtxt
      errtxt=$(cat "$tmp_err" 2>/dev/null || true)
      _err "lpadmin fallback failed: $errtxt"
      sudo -u "$REAL_USER" zenity --error --title "Add failed" --text "Failed to add printer:\n$errtxt" 2>/dev/null || true
      rm -f "$tmp_err" 2>/dev/null || true
      return 2
    fi
  fi

  sudo lpoptions -d "$cups_name" 2>/dev/null || true

  if sudo lpstat -p "$cups_name" >/dev/null 2>&1; then
    sudo -u "$REAL_USER" zenity --info --title "Done" --text "تم تعريف الطابعة بنجاح: $label" 2>/dev/null || echo "Added $label"
    _info "deployed $cups_name -> $uri"
    run_test_and_open_cups "$cups_name" "$addr"
    return 0
  else
    _err "Added but lpstat can't find $cups_name"
    return 3
  fi
}

# -----------------------
# run test & open cups
# -----------------------
run_test_and_open_cups(){
  local cups_name="$1"
  local addr="$2"
  if command -v lp >/dev/null 2>&1; then
    echo -e "IT Aman Test Page\nPrinter: $cups_name\nDate: $(date)" > /tmp/${APP_NAME}_test.$$ || true
    sudo lp -d "$cups_name" /tmp/${APP_NAME}_test.$$ 2>/dev/null || true
    rm -f /tmp/${APP_NAME}_test.$$ 2>/dev/null || true
  fi

  # open CUPS printer page for user
  if [ -n "$REAL_USER" ]; then
    PR_NAME_URL=$(python3 - <<PY 2>/dev/null
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
"$cups_name" 2>/dev/null || echo "")
    [ -z "$PR_NAME_URL" ] && PR_NAME_URL=$(echo "$cups_name" | sed 's/ /%20/g')
    sudo -u "$REAL_USER" xdg-open "http://localhost:631/printers/${PR_NAME_URL}" &>/dev/null || true
  fi

  sudo -u "$REAL_USER" zenity --info --title "Test Page" --text "تم إرسال اختبار وفتحت صفحة CUPS للطابعة. اضغط Print Test Page في الواجهة إن احتجت." 2>/dev/null || true
  _info "Sent test & opened CUPS for $cups_name"
}

# -----------------------
# Branch-first UI with Search-filter (zenity when available; CLI fallback)
# -----------------------
branch_list_ui(){
  # builds unique branches list and shows them; first row is "Search / فلترة الفروع"
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u 2>/dev/null || true)
  if command -v zenity >/dev/null 2>&1; then
    tmp=$(mktemp)
    echo "Search / فلترة الفروع" > "$tmp"
    echo "$branches" >> "$tmp"
    SELECTED=$(cat "$tmp" | sudo -u "$REAL_USER" zenity --list --title "Branches - اختر فرع" --column "Branch or Search" --height=420 --width=420 2>/dev/null || true)
    rm -f "$tmp"
    [ -z "$SELECTED" ] && echo "" && return
    if [ "$SELECTED" = "Search / فلترة الفروع" ]; then
      SEARCH=$(sudo -u "$REAL_USER" zenity --entry --title "Search Branch - ابحث عن فرع" --text "اكتب حروف الفرع لتصفية (مثال: As):" --width=520 2>/dev/null || true)
      [ -z "$SEARCH" ] && echo "" && return
      starts=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ "^"tolower(s) {print $1}' "$DB_FILE" | sort -u 2>/dev/null || true)
      contains=$(awk -F'|' -v s="$SEARCH" 'tolower($1) ~ tolower(s) && !(tolower($1) ~ "^"tolower(s)) {print $1}' "$DB_FILE" | sort -u 2>/dev/null || true)
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
  else
    # CLI fallback: show branches then allow search
    echo "Branches:"
    printf '%s\n' "$branches"
    echo "Type branch name or leave empty to cancel:"
    read -p "> " br
    echo "$br"
    return
  fi
}

search_branch_and_deploy(){
  while true; do
    fetch_db
    normalize_db
    normalize_legacy
    branch=$(branch_list_ui)
    [ -z "$branch" ] && return
    printers=$(awk -F'|' -v b="$branch" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b)) print $0 }' "$DB_FILE" || true)
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
    record=$(awk -F'|' -v b="$branch" -v l="$sel_label" 'BEGIN{IGNORECASE=1} { if (tolower($1)==tolower(b) && tolower($2)==tolower(l)) {print $0; exit} }' "$DB_FILE" || true)
    if [ -z "$record" ]; then sudo -u "$REAL_USER" zenity --error --text "سجل الطابعة غير موجود." --width=380 2>/dev/null || true; _err "record missing $branch | $sel_label"; continue; fi
    addr=$(echo "$record" | awk -F'|' '{print $3}' | xargs)
    typ=$(echo "$record" | awk -F'|' '{print $4}' | xargs)
    driver_hint=$(echo "$record" | awk -F'|' '{print $5}' | xargs)
    # Only network allowed by default; if other, ask to treat as network
    if [ "$typ" != "network" ]; then
      if echo "$addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|[A-Za-z0-9.-]+$'; then
        if ! sudo -u "$REAL_USER" zenity --question --text "This printer is marked as '$typ'. Treat as network printer using address: $addr ?\nسيتم التعامل كطابعة شبكة." --ok-label "Yes/نعم" --cancel-label "No/لا" 2>/dev/null; then
          continue
        fi
      else
        sudo -u "$REAL_USER" zenity --error --text "الطابعة ليست موسومة كشبكة والعنوان غير صالح لمعالجتها كشبكة." --width=480 2>/dev/null || true
        continue
      fi
    fi
    if ! sudo -u "$REAL_USER" zenity --question --text "هل تريد تعريف الطابعة: $sel_label (فرع: $branch)؟\nالاسم سيُستخدم كما هو." --ok-label "نعم" --cancel-label "لا" 2>/dev/null; then
      continue
    fi
    deploy_network_printer "$branch" "$sel_label" "$addr" "$driver_hint"
    return
  done
}

# -----------------------
# Smart fix, clean spooler, view status
# -----------------------
smart_fix(){
  DIAG=$(mktemp) || DIAG="/tmp/${APP_NAME}_diag.$$"
  (
    echo "10"
    if ! systemctl is-active --quiet cups; then systemctl restart cups; echo "- restarted CUPS" >> "$DIAG"; fi
    echo "40"
    if [ -n "$(lpstat -o 2>/dev/null)" ]; then cancel -a 2>/dev/null; echo "- cleared stuck jobs" >> "$DIAG"; fi
    echo "70"
    DIS=$(lpstat -p 2>/dev/null | grep "disabled" | awk '{print $2}' || true)
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

# -----------------------
# CLI: --update
# -----------------------
if [ "${1:-}" = "--update" ]; then
  _info "Manual update requested..."
  self_update "$@"
  exit 0
fi

# -----------------------
# Main: self-install, ensure desktop, update check, UI loop
# -----------------------
self_install    # will exec into installed path if not already
create_single_desktop_shortcut
trigger_background_update_check

# prepare DB
fetch_db
normalize_db
normalize_legacy

# UI loop (zenity preferred, CLI fallback)
while true; do
  if command -v zenity >/dev/null 2>&1; then
    CHOICE=$(sudo -u "$REAL_USER" zenity --list --title "IT Aman - Printer Tool ($CURRENT_VERSION)" --window-icon="printer" --text "قائمة الخدمات المتاحة:" \
      --radiolist --column "Select" --column "ID" --column "Option" \
      FALSE "1" "معالجة حشر الورق / Paper Jam Guide" \
      FALSE "2" "فحص النظام الذكي / Smart System Diagnostic" \
      FALSE "3" "تعريف طابعة (بحث فرع + تعريف) / Define Printer (Branch search)" \
      FALSE "4" "إصلاح أوامر الطباعة (مسح الذاكرة) / Quick Fix Spooler" \
      FALSE "5" "عرض الحالة العامة للطابعات / View Printer Status" \
      FALSE "6" "تحديث يدوي من GitHub / Update from GitHub" \
      FALSE "7" "خروج / Exit" \
      --width=820 --height=520 2>/dev/null || true)
  else
    cat <<CLI_MENU
IT Aman - Printer Tool ($CURRENT_VERSION)
1) Paper Jam Guide
2) Smart System Diagnostic
3) Define Printer (Branch search)
4) Quick Fix Spooler
5) View Printer Status
6) Update from GitHub
7) Exit
CLI_MENU
    read -p "Select option [1-7]: " CHOICE
  fi

  [ -z "${CHOICE:-}" ] && exit 0

  case "$CHOICE" in
    1)
      if command -v zenity >/dev/null 2>&1; then
        sudo -u "$REAL_USER" zenity --info --title "خطوات إزالة الورق / Paper Jam" --text "اتبع التعليمات بدقة.\nFollow the safety steps." --width=520 2>/dev/null || true
        sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null || true
      else
        echo "Paper Jam Guide: power off, open doors, pull paper slowly by both hands. See online video."
      fi
      ;;
    2) smart_fix ;;
    3) search_branch_and_deploy ;;
    4) clean_spooler ;;
    5) view_status ;;
    6) self_update "$@" ;;
    7) exit 0 ;;
    *) _warn "Unknown option: $CHOICE" ;;
  esac
done

# EOF
