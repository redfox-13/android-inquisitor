#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# snapshot.sh - Android Forensic Tool - Main Entrypoint
#
# Usage:
#   ./snapshot.sh new-case    <package> [-d|-e]
#   ./snapshot.sh add-package <case_id> <package> [-d|-e]
#   ./snapshot.sh snap        <case_id> [-d|-e]
#   ./snapshot.sh report      <case_id>
#   ./snapshot.sh list
#
# Snapshot flow:
#   1. Pull data for all packages in case
#   2. Build new manifest (sha256 of all files)
#   3. Compare with previous manifest - log diff
#   4. Update manifest + packages.txt + meta
#   5. git commit (always - evidence integrity)
#   6. Run report tools
#
# Environment:
#   ADB=<path>        override adb binary
#   CASES_DIR=<path>  override cases root (default: ./cases)
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES_DIR="${CASES_DIR:-$SCRIPT_DIR/cases}"

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

# -- Usage ---------------------------------------------------------------------
usage() {
    echo -e "${C_BOLD}Android Forensic Tool${C_RESET}"
    echo ""
    echo -e "${C_BOLD}Usage:${C_RESET}"
    echo "  $0 new-case    <package> [-d|-e]             Create new case + first snapshot"
    echo "  $0 add-package <case_id> <package> [-d|-e]   Add package to existing case"
    echo "  $0 snap        <case_id> [-d|-e]             Take snapshot + commit + report"
    echo "  $0 report      <case_id>                     Regenerate latest report"
    echo "  $0 list                                      List all cases"
    echo ""
    echo -e "${C_BOLD}Device flags:${C_RESET}"
    echo "  -e  emulator (default)"
    echo "  -d  USB device"
    echo ""
    echo -e "${C_BOLD}Environment:${C_RESET}"
    echo "  ADB=<path>        override adb binary"
    echo "  CASES_DIR=<path>  override cases root (default: ./cases)"
    exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -lt 1 ]] && { log_err "Missing command."; echo ""; usage; }

COMMAND="$1"; shift

# -- ADB setup -----------------------------------------------------------------
setup_adb() {
    if [[ -n "${ADB:-}" ]]; then
        [[ ! -f "$ADB" ]] && die "ADB override '$ADB' does not exist."
        [[ ! -x "$ADB" ]] && die "ADB override '$ADB' is not executable."
    else
        ADB=$(command -v adb 2>/dev/null) \
            || die "'adb' not found in PATH."
    fi
    ADB_VER=$("$ADB" version 2>/dev/null | head -1)
    [[ -z "$ADB_VER" ]] && die "'$ADB' did not produce version output."
    log_ok "ADB: $ADB_VER"
}

# -- Device flag ---------------------------------------------------------------
parse_device_flag() {
    DEVICE="${1:--e}"
    case "$DEVICE" in
        -e) DEVNAME="emu" ;;
        -d) DEVNAME="usb" ;;
        *)  die "Unknown device flag \"$DEVICE\". Use -e or -d." ;;
    esac
}

# -- Resolve exact package ID from device (incl. ==hash suffix) ---------------
resolve_package_id() {
    local search="$1"
    local matches

    matches=$("$ADB" $DEVICE shell pm list packages 2>/dev/null \
        | grep "$search" | cut -d: -f2 | tr -d '\r')

    local count
    count=$(echo "$matches" | grep -c . || true)

    [[ -z "$matches" ]] && die "No packages found matching \"$search\"."
 
    if [[ "$count" -ge 2 ]]; then
        log_warn "$count matches — narrow down the search term:"
        echo "$matches" | while read -r p; do echo "      $p"; done
        die "Ambiguous match."
    fi
 
    echo "$matches"
}

# -- Auto-detect sibling packages (bundle) ------------------------------------
detect_siblings() {
    local base_pkg="$1"
    local base_name
    base_name=$(echo "$base_pkg" | sed 's/==.*//')
    "$ADB" $DEVICE shell pm list packages 2>/dev/null \
        | grep "$base_name" | cut -d: -f2 | tr -d '\r' \
        | grep -v "^${base_pkg}$" || true
}

# -- Init case git repo --------------------------------------------------------
init_case_repo() {
    local case_dir="$1"

    mkdir -p "$case_dir/data" "$case_dir/reports"

    # Whitelist gitignore — only evidence tracked, everything else ignored
    # Analyst can freely add notes.txt, exports, etc. without polluting git
    cat > "$case_dir/.gitignore" << 'EOF'
# Ignore everything by default — whitelist approach for evidence integrity
*

# Track only evidence
!.gitignore
!packages.txt
!manifest.sha256
!data/
!data/**
EOF

    git -C "$case_dir" init -q
    git -C "$case_dir" config user.name  "forensic-android"
    git -C "$case_dir" config user.email "forensic@local"

    log_ok "Git repo initialised: $case_dir"
}

# -- Write case.json — analyst metadata, never committed ----------------------
write_case_json() {
    local case_dir="$1" case_id="$2" device_info="$3" android_ver="$4"
    cat > "$case_dir/case.json" << EOF
{
  "case_id": "$case_id",
  "created": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "device": "$device_info",
  "android_version": "$android_ver",
  "investigator": "",
  "notes": ""
}
EOF
    log_info "case.json written (not tracked by git)"
}

# -- Build manifest of all files under data/ -----------------------------------
build_manifest() {
    local case_dir="$1"
    local manifest="$case_dir/manifest.sha256"
    local prev_manifest="$case_dir/manifest.sha256.old"

    # 1. Move current manifest to .prev BEFORE generating a new one
    [[ -f "$manifest" ]] && mv "$manifest" "$prev_manifest"

    # 2. Generate the fresh manifest
    (cd "$case_dir" && find data -type f | sort | xargs sha256sum 2>/dev/null > manifest.sha256) || true
}

# -- Compare manifests — returns 0 if changed, 1 if identical -----------------
compare_manifests() {
    local case_dir="$1"
    local manifest="$case_dir/manifest.sha256"
    local prev="$case_dir/manifest.sha256.old"

    if [[ ! -f "$prev" ]]; then
        log_info "No previous manifest — first snapshot."
        return 0  # changed (first run)
    fi

    if diff -q "$prev" "$manifest" &>/dev/null; then
        log_warn "Manifest identical to previous snapshot — no data changed."
        return 1  # no change
    fi

    # Show summary of what changed
    local added removed modified
    added=$(diff "$prev" "$manifest"   | grep "^>" | wc -l | xargs)
    removed=$(diff "$prev" "$manifest" | grep "^<" | wc -l | xargs)
    log_info "Manifest diff — added/modified: $added  removed: $removed"
    return 0  # changed
}

# -- Core snapshot logic -------------------------------------------------------
_do_snapshot() {
    local case_dir="$1"
    local device_flag="$2"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Device info for commit message
    local android_ver device_model device_brand
    android_ver=$("$ADB" $DEVICE shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
    device_model=$("$ADB"  $DEVICE shell getprop ro.product.model       2>/dev/null | tr -d '\r')
    device_brand=$("$ADB"  $DEVICE shell getprop ro.product.brand       2>/dev/null | tr -d '\r')

    # -- Step 1: Pull data for all packages ------------------------------------
    log_step "Step 1/5 — Acquiring data"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        log_step "Package: $pkg"
        "$SCRIPT_DIR/acquisition.sh" "$pkg" "$device_flag" "$case_dir/data/$pkg" \
            || log_warn "Acquisition issues for $pkg — partial data may exist"
    done < "$case_dir/packages.txt"

    # -- Step 2: Build manifest + compare -------------------------------------
    log_step "Step 2/5 — Manifest"
    build_manifest "$case_dir"

    local manifest_changed=true
    compare_manifests "$case_dir" || manifest_changed=false

    # -- Step 3: Update packages.txt + meta (always current) ------------------
    log_step "Step 3/5 — Updating metadata"
    # packages.txt is already up to date (managed by new-case / add-package)
    # Write snapshot log entry for analyst reference (not tracked)
    mkdir -p "$case_dir/reports"
    echo "$timestamp | $device_brand $device_model | Android $android_ver | changed=$manifest_changed" \
        >> "$case_dir/snapshot.log"
    log_ok "snapshot.log updated"

    # Clean up temp prev manifest
    rm -f "$case_dir/manifest.sha256.old"

    # -- Step 4: Git commit (conditional) --------------------------------------
    log_step "Step 4/5 — Git commit"

    # Check if this is the first commit
    local is_first_commit=false
    if ! git -C "$case_dir" rev-parse HEAD &>/dev/null; then
        is_first_commit=true
    fi

    # Commit if it's the first run OR if data has changed
    if [[ "$is_first_commit" == "true" ]] || ! git -C "$case_dir" diff --quiet data/ manifest.sha256 2>/dev/null; then
        git -C "$case_dir" add -A -- .gitignore packages.txt manifest.sha256 data/ 2>/dev/null || true

        local change_note="DATA CHANGED"
        [[ "$is_first_commit" == "true" ]] && change_note="INITIAL ACQUISITION"

        local commit_msg="snapshot: $timestamp | $device_brand $device_model (Android $android_ver) | $change_note"

        git -C "$case_dir" commit -m "$commit_msg" -q
        commit_sha=$(git -C "$case_dir" rev-parse --short HEAD)
        log_ok "Committed: $commit_sha — $commit_msg"
    else
        log_warn "No data changes detected — skipping commit to save SSD usage."
        commit_sha=$(git -C "$case_dir" rev-parse --short HEAD || echo "none")
    fi

    # -- Step 5: Report --------------------------------------------------------
    REPORT_DIR="$case_dir/reports/$timestamp"
    mkdir -p "$REPORT_DIR/db"

    "$SCRIPT_DIR/db_report.sh"  "$case_dir" "$timestamp" || log_warn "DB report issues"
    "$SCRIPT_DIR/report.sh"     "$case_dir" "$timestamp" || log_warn "HTML report issues"

    log_sep
    log_ok "Snapshot complete → $case_dir"
    log_info "Commit: $commit_sha"
    log_info "Report: $case_dir/reports/$timestamp/report.html"
    log_sep
}

# -- new-case ------------------------------------------------------------------
cmd_new_case() {
    [[ $# -lt 1 ]] && die "Usage: $0 new-case <package> [-d|-e]"
    local search="$1"
    local device_flag="${2:--e}"

    setup_adb
    parse_device_flag "$device_flag"

    log_step "Resolving package"
    local pkg
    pkg=$(resolve_package_id "$search")
    log_ok "Primary package: $pkg"

    local case_id="$pkg"
    local case_dir="$CASES_DIR/$case_id"

    [[ -d "$case_dir/.git" ]] && die "Case already exists: $case_id\nUse: $0 snap \"$case_id\""

    # Device info
    local android_ver device_model device_brand
    android_ver=$("$ADB" $DEVICE shell getprop ro.build.version.release | tr -d '\r')
    device_model=$("$ADB" $DEVICE shell getprop ro.product.model       | tr -d '\r')
    device_brand=$("$ADB" $DEVICE shell getprop ro.product.brand       | tr -d '\r')
    log_info "Device: $device_brand $device_model (Android $android_ver)"

    # Bundle / sibling detection
    log_step "Bundle detection"
    local siblings
    siblings=$(detect_siblings "$pkg")
    local all_packages=("$pkg")

    if [[ -n "$siblings" ]]; then
        log_warn "Related packages found:"
        echo "$siblings" | while read -r s; do echo "      $s"; done
        echo ""
        read -rp "$(echo -e "${C_BOLD}Add to this case? [Y=all / n=skip / s=select]:${C_RESET} ")" choice
        choice="${choice:-Y}"

        if [[ "$choice" =~ ^[Yy]$ ]]; then
            while IFS= read -r s; do
                [[ -n "$s" ]] && all_packages+=("$s")
            done <<< "$siblings"
            log_ok "All related packages added."
        elif [[ "$choice" =~ ^[Ss]$ ]]; then
            echo "Enter package names to include (one per line, empty to finish):"
            while IFS= read -r line; do
                [[ -z "$line" ]] && break
                all_packages+=("$line")
            done
            log_ok "${#all_packages[@]} package(s) selected."
        else
            log_info "Only primary package included."
        fi
    else
        log_info "No sibling packages detected."
    fi

    # Init repo (writes .gitignore before any commit)
    log_step "Initialising case"
    init_case_repo "$case_dir"
    write_case_json "$case_dir" "$case_id" "$device_brand $device_model" "$android_ver"

    printf '%s\n' "${all_packages[@]}" > "$case_dir/packages.txt"
    log_ok "packages.txt: ${#all_packages[@]} package(s)"

    # First snapshot
    _do_snapshot "$case_dir" "$device_flag"
}

# -- add-package ---------------------------------------------------------------
cmd_add_package() {
    [[ $# -lt 2 ]] && die "Usage: $0 add-package <case_id> <package> [-d|-e]"
    local case_id="$1" search="$2" device_flag="${3:--e}"
    local case_dir="$CASES_DIR/$case_id"

    [[ ! -d "$case_dir/.git" ]] && die "Case not found: $case_id"

    setup_adb
    parse_device_flag "$device_flag"

    local pkg
    pkg=$(resolve_package_id "$search")
    log_ok "Package: $pkg"

    if grep -qF "$pkg" "$case_dir/packages.txt" 2>/dev/null; then
        die "Package already in case: $pkg"
    fi

    echo "$pkg" >> "$case_dir/packages.txt"
    log_ok "Added $pkg to case $case_id"
    log_info "Run: $0 snap \"$case_id\" to pull data for the new package."
}

# -- snap ----------------------------------------------------------------------
cmd_snap() {
    [[ $# -lt 1 ]] && die "Usage: $0 snap <case_id> [-d|-e]"
    local case_id="$1" device_flag="${2:--e}"
    local case_dir="$CASES_DIR/$case_id"

    [[ ! -d "$case_dir/.git" ]] && die "Case not found: $case_id"

    setup_adb
    parse_device_flag "$device_flag"

    _do_snapshot "$case_dir" "$device_flag"
}

# -- report --------------------------------------------------------------------
cmd_report() {
    [[ $# -lt 1 ]] && die "Usage: $0 report <case_id>"
    local case_id="$1"
    local case_dir="$CASES_DIR/$case_id"
    [[ ! -d "$case_dir/.git" ]] && die "Case not found: $case_id"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    "$SCRIPT_DIR/db_report.sh" "$case_dir" "$timestamp" || true
    "$SCRIPT_DIR/report.sh"    "$case_dir" "$timestamp"
}

# -- list ----------------------------------------------------------------------
cmd_list() {
    log_step "Cases in $CASES_DIR"
    if [[ ! -d "$CASES_DIR" ]] || [[ -z "$(ls -A "$CASES_DIR" 2>/dev/null)" ]]; then
        log_warn "No cases found."
        return
    fi
    for case_dir in "$CASES_DIR"/*/; do
        [[ ! -d "$case_dir/.git" ]] && continue
        local case_id commit_count last_commit pkg_count
        case_id=$(basename "$case_dir")
        commit_count=$(git -C "$case_dir" rev-list --count HEAD 2>/dev/null || echo "0")
        last_commit=$(git  -C "$case_dir" log -1 --format="%ci"             2>/dev/null || echo "never")
        pkg_count=$(wc -l < "$case_dir/packages.txt"                        2>/dev/null || echo "?")
        echo -e "  ${C_BOLD}$case_id${C_RESET}"
        echo -e "    ${C_DIM}packages: $pkg_count | snapshots: $commit_count | last: $last_commit${C_RESET}"
    done
}

# -- Dispatch ------------------------------------------------------------------
case "$COMMAND" in
    new-case)    cmd_new_case    "$@" ;;
    add-package) cmd_add_package "$@" ;;
    snap)        cmd_snap        "$@" ;;
    report)      cmd_report      "$@" ;;
    list)        cmd_list ;;
    *) log_err "Unknown command: $COMMAND"; echo ""; usage ;;
esac
