#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-report.sh - SQLite introspector
# Walks all .db files in a case, extracts schema + stats, writes JSON + text
#
# Usage: ./db-report.sh <case_dir> <report_name>
# Output: <case_dir>/reports/<report_name>/db/
# -----------------------------------------------------------------------------
set -euo pipefail

if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_INFO='\033[0;36m'; C_OK='\033[0;32m'
    C_WARN='\033[0;33m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
else
    C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_BOLD=''; C_DIM=''
fi

log_info() { echo -e "${C_INFO}[Info ]${C_RESET} $*" >&2; }
log_ok()   { echo -e "${C_OK}[  OK ]${C_RESET} $*" >&2; }
log_warn() { echo -e "${C_WARN}[Warn ]${C_RESET} $*" >&2; }
log_err()  { echo -e "${C_ERR}[Error]${C_RESET} $*" >&2; }
log_step() { echo -e "\n${C_BOLD}-- $* ${C_RESET}" >&2; }
log_sep()  { echo -e "${C_DIM}----------------------------------------${C_RESET}" >&2; }

[[ $# -lt 2 ]] && { echo "Usage: db-report.sh <case_dir> <report_name>"; exit 1; }

CASE_DIR="$1"
REPORT_NAME="$2"
REPORT_DB_DIR="$CASE_DIR/reports/$REPORT_NAME/db"

command -v sqlite3 &>/dev/null || { echo "[Warn] sqlite3 not found — skipping DB report"; exit 0; }

mkdir -p "$REPORT_DB_DIR"

# -- Find all .db files --------------------------------------------------------
log_step "Scanning databases"

mapfile -t DB_FILES < <(find "$CASE_DIR/data" -type f -exec sh -c 'file -b "$1" | grep -iq "SQLite"' _ {} \; -print)

if [[ ${#DB_FILES[@]} -eq 0 ]]; then
    log_warn "No database files found."
    echo "[]" > "$REPORT_DB_DIR/databases.json"
    exit 0
fi

log_ok "Found ${#DB_FILES[@]} database(s)"

SAMPLE_ROWS=5

inspect_db() {
    local db_path="$1"
    local rel_path="${db_path#$CASE_DIR/}"
    local db_name
    db_name=$(basename "$db_path")
    local db_size
    db_size=$(wc -c < "$db_path" 2>/dev/null || echo 0)

    log_info "Inspecting: $rel_path"

    # Validate SQLite magic header
    if ! head -c 15 "$db_path" 2>/dev/null | grep -q "SQLite format"; then
        log_warn "Not a valid SQLite file: $db_name"
        printf '{"path":"%s","name":"%s","error":"not_sqlite","size_bytes":%s}\n' \
            "$(echo "$rel_path" | sed 's/"/\\"/g')" \
            "$(echo "$db_name"  | sed 's/"/\\"/g')" \
            "$db_size"
        return
    fi

    # Copy DB + WAL/SHM to temp so sqlite3 opens cleanly.
    # Locally pulled WAL without matching SHM causes sqlite3 to fail
    # reading any tables due to incomplete journal recovery.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    local tmp_db="$tmp_dir/$db_name"
    cp "$db_path" "$tmp_db"
    [[ -f "${db_path}-wal" ]] && cp "${db_path}-wal" "${tmp_db}-wal" || true
    [[ -f "${db_path}-shm" ]] && cp "${db_path}-shm" "${tmp_db}-shm" || true
    # If WAL exists but no SHM, sqlite3 needs a blank SHM to open
    if [[ -f "${tmp_db}-wal" && ! -f "${tmp_db}-shm" ]]; then
        touch "${tmp_db}-shm"
    fi

    local has_wal=false
    [[ -f "${db_path}-wal" ]] && has_wal=true

    # Basic pragmas
    local page_size encoding sqlite_ver
    page_size=$(sqlite3 "$tmp_db" "PRAGMA page_size;" 2>/dev/null || echo "0")
    encoding=$(sqlite3  "$tmp_db" "PRAGMA encoding;"  2>/dev/null || echo "?")
    sqlite_ver=$(sqlite3 "$tmp_db" "SELECT sqlite_version();" 2>/dev/null || echo "?")

    # Tables
    local tables
    mapfile -t tables < <(sqlite3 "$tmp_db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" \
        2>/dev/null || true)

    # Remove empty entries
    local clean_tables=()
    for t in "${tables[@]}"; do
        [[ -n "$t" ]] && clean_tables+=("$t")
    done
    tables=("${clean_tables[@]+"${clean_tables[@]}"}")

    local trigger_count view_count
    trigger_count=$(sqlite3 "$tmp_db" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger';" 2>/dev/null || echo 0)
    view_count=$(sqlite3    "$tmp_db" "SELECT COUNT(*) FROM sqlite_master WHERE type='view';"    2>/dev/null || echo 0)

    # Build tables JSON
    local tables_json="["
    local first_table=true

    for table in "${tables[@]}"; do
        [[ -z "$table" ]] && continue

        local row_count
        row_count=$(sqlite3 "$tmp_db" "SELECT COUNT(*) FROM \"${table//\"/\\\"}\";" 2>/dev/null || echo 0)
        row_count=$(echo "$row_count" | tr -d '[:space:]')

        # Columns via PRAGMA
        local cols_json="["
        local first_col=true
        while IFS='|' read -r cid col_name col_type notnull dflt_val pk; do
            [[ -z "$col_name" ]] && continue
            $first_col || cols_json+=","
            cols_json+=$(printf '{"cid":%s,"name":"%s","type":"%s","notnull":%s,"pk":%s}' \
                "${cid:-0}" \
                "$(echo "$col_name" | sed 's/"/\\"/g')" \
                "$(echo "${col_type:-TEXT}" | sed 's/"/\\"/g')" \
                "$([[ "${notnull:-0}" == "1" ]] && echo true || echo false)" \
                "$([[ "${pk:-0}" != "0" ]] && echo true || echo false)")
            first_col=false
        done < <(sqlite3 "$tmp_db" "PRAGMA table_info(\"${table//\"/\\\"}\");" 2>/dev/null || true)
        cols_json+="]"

        # Sample rows — output as pipe-separated, one row per line
        local sample_json="["
        local first_row=true
        while IFS= read -r row; do
            [[ -z "$row" ]] && continue
            $first_row || sample_json+=","
            local escaped
            escaped=$(printf '%s' "$row" | sed 's/\\/\\\\/g; s/"/\\"/g')
            sample_json+="\"$escaped\""
            first_row=false
        done < <(sqlite3 -separator " | " "$tmp_db" \
            "SELECT * FROM \"${table//\"/\\\"}\" LIMIT $SAMPLE_ROWS;" 2>/dev/null || true)
        sample_json+="]"

        # Indexes
        local idx_json="["
        local first_idx=true
        while IFS= read -r idx; do
            [[ -z "$idx" ]] && continue
            $first_idx || idx_json+=","
            idx_json+="\"$(echo "$idx" | sed 's/"/\\"/g')\""
            first_idx=false
        done < <(sqlite3 "$tmp_db" \
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='${table//\'/\'\'}' AND name NOT LIKE 'sqlite_%';" \
            2>/dev/null || true)
        idx_json+="]"

        $first_table || tables_json+=","
        tables_json+=$(printf '{"name":"%s","row_count":%s,"columns":%s,"indexes":%s,"sample":%s}' \
            "$(echo "$table" | sed 's/"/\\"/g')" \
            "${row_count:-0}" \
            "$cols_json" \
            "$idx_json" \
            "$sample_json")
        first_table=false
    done
    tables_json+="]"

    printf '{"path":"%s","name":"%s","size_bytes":%s,"sqlite_version":"%s","page_size":%s,"encoding":"%s","table_count":%s,"trigger_count":%s,"view_count":%s,"has_wal":%s,"tables":%s}\n' \
        "$(echo "$rel_path" | sed 's/"/\\"/g')" \
        "$(echo "$db_name"  | sed 's/"/\\"/g')" \
        "$db_size" \
        "$sqlite_ver" \
        "${page_size:-0}" \
        "$encoding" \
        "${#tables[@]}" \
        "${trigger_count:-0}" \
        "${view_count:-0}" \
        "$has_wal" \
        "$tables_json"
}

# -- Run and collect JSON ------------------------------------------------------
ALL_JSON="["
first=true
for db in "${DB_FILES[@]}"; do
    result=$(inspect_db "$db")
    $first || ALL_JSON+=","
    ALL_JSON+="$result"
    first=false
done
ALL_JSON+="]"

echo "$ALL_JSON" > "$REPORT_DB_DIR/databases.json"
log_ok "databases.json → $REPORT_DB_DIR/databases.json"

# -- Plain text summary --------------------------------------------------------
{
    echo "Database Report — $REPORT_NAME"
    echo "Case: $CASE_DIR"
    echo "════════════════════════════════════════"
    for db in "${DB_FILES[@]}"; do
        rel="${db#$CASE_DIR/}"
        echo ""
        echo "DATABASE: $rel"
        echo "  Size: $(wc -c < "$db" 2>/dev/null || echo '?') bytes"
        tmp2=$(mktemp)
        cp "$db" "$tmp2"

        [[ -f "${db}-wal" ]] && cp "${db}-wal" "${tmp2}-wal" || true
        [[ -f "${db}-shm" ]] && cp "${db}-shm" "${tmp2}-shm" || true
        [[ -f "${tmp2}-wal" && ! -f "${tmp2}-shm" ]] && touch "${tmp2}-shm" || true

        echo "  Tables:"
        sqlite3 "$tmp2" \
            "SELECT '    - ' || name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" \
            2>/dev/null || echo "    (could not read)"
        rm -f "$tmp2" "${tmp2}-wal" "${tmp2}-shm"
    done
} > "$REPORT_DB_DIR/databases.txt"

log_ok "databases.txt → $REPORT_DB_DIR/databases.txt"
log_sep
log_ok "DB report done"
