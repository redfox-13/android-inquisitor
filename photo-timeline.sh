#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# photo_timeline.sh — Hash-deduplicate files from an Android directory,
# group identical content by first-seen time, show image inline if supported.
#
# Usage:
#   ./photo_timeline.sh <remote_dir> [-d|-e]
#   ./photo_timeline.sh <local_dir>
#
# Examples:
#   ./photo_timeline.sh /data/data/com.app/cache/contact_photos -e
#   ./photo_timeline.sh /data/data/com.app/cache/contact_photos -d
#   ./photo_timeline.sh ./pulled_cache          # local directory
#
# Output:
#   Groups of files sharing identical content, sorted by first appearance.
#   Each group shows: [FIRST SEEN] hash, all filenames with their timestamps.
#   Images rendered inline if terminal supports Kitty/iTerm2/Sixel protocol.
#
# Environment:
#   ADB=/path/to/adb   override adb binary
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_INFO='\033[0;36m'; C_OK='\033[0;32m'
    C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_BOLD='\033[1m'
    C_DIM='\033[2m';    C_PURPLE='\033[0;35m'; C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
else
    C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_BOLD=''
    C_DIM='';   C_PURPLE=''; C_YELLOW=''; C_BLUE=''
fi

log_info() { echo -e "${C_INFO}[Info ]${C_RESET} $*" >&2; }
log_ok()   { echo -e "${C_OK}[  OK ]${C_RESET} $*" >&2; }
log_warn() { echo -e "${C_WARN}[Warn ]${C_RESET} $*" >&2; }
log_err()  { echo -e "${C_ERR}[Error]${C_RESET} $*"; }
log_step() { echo -e "\n${C_BOLD}── $* ──${C_RESET}" >&2; }
die()      { log_err "$*"; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    echo -e "${C_BOLD}photo_timeline.sh${C_RESET} — File identity timeline from Android cache"
    echo ""
    echo -e "${C_BOLD}Usage:${C_RESET}"
    echo "  $0 <remote_path> [-d|-e]   Pull from Android device and analyse"
    echo "  $0 <local_path>            Analyse a local directory directly"
    echo ""
    echo -e "${C_BOLD}Device flags:${C_RESET}"
    echo "  -e  emulator (default)"
    echo "  -d  USB device"
    echo ""
    echo -e "${C_BOLD}Options:${C_RESET}"
    echo "  --no-image   Skip inline image rendering even if terminal supports it"
    echo "  --keep       Keep pulled files in ./photo_timeline_pull/ after analysis"
    echo ""
    echo -e "${C_BOLD}Environment:${C_RESET}"
    echo "  ADB=/path/to/adb   override adb binary"
    exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -lt 1 ]] && { log_err "Missing argument."; usage; }

# ── Parse args ────────────────────────────────────────────────────────────────
REMOTE_PATH=""
LOCAL_PATH=""
DEVICE="-e"
NO_IMAGE=false
KEEP_FILES=false

for arg in "$@"; do
    case "$arg" in
        -e) DEVICE="-e" ;;
        -d) DEVICE="-d" ;;
        --no-image) NO_IMAGE=true ;;
        --keep) KEEP_FILES=true ;;
        -*) log_warn "Unknown flag: $arg" ;;
        *)
            if [[ -d "$arg" ]]; then
                LOCAL_PATH="$arg"
            else
                REMOTE_PATH="$arg"
            fi
            ;;
    esac
done

[[ -z "$LOCAL_PATH" && -z "$REMOTE_PATH" ]] && die "No valid path provided."

# ── Terminal image capability detection ───────────────────────────────────────
detect_image_support() {
    # Kitty: $TERM or $TERM_PROGRAM
    if [[ "${TERM:-}" == "xterm-kitty" || "${TERM_PROGRAM:-}" == "kitty" ]]; then
        echo "kitty"; return
    fi
    # iTerm2
    if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]]; then
        echo "iterm2"; return
    fi
    # Sixel: check TERM or via terminfo
    if [[ "${TERM:-}" =~ "sixel" ]] || tput colors 2>/dev/null | grep -q "^[0-9]"; then
        if command -v convert &>/dev/null; then
            # Test if sixel output works by checking DCS support
            if [[ "${COLORTERM:-}" == "truecolor" || "${TERM:-}" =~ "256color" ]]; then
                echo "sixel"; return
            fi
        fi
    fi
    # WezTerm supports iTerm2 protocol
    if [[ "${TERM_PROGRAM:-}" == "WezTerm" ]]; then
        echo "iterm2"; return
    fi
    echo "none"
}

IMAGE_SUPPORT=$([[ "$NO_IMAGE" == true ]] && echo "none" || detect_image_support)
log_info "Terminal image support: $IMAGE_SUPPORT"

# ── ADB setup (only if pulling from device) ───────────────────────────────────
if [[ -n "$REMOTE_PATH" ]]; then
    ADB="${ADB:-$(command -v adb 2>/dev/null || echo '')}"
    [[ -z "$ADB" ]] && die "'adb' not found in PATH. Set ADB=/path/to/adb or use a local directory."

    # Root method detection
    log_step "Root method"
    ROOT_METHOD="NONE"
    probe() {
        local result
        result=$("$ADB" $DEVICE shell "$2" 2>/dev/null | tr -d '\r')
        echo "$result" | grep -q "uid=0" && { log_ok "Works: $1"; return 0; }
        log_info "Failed: $1"; return 1
    }
    ADBD_OUT=$("$ADB" $DEVICE root 2>&1 | tr -d '\r')
    if ! echo "$ADBD_OUT" | grep -qE "adbd cannot run as root|error|failed"; then
        sleep 1; probe "adb root" "id" && ROOT_METHOD="adb_root"
    fi
    [[ "$ROOT_METHOD" == "NONE" ]] && probe "su -c"   "su -c 'id'"   && ROOT_METHOD="su_c"
    [[ "$ROOT_METHOD" == "NONE" ]] && probe "su 0 -c" "su 0 -c 'id'" && ROOT_METHOD="su_0_c"
    [[ "$ROOT_METHOD" == "NONE" ]] && probe "su 0"    "su 0 id"      && ROOT_METHOD="su_0"
    [[ "$ROOT_METHOD" == "NONE" ]] && probe "plain"   "id"           && ROOT_METHOD="shell_root"
    log_ok "Root method: $ROOT_METHOD"

    adb_root_shell() {
        local cmd="$1"
        local sq_cmd="'$(echo "$cmd" | sed "s/'/'\\\\''/g")'"
        case "$ROOT_METHOD" in
            adb_root|shell_root) "$ADB" $DEVICE shell "$cmd" ;;
            su_c)                "$ADB" $DEVICE shell "su -c $sq_cmd" ;;
            su_0_c)              "$ADB" $DEVICE shell "su 0 -c $sq_cmd" ;;
            su_0)                "$ADB" $DEVICE shell "su 0 $sq_cmd" ;;
            NONE)                "$ADB" $DEVICE shell "$cmd" ;;
        esac
    }

    # Pull the directory
    log_step "Pulling $REMOTE_PATH"
    PULL_DIR="$(pwd)/photo_timeline_pull"
    rm -rf "$PULL_DIR"; mkdir -p "$PULL_DIR"

    parent=$(dirname "$REMOTE_PATH")
    name=$(basename "$REMOTE_PATH")
    adb_root_shell "tar -C '$parent' -czf - '$name' 2>/dev/null" \
        | tar -xzf - -C "$PULL_DIR" 2>/dev/null \
        && log_ok "Pulled to $PULL_DIR/$name" \
        || log_warn "Partial pull — some files may be missing"

    LOCAL_PATH="$PULL_DIR/$name"
    [[ ! -d "$LOCAL_PATH" ]] && die "Pull failed or directory empty: $LOCAL_PATH"
fi

# ── Collect all files with metadata ──────────────────────────────────────────
log_step "Scanning files"

WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'; $([[ '$KEEP_FILES' == false && -n '${PULL_DIR:-}' ]] && echo 'rm -rf \"$PULL_DIR\"' || echo 'true')" EXIT

METADATA_FILE="$WORK_DIR/metadata.tsv"  # hash \t mtime_epoch \t mtime_human \t filepath \t filename \t size \t mimetype

file_count=0
while IFS= read -r fpath; do
    [[ -f "$fpath" ]] || continue

    # Size
    fsize=$(wc -c < "$fpath" 2>/dev/null || echo 0)
    [[ "$fsize" -eq 0 ]] && continue  # skip empty files

    # Hash
    hash=$(sha256sum "$fpath" | cut -d' ' -f1)

    # Modification time
    if stat --version 2>/dev/null | grep -q GNU; then
        # GNU stat (Linux)
        mtime_epoch=$(stat -c '%Y' "$fpath" 2>/dev/null || echo 0)
        mtime_human=$(stat -c '%y' "$fpath" 2>/dev/null | cut -d'.' -f1 || echo '?')
    else
        # BSD stat (macOS)
        mtime_epoch=$(stat -f '%m' "$fpath" 2>/dev/null || echo 0)
        mtime_human=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$fpath" 2>/dev/null || echo '?')
    fi

    # MIME type
    mimetype=$(file -b --mime-type "$fpath" 2>/dev/null || echo "application/octet-stream")

    fname=$(basename "$fpath")
    rel="${fpath#$LOCAL_PATH/}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$hash" "$mtime_epoch" "$mtime_human" "$fpath" "$rel" "$fsize" "$mimetype" \
        >> "$METADATA_FILE"

    file_count=$((file_count + 1))
done < <(find "$LOCAL_PATH" -type f | sort)

log_ok "Scanned $file_count file(s)"
[[ $file_count -eq 0 ]] && { log_warn "No files found in $LOCAL_PATH"; exit 0; }

# ── Group by hash, sort groups by earliest mtime ──────────────────────────────
log_step "Building timeline"

# Use python3 for grouping/sorting logic — cleaner than pure bash
python3 - "$METADATA_FILE" "$LOCAL_PATH" "$IMAGE_SUPPORT" << 'PYEOF'
import sys, os, subprocess, base64, struct
from collections import defaultdict
from datetime import datetime

metadata_file = sys.argv[1]
local_path    = sys.argv[2]
img_support   = sys.argv[3]

# Colours (reuse terminal codes)
R='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'
PURPLE='\033[0;35m'; BLUE='\033[0;34m'; RED='\033[0;31m'

def fmt_size(n):
    for unit in ['B','KB','MB','GB']:
        if n < 1024: return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"

def short_hash(h): return h[:12]

ADJECTIVES = [
    'amber','ancient','arctic','ashen','azure','binary','bitter','blazing',
    'bold','broken','calm','carbon','cold','coral','crimson','crystal',
    'cursed','dark','delta','distant','dusty','electric','empty','fallen',
    'feral','fierce','final','fixed','frozen','ghost','golden','hollow',
    'icy','iron','jade','jade','keen','last','lean','lone','lost','lunar',
    'marble','muted','mystic','neon','noble','null','obsidian','odd',
    'onyx','opaque','pale','phantom','prime','quiet','raw','rigid','rose',
    'rusted','sacred','scarlet','shadow','sharp','silent','silver','slate',
    'smooth','solar','solid','static','steel','still','stone','strange',
    'swift','tidal','twin','ultra','veiled','violet','vital','void',
    'wandering','warm','wild','worn','xenon','zero',
]
NOUNS = [
    'anchor','apex','arc','ash','atom','beacon','blade','bloom','bolt',
    'bone','branch','bridge','byte','cache','cell','cipher','circuit',
    'cliff','clock','cloud','comet','core','crown','crypt','curve',
    'dawn','delta','dome','drift','dusk','echo','edge','ember','epoch',
    'facet','field','flame','flash','flux','fold','forge','fork','frame',
    'frost','gate','ghost','glyph','grid','grove','hash','horizon',
    'hull','index','iris','isle','kernel','key','knot','layer','leaf',
    'lens','link','lock','loop','map','mask','mesh','mode','moon',
    'node','null','orbit','packet','path','peak','pixel','plane','point',
    'port','prism','pulse','range','reef','ring','root','route','rune',
    'shard','shell','shift','shore','signal','sink','slate','socket',
    'source','spark','spike','spiral','stack','stem','stone','stream',
    'summit','surge','tide','token','trace','tree','vault','vector',
    'veil','vertex','void','wake','wall','wave','well','wire','zone',
]

def hash_name(h):
    """Deterministic human-readable name from hash. Same hash = same name always."""
    n = int(h[:8], 16)
    adj  = ADJECTIVES[n % len(ADJECTIVES)]
    noun = NOUNS[(n // len(ADJECTIVES)) % len(NOUNS)]
    tail = h[:4]
    return f"{adj}-{noun}-{tail}"

# Parse metadata
groups = defaultdict(list)  # hash → list of (mtime_epoch, mtime_human, fpath, rel, size, mime)
with open(metadata_file) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 7: continue
        h, epoch, human, fpath, rel, size, mime = parts
        groups[h].append({
            'epoch': int(epoch),
            'human': human,
            'fpath': fpath,
            'rel':   rel,
            'size':  int(size),
            'mime':  mime,
        })

# Sort each group internally by mtime ascending (oldest first)
for h in groups:
    groups[h].sort(key=lambda x: x['epoch'])

# Sort groups by earliest mtime of their first file
sorted_groups = sorted(groups.items(), key=lambda kv: kv[1][0]['epoch'])

total_groups   = len(sorted_groups)
unique_content = sum(1 for h, files in sorted_groups if len(files) == 1)
duplicated     = total_groups - unique_content

print(f"\n{BOLD}{'━'*70}{R}")
print(f"{BOLD}  File Identity Timeline{R}  —  {local_path}")
print(f"{DIM}  {total_groups} unique content(s) · {duplicated} with multiple names · "
      f"{sum(len(v) for v in groups.values())} total files{R}")
print(f"{BOLD}{'━'*70}{R}\n")

# ── Image rendering helpers ───────────────────────────────────────────────────

def render_kitty(fpath):
    """Render image via kitty +kitten icat — handles format detection internally."""
    try:
        # kitty icat is the official way; it handles PNG/JPEG/WEBP/etc automatically
        # --transfer-mode=stream works even over SSH
        r = subprocess.run(
            ['kitty', '+kitten', 'icat', '--align=left',
             '--transfer-mode=stream', '--stdin=no', fpath],
            stderr=subprocess.DEVNULL
        )
        sys.stdout.write('\n')
        sys.stdout.flush()
        return r.returncode == 0
    except FileNotFoundError:
        # kitty binary not in PATH — fall back to raw graphics protocol
        try:
            with open(fpath, 'rb') as fh:
                data = fh.read()
            # Detect format: f=32 RGBA, f=24 RGB, f=100 PNG-encoded (safest default)
            # Use f=100 which means "PNG" — kitty will decode it correctly for PNG/JPEG
            b64 = base64.b64encode(data).decode()
            chunks = [b64[i:i+4096] for i in range(0, len(b64), 4096)]
            for i, chunk in enumerate(chunks):
                more = 0 if i == len(chunks) - 1 else 1
                if i == 0:
                    # a=T transmit+display, f=100 PNG format, s/v=0 auto-size
                    sys.stdout.buffer.write(
                        f'\033_Ga=T,f=100,m={more};{chunk}\033\\'.encode()
                    )
                else:
                    sys.stdout.buffer.write(
                        f'\033_Gm={more};{chunk}\033\\'.encode()
                    )
            sys.stdout.buffer.write(b'\n')
            sys.stdout.buffer.flush()
            return True
        except Exception:
            return False

def render_iterm2(fpath):
    """Render image via iTerm2 inline image protocol (also WezTerm)."""
    try:
        with open(fpath, 'rb') as f:
            data = f.read()
        b64 = base64.b64encode(data).decode()
        fname = os.path.basename(fpath)
        size  = len(data)
        sys.stdout.write(f'\033]1337;File=name={base64.b64encode(fname.encode()).decode()}'
                         f';size={size};inline=1:{b64}\a\n')
        sys.stdout.flush()
        return True
    except Exception:
        return False

def render_sixel(fpath):
    """Render image via Sixel using ImageMagick convert."""
    try:
        subprocess.run(
            ['convert', fpath, '-geometry', '200x200>', '-colors', '256', 'sixel:-'],
            check=True, stderr=subprocess.DEVNULL
        )
        sys.stdout.write('\n')
        sys.stdout.flush()
        return True
    except Exception:
        return False

def try_render_image(fpath, mime):
    if img_support == 'none':
        return
    if not mime.startswith('image/'):
        return
    rendered = False
    if   img_support == 'kitty':   rendered = render_kitty(fpath)
    elif img_support == 'iterm2':  rendered = render_iterm2(fpath)
    elif img_support == 'sixel':   rendered = render_sixel(fpath)
    if not rendered:
        print(f"  {DIM}[image rendering failed]{R}")

# ── Print timeline ────────────────────────────────────────────────────────────
for idx, (h, files) in enumerate(sorted_groups, 1):
    is_dup   = len(files) > 1
    first    = files[0]
    mime     = first['mime']
    is_image = mime.startswith('image/')

    # Group header
    dup_label = f"{YELLOW}  ×{len(files)} names{R}" if is_dup else ""
    type_label = f"{BLUE}[{mime}]{R}"
    name = hash_name(h)
    print(f"{BOLD}{PURPLE}#{idx:03d}{R}  {BOLD}{GREEN}{name}{R}  "
          f"{type_label}  {DIM}{fmt_size(first['size'])}{R}{dup_label}")
    print(f"  {DIM}hash: {h}{R}")

    # File entries: oldest first
    for i, entry in enumerate(files):
        marker = f"{GREEN}FIRST{R}" if i == 0 else f"{DIM} next{R}"
        dt = datetime.fromtimestamp(entry['epoch']).strftime('%Y-%m-%d  %H:%M:%S')
        print(f"  {marker}  {BOLD}{dt}{R}  {entry['rel']}")

    # Render image inline (use first/canonical file)
    if is_image and img_support != 'none':
        try_render_image(first['fpath'], mime)

    # Separator
    print(f"  {DIM}{'─'*66}{R}")
    print()

# ── Summary ───────────────────────────────────────────────────────────────────
print(f"{BOLD}{'━'*70}{R}")
print(f"  {GREEN}Timeline complete.{R}  "
      f"{total_groups} unique file(s), "
      f"{sum(len(v) for v in groups.values())} total entries.")

# Highlight interesting patterns: same content, very different timestamps
print(f"\n{BOLD}  Notable patterns:{R}")
notable = 0
for h, files in sorted_groups:
    if len(files) < 2: continue
    span = files[-1]['epoch'] - files[0]['epoch']
    if span > 86400:  # more than 1 day apart
        days = span // 86400
        print(f"  {YELLOW}⚠{R}  {BOLD}{GREEN}{hash_name(h)}{R}  "
              f"same content, {days}d span  "
              f"({files[0]['rel']} → {files[-1]['rel']})")
        notable += 1
if notable == 0:
    print(f"  {DIM}No files with same content across >1 day gap.{R}")

print(f"\n{BOLD}{'━'*70}{R}\n")
PYEOF

# ── Cleanup ───────────────────────────────────────────────────────────────────
if [[ "$KEEP_FILES" == false && -n "${PULL_DIR:-}" ]]; then
    rm -rf "$PULL_DIR"
    log_info "Pulled files removed (use --keep to retain them)"
fi
