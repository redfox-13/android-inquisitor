#!/bin/bash

# --- ANSI Color Codes ---
CLR_RESET="\e[0m"
CLR_LINE="\e[90m"     # Dim Gray for tree lines
CLR_DIR="\e[34;1m"    # Bold Blue for directories
CLR_DB="\e[0m"        # Default for main databases
CLR_AV="\e[33m"       # Yellow for auto_vacuum info
CLR_SIDE="\e[31m"     # Red/Orange for extra sidecars
CLR_STAT="\e[36;1m"   # Cyan for the final summary

# --- Default Flag Settings ---
SHOW_AV=false
SHOW_EXTRA=false

# --- Parse Arguments ---
TARGET_DIR="."
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--av)
            SHOW_AV=true
            shift
            ;;
        -e|--extra)
            SHOW_EXTRA=true
            shift
            ;;
        -a|--all)
            SHOW_AV=true
            SHOW_EXTRA=true
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [target_dir] [-v|--av] [-e|--extra] [-a|--all]" >&2
            exit 1
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

TARGET_DIR="${TARGET_DIR%/}"

echo -e "${CLR_DIR}$TARGET_DIR/${CLR_RESET}"
TOTAL_DB_COUNT=0

get_auto_vacuum() {
    local db_file="$1"
    local av_status=$(od -An -j 64 -N 4 -D "$db_file" 2>/dev/null | tr -d '[:space:]')
    case "$av_status" in
        0) echo "0 - NONE" ;;
        1) echo "1 - FULL" ;;
        2) echo "2 - INCREMENTAL" ;;
        *) echo "UNKNOWN (corrupted or encrypted)" ;;
    esac
}

# Arguments: $1 = sub_prefix, $2 = item/db_path, $3 = db_name
show_metadata_block() {
    local sub_prefix="$1"
    local item="$2"
    local db_name="$3"

    local meta_lines=()

    # 1. Evaluate auto_vacuum
    if [ "$SHOW_AV" = true ]; then
        local av_info=$(get_auto_vacuum "$item")
        meta_lines+=("${CLR_AV}auto_vacuum: ${av_info}${CLR_RESET}")
    fi

    # 2. Evaluate extras
    if [ "$SHOW_EXTRA" = true ]; then
        [ -f "${item}-wal" ] && meta_lines+=("${CLR_SIDE}extra-wal: ${db_name}-wal${CLR_RESET}")
        [ -f "${item}-shm" ] && meta_lines+=("${CLR_SIDE}extra-shm: ${db_name}-shm${CLR_RESET}")
        [ -f "${item}-journal" ] && meta_lines+=("${CLR_SIDE}extra-journal: ${db_name}-journal${CLR_RESET}")
    fi

    local total_meta=${#meta_lines[@]}
    if [ $total_meta -gt 0 ]; then
        local colored_sub_prefix="${sub_prefix//│/${CLR_LINE}│${CLR_RESET}}"
        local idx=0
        for line in "${meta_lines[@]}"; do
            ((idx++))
            if [ $idx -eq $total_meta ]; then
                echo -e "${colored_sub_prefix}${CLR_LINE}└── ${line}"
            else
                echo -e "${colored_sub_prefix}${CLR_LINE}├── ${line}"
            fi
        done
    fi
}

walk_tree() {
    local current_dir="$1"
    local prefix="$2"

    local raw_items=()
    while IFS= read -r item; do
        [ -n "$item" ] && raw_items+=("$item")
    done < <(find "$current_dir" -maxdepth 1 -not -path "$current_dir" | sort)

    local items=()
    for item in "${raw_items[@]}"; do
        if [ -d "$item" ]; then
            if find "$item" -type f | while read -r f; do file "$f"; done | grep -q "SQLite 3"; then
                items+=("$item")
            fi
        elif [ -f "$item" ]; then
            case "$item" in
                *-wal|*-shm|*-journal) continue ;;
            esac
            if file "$item" | grep -q "SQLite 3"; then
                items+=("$item")
            fi
        fi
    done

    local count=${#items[@]}
    local i=0

    for item in "${items[@]}"; do
        ((i++))

        local pointer="├── "
        local sub_prefix="${prefix}│   "
        if [ $i -eq $count ]; then
            pointer="└── "
            sub_prefix="${prefix}    "
        fi

        local colored_pointer="${CLR_LINE}${pointer}${CLR_RESET}"
        local colored_prefix=""
        if [ -n "$prefix" ]; then
            colored_prefix="${prefix//│/${CLR_LINE}│${CLR_RESET}}"
        fi

        if [ -d "$item" ]; then
            echo -e "${colored_prefix}${colored_pointer}${CLR_DIR}$(basename "$item")/${CLR_RESET}"
            walk_tree "$item" "$sub_prefix"
        elif [ -f "$item" ]; then
            local db_name=$(basename "$item")
            echo -e "${colored_prefix}${colored_pointer}${CLR_DB}${db_name}${CLR_RESET}"

            ((TOTAL_DB_COUNT++))

            # Consolidated function call replaces old messy if/else block
            show_metadata_block "$sub_prefix" "$item" "$db_name"
        fi
    done
}

walk_tree "$TARGET_DIR" ""
echo ""
echo -e "${CLR_STAT}◆ Total Count: $TOTAL_DB_COUNT${CLR_RESET}"
