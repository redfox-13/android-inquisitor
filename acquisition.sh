#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# acquisition.sh - Pull all app data from Android device into case directory
#
# Called by snapshot.sh  intended for direct use.
# Usage: ./acquisition.sh <package> <device_flag> <out_dir>
#
# Pulls into <out_dir>/:
#   app_data/   - full data dirs (data/data, data/user, data/user_de,
#                 data_mirror, external/media) — WAL/SHM included automatically
#   apk/        - installed APK(s) + sha256
#   meta/       - dumpsys package, permissions list, granted permissions
#   network/    - keystore/net misc files, cert/ssl files noted from app_data
#
# Environment:
#   ADB=<path>        override adb binary
# ----------------------------------------------------------------------------
set -euo pipefail

# -- Colours -------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_INFO='\033[0;36m'; C_OK='\033[0;32m'
    C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
else
    C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_BOLD=''; C_DIM=''
fi

log_info() { echo -e "${C_INFO}[Info ]${C_RESET} $*" >&2; }
log_ok()   { echo -e "${C_OK}[  OK ]${C_RESET} $*" >&2; }
log_warn() { echo -e "${C_WARN}[Warn ]${C_RESET} $*" >&2; }
log_err()  { echo -e "${C_ERR}[Error]${C_RESET} $*" >&2; }
log_step() { echo -e "\n${C_BOLD}-- $* ${C_RESET}" >&2; }
log_sep()  { echo -e "${C_DIM}----------------------------------------${C_RESET}"; }
die()      { log_err "$*"; exit 1; }

# -- Args ----------------------------------------------------------------------
[[ $# -lt 3 ]] && die "Usage: acquisition.sh <package> <device_flag> <out_dir>"

APP="$1"
DEVICE="$2"
OUT_DIR="$3"

ADB="${ADB:-$(command -v adb 2>/dev/null || echo '')}"
[[ -z "$ADB" ]] && die "'adb' not found in PATH."

mkdir -p "$OUT_DIR"

# -- Root method detection -----------------------------------------------------
log_step "Root method"
ROOT_METHOD="NONE"

probe() {
    local label="$1" cmd="$2" result
    result=$("$ADB" $DEVICE shell "$cmd" 2>/dev/null | tr -d '\r')
    if echo "$result" | grep -q "uid=0"; then
        log_ok "Works: $label"; return 0
    fi
    log_info "Failed: $label (got: ${result:-<no output>})"; return 1
}

ADBD_OUT=$("$ADB" $DEVICE root 2>&1 | tr -d '\r')
if ! echo "$ADBD_OUT" | grep -qE "adbd cannot run as root|error|failed"; then
    sleep 1
    probe "adb root"   "id" && ROOT_METHOD="adb_root"
fi
[[ "$ROOT_METHOD" == "NONE" ]] && probe "su -c id"   "su -c 'id'"   && ROOT_METHOD="su_c"
[[ "$ROOT_METHOD" == "NONE" ]] && probe "su 0 -c id" "su 0 -c 'id'" && ROOT_METHOD="su_0_c"
[[ "$ROOT_METHOD" == "NONE" ]] && probe "su 0 id"    "su 0 id"      && ROOT_METHOD="su_0"
[[ "$ROOT_METHOD" == "NONE" ]] && probe "plain shell" "id"           && ROOT_METHOD="shell_root"

[[ "$ROOT_METHOD" == "NONE" ]] \
    && log_warn "No root — acquisition will be partial." \
    || log_ok "Root method: $ROOT_METHOD"

# -- Root shell helper ---------------------------------------------------------
adb_root_shell() {
    local cmd="$1"
    # su -c requires the entire command as a single quoted argument on the device.
    # Wrap in single quotes, escape any single quotes inside the command.
    local sq_cmd
    sq_cmd="'$(echo "$cmd" | sed "s/'/'\\\\''/g")'"
    case "$ROOT_METHOD" in
        adb_root|shell_root) "$ADB" $DEVICE shell "$cmd" ;;
        su_c)                "$ADB" $DEVICE shell "su -c $sq_cmd" ;;
        su_0_c)              "$ADB" $DEVICE shell "su 0 -c $sq_cmd" ;;
        su_0)                "$ADB" $DEVICE shell "su 0 $sq_cmd" ;;
        NONE)                "$ADB" $DEVICE shell "$cmd" ;;
    esac
}

# -- Pull a remote path via tar stream ----------------------------------------
# Strategy: tar -C <parent_of_src> <basename_of_src>
#   → archive root is just the basename, no absolute path prefix
#   → extract into <dest>/ so result is <dest>/<basename>/...
#
# This correctly preserves the full internal folder tree regardless of
# how deep the source path is on the device.
pull_path() {
    local src="$1"        # /data/user/0/com.app
    local dest="$2"       # .../app_data/data/user/0/com.app
    local label="${3:-$src}"

    local parent name
    parent=$(dirname "$src")
    name=$(basename "$src")

    # To prevent nesting, we extract to the parent of the destination
    local local_dest_parent
    local_dest_parent=$(dirname "$dest")
    mkdir -p "$local_dest_parent"

    log_info "Pulling: $label"

    # --overwrite ensures we update existing files on the SSD instead of nesting
    if adb_root_shell "tar -C '$parent' -czf - '$name' 2>/dev/null" \
            | tar -xzf - -C "$local_dest_parent" --overwrite 2>/dev/null; then
        log_ok "Pulled: $label"
    else
        log_warn "Partial pull (some files may be unreadable): $label"
    fi
}

# -- Locate all unique data directories for this package -----------------------
log_step "Locating data directories"

# All known Android locations where app data can live:
#   /data/data/<pkg>                      primary (legacy / symlink)
#   /data/user/0/<pkg>                    CE user 0  (same as data/data on most)
#   /data/user/<N>/<pkg>                  CE work profile / multi-user
#   /data/user_de/0/<pkg>                 DE (device encrypted / direct boot)
#   /data/user_de/<N>/<pkg>               DE work profile / multi-user
#   /data_mirror/data_ce/null/<pkg>       CE mirror (Android 11+)
#   /data_mirror/data_de/null/<pkg>       DE mirror (Android 11+)
#   /data/media/0/Android/data/<pkg>      external scoped storage
#   /storage/emulated/0/Android/data/<pkg> external (alternate mount point)
SEARCH_ROOTS=(
    "/data/data"
    "/data/user"
    "/data/user_de"
    "/data_mirror/data_ce"
    "/data_mirror/data_de"
    "/data/media"
    "/storage/emulated"
)

declare -A seen_inodes
FOUND_PATHS=()

for root in "${SEARCH_ROOTS[@]}"; do
    # maxdepth 3 covers: root/<user_id>/<pkg> and root/<pkg>
    while IFS= read -r found; do
        found=$(echo "$found" | tr -d '\r')
        [[ -z "$found" ]] && continue

        inode=$(adb_root_shell "stat -c %i '$found' 2>/dev/null" | tr -d '\r')
        if [[ -n "$inode" && -z "${seen_inodes[$inode]:-}" ]]; then
            seen_inodes[$inode]="$found"
            FOUND_PATHS+=("$found")
            log_info "Found: $found  (inode $inode)"
        else
            log_info "Skipped duplicate (inode $inode): $found"
        fi
    done < <(adb_root_shell "find '$root' -type d -name '$APP' 2>/dev/null" || true)
done

if [[ ${#FOUND_PATHS[@]} -eq 0 ]]; then
    log_warn "No data directories found for $APP."
    log_warn "App may not have been launched yet, or root access is insufficient."
else
    log_ok "${#FOUND_PATHS[@]} unique data location(s) found."
fi

# -- Pull all located directories ----------------------------------------------
# WAL and SHM files live inside these dirs and are captured automatically.
log_step "Pulling app data"

for path in "${FOUND_PATHS[@]}"; do
    # Mirror device path under app_data/ preserving structure:
    # /data/user/0/com.app  →  <out>/app_data/data/user/0/com.app/
    local_rel="${path#/}"                          # strip leading /
    pull_path "$path" "$OUT_DIR/app_data/$local_rel" "$path"
done

# -- APK(s) -------------------------------------------------------------------
log_step "APK"

mkdir -p "$OUT_DIR/apk"
# Clear hash file before loop — prevents accumulation across snapshots
# For split APKs each base.apk/split_*.apk gets its own line appended
> "$OUT_DIR/apk/apk.sha256"
# pm path returns one line per split APK: "package:/path/to/file.apk"
while IFS= read -r apk_line; do
    apk_line=$(echo "$apk_line" | tr -d '\r')
    [[ -z "$apk_line" ]] && continue
    APK_PATH=$(echo "$apk_line" | cut -d: -f2 | xargs)
    [[ -z "$APK_PATH" ]] && continue

    local_name=$(basename "$APK_PATH")
    local_apk="$OUT_DIR/apk/$local_name"
    adb_root_shell "cat '$APK_PATH'" > "$local_apk" 2>/dev/null \
        && log_ok "APK: $local_name" \
        || log_warn "Could not pull: $APK_PATH"

    # Append — supports split APKs, file is cleared before loop
    if [[ -f "$local_apk" ]]; then
        hash=$(sha256sum "$local_apk" | awk '{print $1}')
        echo "$hash  $local_name" >> "$OUT_DIR/apk/apk.sha256"
    fi
done < <(adb_root_shell "pm path '$APP' 2>/dev/null" || true)

if [[ -f "$OUT_DIR/apk/apk.sha256" ]]; then
    log_ok "APK hashes saved:"
    while IFS= read -r line; do log_info "  $line"; done < "$OUT_DIR/apk/apk.sha256"
else
    log_warn "No APK pulled."
fi

# -- Package metadata ----------------------------------------------------------
log_step "Package metadata"

mkdir -p "$OUT_DIR/meta"

"$ADB" $DEVICE shell dumpsys package "$APP" 2>/dev/null \
    > "$OUT_DIR/meta/dumpsys_package.txt" \
    && log_ok "dumpsys_package.txt" \
    || log_warn "dumpsys package failed"

# All declared permissions
grep -E "^\s*(uses-permission|permission\.|grantedPermissions|android\.permission)" \
    "$OUT_DIR/meta/dumpsys_package.txt" 2>/dev/null \
    | sed 's/^[[:space:]]*//' | sort -u \
    > "$OUT_DIR/meta/permissions.txt" || true

# Granted runtime permissions only — useful for diffing across snapshots
grep "granted=true" "$OUT_DIR/meta/dumpsys_package.txt" 2>/dev/null \
    | sed 's/^[[:space:]]*//' | sort -u \
    > "$OUT_DIR/meta/permissions_granted.txt" || true

log_ok "permissions.txt and permissions_granted.txt"

# -- Network config ------------------------------------------------------------
log_step "Network config"

# Resolve app UID from packages.list for targeted keystore/net lookups
APP_UID=$(adb_root_shell "grep '^$APP ' /data/system/packages.list 2>/dev/null | awk '{print \$2}'" | tr -d '\r')

if [[ -n "$APP_UID" ]]; then
    log_info "App UID: $APP_UID"
    mkdir -p "$OUT_DIR/network"

    for net_root in "/data/misc/net" "/data/misc/keystore"; do
        while IFS= read -r f; do
            f=$(echo "$f" | tr -d '\r')
            [[ -z "$f" ]] && continue
            dest="$OUT_DIR/network/$(basename "$net_root")"
            mkdir -p "$dest"
            adb_root_shell "cat '$f'" > "$dest/$(basename "$f")" 2>/dev/null \
                && log_info "Network file: $f" \
                || true
        done < <(adb_root_shell "find '$net_root' -name '*${APP_UID}*' -type f 2>/dev/null" || true)
    done
else
    log_warn "Could not resolve app UID — skipping keystore/net lookups."
fi

# Note cert/ssl files already captured inside app_data
for path in "${FOUND_PATHS[@]}"; do
    while IFS= read -r f; do
        f=$(echo "$f" | tr -d '\r')
        [[ -z "$f" ]] && continue
        log_info "Network-related file in app_data: $f"
    done < <(adb_root_shell "find '$path' \( -name '*cert*' -o -name '*network*' -o -name '*ssl*' -o -name '*.pem' -o -name '*.crt' \) -type f 2>/dev/null" || true)
done

# -- Done ----------------------------------------------------------------------
log_sep
log_ok "Acquisition complete → $OUT_DIR"
log_sep
