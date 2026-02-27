#!/bin/bash
# ===============================================================
# printers.sh - IT Aman / Printer Tool (Stable, full-featured)
# Version: 11.7
# Purpose: Branch-first UI, network-only deploy, self-update, merge DB,
#          single desktop shortcut, robust CUPS deploy with validation.
# Notes: - Place printers.list next to this script or in /opt/printer-tool/
#        - Update version.txt on GitHub when releasing new version.
# ===============================================================
set -euo pipefail
IFS=$'\n\t'

# -----------------------
# Config
# -----------------------
CURRENT_VERSION="11.7"
REPO_RAW="https://raw.githubusercontent.com/BAKR1911/printer-tool/main"
APP="printer-tool"
INSTALL_DIR="/opt/$APP"
BIN_LINK="/usr/local/bin/$APP"
DESKTOP_NAME="printer-tool.desktop"
LOG="/var/log/$APP.log"
PRINTERS_LIST="printers.list"
VERSION_FILE="version.txt"
ICON_NAME="printer.png"
DRIVER_DIRS=( "/usr/local/share/it_aman/drivers" "/opt/it_aman/drivers" "/usr/share/cups/model" "/usr/share/ppd" "/usr/share/cups/drv" )
TMP_PREFIX="/tmp/${APP}_$$"

# -----------------------
# Helpers (logging)
# -----------------------
_info(){ printf '%s [INFO] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG" 2>/dev/null; }
_warn(){ printf '%s [WARN] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG" 2>/dev/null; }
_err(){ printf '%s [ERROR] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOG" >&2 2>/dev/null; }

# Ensure log exists
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
touch "$LOG" 2>/dev/null || true
chmod 644 "$LOG" 2>/dev/null || true

# -----------------------
# Determine real interactive user (the human who triggered sudo/pkexec)
# -----------------------
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "$HOME")"

# Desktop detection (xdg-user-dir DESKTOP when possible, supports Arabic)
detect_desktop_dir(){
  local desktop
  desktop=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP 2>/dev/null || true)
  if [ -n "$desktop" ] && [ -d "$desktop" ]; then
    echo "$desktop"
    return
  fi
  if [ -d "$USER_HOME/Desktop" ]; then echo "$USER_HOME/Desktop"; return; fi
  if [ -d "$USER_HOME/سطح المكتب" ]; then echo "$USER_HOME/سطح المكتب"; return; fi
  mkdir -p "$USER_HOME/Desktop" 2>/dev/null || true
  echo "$USER_HOME/Desktop"
}
DESKTOP_DIR="$(detect_desktop_dir)"

# Path to running script and script dir
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# SUDO wrapper: use sudo when not running as root
SUDO_CMD=""
if [ "$EUID" -ne 0 ]; then SUDO_CMD="sudo"; fi

# -----------------------
# Self-install: move to INSTALL_DIR and merge printers.list (no data loss)
# -----------------------
self_install(){
  if [ "$SCRIPT_PATH" != "$INSTALL_DIR/printers.sh" ]; then
    _info "Installing $APP to $INSTALL_DIR ..."
    $SUDO_CMD mkdir -p "$INSTALL_DIR"
    $SUDO_CMD cp -f "$SCRIPT_PATH" "$INSTALL_DIR/printers.sh"
    $SUDO_CMD chmod +x "$INSTALL_DIR/printers.sh"
    # Copy/merge local printers.list if exists
    if [ -f "$SCRIPT_DIR/$PRINTERS_LIST" ]; then
      if $SUDO_CMD test -f "$INSTALL_DIR/$PRINTERS_LIST"; then
        # merge lines not already present
        tmp_src=$(mktemp "$TMP_PREFIX.src.XXXX")
        cp -f "$SCRIPT_DIR/$PRINTERS_LIST" "$tmp_src"
        $SUDO_CMD bash -c "awk 'NF && \$0 !~ /^#/ {print \$0}' '$tmp_src' | while IFS= read -r line; do if ! grep -Fxq \"\$line\" '$INSTALL_DIR/$PRINTERS_LIST'; then echo \"\$line\" >> '$INSTALL_DIR/$PRINTERS_LIST'; fi; done"
        rm -f "$tmp_src" 2>/dev/null || true
        _info "Merged local printers.list into $INSTALL_DIR/$PRINTERS_LIST"
      else
        $SUDO_CMD cp -f "$SCRIPT_DIR/$PRINTERS_LIST" "$INSTALL_DIR/$PRINTERS_LIST"
        _info "Copied local printers.list to $INSTALL_DIR/"
      fi
    fi
    # copy icon if exists
    if [ -f "$SCRIPT_DIR/$ICON_NAME" ]; then
      $SUDO_CMD cp -f "$SCRIPT_DIR/$ICON_NAME" "$INSTALL_DIR/$ICON_NAME"
    fi
    # create symlink
    $SUDO_CMD ln -sf "$INSTALL_DIR/printers.sh" "$BIN_LINK"
    $SUDO_CMD chmod +x "$BIN_LINK"
    _info "Installed. Re-executing installed script..."
    exec $SUDO_CMD "$INSTALL_DIR/printers.sh" "$@"
    exit 0
  fi
}

# -----------------------
# Ensure single desktop shortcut (idempotent)
# -----------------------
ensure_single_desktop(){
  [ -n "$DESKTOP_DIR" ] || return 0
  local desktop_path="$DESKTOP_DIR/$DESKTOP_NAME"
  # remove legacy variants
  local legacy=("IT-Aman.desktop" "IT-Aman-Tool.desktop" "Printer-Tool.desktop" "$DESKTOP_NAME")
  for n in "${legacy[@]}"; do
    $SUDO_CMD rm -f "$DESKTOP_DIR/$n" 2>/dev/null || true
  done

  # Build Exec: use pkexec to prompt for auth when clicking icon. preserve DISPLAY/XAUTHORITY.
  local exec_cmd="pkexec env DISPLAY=\$DISPLAY XAUTHORITY=\$XAUTHORITY \"$INSTALL_DIR/printers.sh\""
  # choose icon
  local iconpath="$INSTALL_DIR/$ICON_NAME"
  if ! $SUDO_CMD test -f "$iconpath"; then iconpath="printer"; fi

  # write tmp file as root then chown
  tmpfile=$(mktemp "$TMP_PREFIX.desktop.XXXX")
  cat > "$tmpfile" <<EOF
[Desktop Entry]
Name=Printer Tool
Comment=IT Printer Management Tool
Exec=$exec_cmd
Icon=$iconpath
Terminal=false
Type=Application
Categories=Utility;
EOF

  $SUDO_CMD mv -f "$tmpfile" "$desktop_path"
  $SUDO_CMD chown "$REAL_USER:$REAL_USER" "$desktop_path" 2>/dev/null || true
  $SUDO_CMD chmod +x "$desktop_path" 2>/dev/null || true
  # try mark trusted (GNOME)
  sudo -u "$REAL_USER" gio set "$desktop_path" "metadata::trusted" true 2>/dev/null || true

  _info "Desktop shortcut ensured: $desktop_path"
}

# -----------------------
# Self update helpers
# -----------------------
get_remote_version(){
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 5 "$REPO_RAW/$VERSION_FILE" 2>/dev/null | tr -d '[:space:]' || echo ""
  else
    echo ""
  fi
}
version_gt(){
  if command -v sort >/dev/null 2>&1; then
    maj=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)
    [ "$maj" = "$1" ] && [ "$1" != "$2" ]
    return
  fi
  [ "$1" != "$2" ] && [ "$1" \> "$2" ]
  return
}
perform_self_update(){
  tmpf=$(mktemp "$TMP_PREFIX.update.XXXX")
  if curl -fsS --connect-timeout 10 "$REPO_RAW/printers.sh" -o "$tmpf"; then
    $SUDO_CMD cp -f "$INSTALL_DIR/printers.sh" "$INSTALL_DIR/printers.sh.bak" 2>/dev/null || true
    $SUDO_CMD mv -f "$tmpf" "$INSTALL_DIR/printers.sh"
    $SUDO_CMD chmod +x "$INSTALL_DIR/printers.sh"
    _info "Update applied. Restarting new script..."
    exec $SUDO_CMD "$INSTALL_DIR/printers.sh" "$@"
  else
    _err "Failed to download updated script"
    rm -f "$tmpf" 2>/dev/null || true
    return 1
  fi
}
# background check (non-blocking)
background_update_check(){
  if command -v curl >/dev/null 2>&1 && ping -c1 -W2 8.8.8.8 &>/dev/null; then
    ( sleep 2
      remote_v="$(get_remote_version)"
      if [ -n "$remote_v" ] && version_gt "$remote_v" "$CURRENT_VERSION"; then
        # ask user (zenity) or skip
        if command -v zenity >/dev/null 2>&1; then
          if sudo -u "$REAL_USER" zenity --question --title "Update available" --text "New version $remote_v. Update now?" 2>/dev/null; then
            perform_self_update "$@"
          fi
        fi
      fi
    ) & disown
  fi
}

# -----------------------
# DB fetch and merge
# -----------------------
fetch_and_merge_db(){
  tmpremote=$(mktemp "$TMP_PREFIX.remote.XXXX")
  rm -f "$tmpremote" 2>/dev/null || true

  if ping -c1 -W2 8.8.8.8 &>/dev/null && command -v curl >/dev/null 2>&1; then
    if curl -fsS --connect-timeout 5 "$REPO_RAW/$PRINTERS_LIST" -o "$tmpremote" 2>/dev/null; then
      if [ -s "$tmpremote" ]; then
        _info "Fetched remote printers.list"
        if [ -f "$INSTALL_DIR/$PRINTERS_LIST" ]; then
          # merge remote into installed file
          $SUDO_CMD bash -c "awk 'NF && \$0 !~ /^#/ {print \$0}' '$tmpremote' | while IFS= read -r line; do if ! grep -Fxq \"\$line\" '$INSTALL_DIR/$PRINTERS_LIST'; then echo \"\$line\" >> '$INSTALL_DIR/$PRINTERS_LIST'; fi; done"
          DB_FILE="$INSTALL_DIR/$PRINTERS_LIST"
          _info "Merged remote into $INSTALL_DIR/$PRINTERS_LIST"
        else
          $SUDO_CMD cp -f "$tmpremote" "$INSTALL_DIR/$PRINTERS_LIST"
          DB_FILE="$INSTALL_DIR/$PRINTERS_LIST"
          _info "Copied remote printers.list to $INSTALL_DIR"
        fi
        rm -f "$tmpremote" 2>/dev/null || true
        return 0
      fi
    fi
  fi

  # fallback options
  if [ -f "$SCRIPT_DIR/$PRINTERS_LIST" ] && [ -s "$SCRIPT_DIR/$PRINTERS_LIST" ]; then
    DB_FILE="$SCRIPT_DIR/$PRINTERS_LIST"
    _info "Using local printers.list next to script"
    return 0
  fi
  if [ -f "$INSTALL_DIR/$PRINTERS_LIST" ] && [ -s "$INSTALL_DIR/$PRINTERS_LIST" ]; then
    DB_FILE="$INSTALL_DIR/$PRINTERS_LIST"
    _info "Using installed printers.list"
    return 0
  fi

  # fallback sample
  tmpdb=$(mktemp "$TMP_PREFIX.sample.XXXX")
  cat > "$tmpdb" <<'EOF'
# Sample printers.list
# Format: Branch|Label|Address|Type|Driver(optional)
Aswan|POS Thermal 1|192.168.10.50|network|tm-raw
Aswan|Front Office HP M404|192.168.10.20|network|hp-ppd
Qena|Back Office Epson LQ|192.168.20.15|network|epson-lq
EOF
  DB_FILE="$tmpdb"
  _info "Using sample printers DB"
  return 0
}

# -----------------------
# Normalize DB formats
# -----------------------
normalize_db(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    for(i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
    print $0
  }' "$DB_FILE" > "${TMP_PREFIX}.db_clean" 2>/dev/null || cp -f "$DB_FILE" "${TMP_PREFIX}.db_clean" 2>/dev/null || true
  DB_FILE="${TMP_PREFIX}.db_clean"
}

normalize_legacy(){
  awk -F'|' '{
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next;
    if (NF==3) {
      b=$1; a=$2; m=$3
      gsub(/^[ \t]+|[ \t]+$/,"",b); gsub(/^[ \t]+|[ \t]+$/,"",a); gsub(/^[ \t]+|[ \t]+$/,"",m);
      print b "|" m "|" a "|network"
    } else print $0
  }' "$DB_FILE" > "${TMP_PREFIX}.db_norm" 2>/dev/null || cp -f "$DB_FILE" "${TMP_PREFIX}.db_norm" 2>/dev/null || true
  DB_FILE="${TMP_PREFIX}.db_norm"
}

# -----------------------
# Validate network (ping + port)
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
  local found=""
  for d in "$INSTALL_DIR/drivers" "${DRIVER_DIRS[@]}"; do
    [ -d "$d" ] || continue
    if [ -n "$hint" ]; then
      found=$(grep -ril --null -e "$hint" "$d" 2>/dev/null | tr '\0' '\n' | head -n1 || true)
      [ -n "$found" ] && { echo "$found"; return 0; }
    fi
    f=$(ls "$d"/*.ppd 2>/dev/null | head -n1 || true)
    [ -n "$f" ] && { echo "$f"; return 0; }
  done
  # zenity picker fallback
  if command -v zenity >/dev/null 2>&1; then
    driver_file=$(sudo -u "$REAL_USER" zenity --file-selection --title "Select driver PPD (اختيار ملف درايفر)" 2>/dev/null || true)
    [ -n "$driver_file" ] && { echo "$driver_file"; return 0; }
  fi
  echo ""
  return 1
}

# -----------------------
# Deploy network printer (robust)
# -----------------------
deploy_network_printer(){
  local branch="$1" label="$2" addr="$3" driver_hint="$4"

  local cups_name="ITA_${branch// /_}_${label// /_}"
  cups_name=$(echo "$cups_name" | tr -s '_' )

  if $SUDO_CMD lpstat -p "$cups_name" >/dev/null 2>&1; then
    sudo -u "$REAL_USER" zenity --info --title "Info" --text "الطابعة معرفة بالفعل: $label" 2>/dev/null || true
    _info "skip deploy: $cups_name exists"
    return 0
  fi

  # Validate network
  validate_network "$addr"
  local vres=$?
  if [ $vres -eq 1 ]; then
    sudo -u "$REAL_USER" zenity --error --title "Network Error" --text "تعذر الوصول للطابعة (Ping failed): $addr\nPlease check network/cable." 2>/dev/null || true
    _err "ping failed for $addr"
    return 1
  elif [ $vres -eq 2 ]; then
    sudo -u "$REAL_USER" zenity --warning --title "Port Warning" --text "الطابعة ترد لكن منفذ 9100 مغلق: $addr\nAttempting add with warning." 2>/dev/null || true
    _warn "port 9100 closed on $addr"
  fi

  # Choose best URI automatically
  local uri
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w2 "$addr" 9100 &>/dev/null; then
      uri="socket://${addr}:9100"
    elif nc -z -w2 "$addr" 631 &>/dev/null; then
      uri="ipp://${addr}/ipp/print"
    elif nc -z -w2 "$addr" 515 &>/dev/null; then
      uri="lpd://${addr}/"
    else
      uri="socket://${addr}:9100"
    fi
  else
    uri="socket://${addr}:9100"
  fi
  _info "Using URI: $uri"

  local driver_file
  driver_file="$(find_driver "$driver_hint" 2>/dev/null || echo "")"

  local tmp_err="$(mktemp "$TMP_PREFIX.err.XXXX")"
  rm -f "$tmp_err" 2>/dev/null || true

  if [ -n "$driver_file" ]; then
    _info "Using driver file: $driver_file"
    if ! $SUDO_CMD lpadmin -p "$cups_name" -E -v "$uri" -P "$driver_file" 2>"$tmp_err"; then
      errtxt=$(cat "$tmp_err" 2>/dev/null || true)
      _err "lpadmin failed with driver: $errtxt"
      sudo -u "$REAL_USER" zenity --error --title "lpadmin failed" --text "Failed to add printer:\n$errtxt" 2>/dev/null || true
      rm -f "$tmp_err" 2>/dev/null || true
      return 2
    fi
  else
    _info "No driver found; trying -m everywhere then raw"
    if $SUDO_CMD lpadmin -p "$cups_name" -E -v "$uri" -m everywhere 2>"$tmp_err"; then
      _info "Added with everywhere"
    elif $SUDO_CMD lpadmin -p "$cups_name" -E -v "$uri" -m raw 2>"$tmp_err"; then
      _info "Added with raw"
    else
      errtxt=$(cat "$tmp_err" 2>/dev/null || true)
      _err "lpadmin fallback failed: $errtxt"
      sudo -u "$REAL_USER" zenity --error --title "Add failed" --text "Failed to add printer:\n$errtxt" 2>/dev/null || true
      rm -f "$tmp_err" 2>/dev/null || true
      return 2
    fi
  fi

  $SUDO_CMD lpoptions -d "$cups_name" 2>/dev/null || true

  if $SUDO_CMD lpstat -p "$cups_name" >/dev/null 2>&1; then
    sudo -u "$REAL_USER" zenity --info --title "Done" --text "تم تعريف الطابعة بنجاح: $label" 2>/dev/null || true
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
  local cups_name="$1" addr="$2"
  if command -v lp >/dev/null 2>&1; then
    local tmpf="$(mktemp "$TMP_PREFIX.test.XXXX")"
    echo -e "IT Aman Test Page\nPrinter: $cups_name\nDate: $(date)" > "$tmpf" || true
    $SUDO_CMD lp -d "$cups_name" "$tmpf" 2>/dev/null || true
    rm -f "$tmpf" 2>/dev/null || true
  fi
  # open printer page for user
  PR_NAME_URL="$(python3 - <<PY 2>/dev/null
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
"$cups_name" 2>/dev/null || echo "")"
  [ -z "$PR_NAME_URL" ] && PR_NAME_URL=$(echo "$cups_name" | sed 's/ /%20/g')
  sudo -u "$REAL_USER" xdg-open "http://localhost:631/printers/${PR_NAME_URL}" &>/dev/null || true
  sudo -u "$REAL_USER" zenity --info --title "Test Page" --text "تم إرسال اختبار وفتحت صفحة CUPS للطابعة. اضغط Print Test Page في الواجهة إن احتجت." 2>/dev/null || true
  _info "Test sent & CUPS opened for $cups_name"
}

# -----------------------
# Branch-first UI / search-filter
# -----------------------
branch_list_ui(){
  branches=$(awk -F'|' '{print $1}' "$DB_FILE" | sort -u 2>/dev/null || true)
  if command -v zenity >/dev/null 2>&1; then
    tmp=$(mktemp "$TMP_PREFIX.branches.XXXX")
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
    echo "Branches:"
    printf '%s\n' "$branches"
    read -p "Type branch name (or Enter to cancel): " br
    echo "$br"
    return
  fi
}

search_branch_and_deploy(){
  while true; do
    fetch_and_merge_db
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
# Smart fix / Clean / Status
# -----------------------
smart_fix(){
  DIAG=$(mktemp "$TMP_PREFIX.diag.XXXX") || DIAG="/tmp/${APP}_diag.$$"
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
# CLI args handling
# -----------------------
if [ "${1:-}" = "--update" ]; then
  _info "Manual update requested..."
  perform_self_update "$@"
  exit 0
fi

# -----------------------
# Init sequence
# -----------------------
self_install "$@"
ensure_single_desktop
background_update_check "$@"
fetch_and_merge_db
normalize_db
normalize_legacy

# -----------------------
# Main UI loop
# -----------------------
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
    cat <<EOF
IT Aman - Printer Tool ($CURRENT_VERSION)
1) Paper Jam Guide
2) Smart System Diagnostic
3) Define Printer (Branch search)
4) Quick Fix Spooler
5) View Printer Status
6) Update from GitHub
7) Exit
EOF
    read -p "Select option [1-7]: " CHOICE
  fi

  [ -z "${CHOICE:-}" ] && exit 0

  case "$CHOICE" in
    1)
      if command -v zenity >/dev/null 2>&1; then
        sudo -u "$REAL_USER" zenity --info --title "خطوات إزالة الورق / Paper Jam" --text "اتبع التعليمات بدقة.\nFollow the safety steps." --width=520 2>/dev/null || true
        sudo -u "$REAL_USER" xdg-open "https://drive.google.com/file/d/1Ir08HroVj6TShF-ZOCiXvbwk8THkED1E/view?usp=drive_link" &>/dev/null || true
      else
        echo "Paper Jam: power off, open access doors, pull jam slowly with both hands."
      fi
      ;;
    2) smart_fix ;;
    3) search_branch_and_deploy ;;
    4) clean_spooler ;;
    5) view_status ;;
    6) perform_self_update "$@" ;;
    7) exit 0 ;;
    *) _warn "Unknown option: $CHOICE" ;;
  esac
done

# EOF
