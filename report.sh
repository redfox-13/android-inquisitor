#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# report.sh - Generate HTML report for a case snapshot
# Usage: ./report.sh <case_dir> <report_name>
# Output: <case_dir>/reports/<report_name>/report.html
# -----------------------------------------------------------------------------
set -euo pipefail

[[ $# -lt 2 ]] && { echo "Usage: report.sh <case_dir> <report_name>"; exit 1; }

CASE_DIR="$1"
REPORT_NAME="$2"
REPORT_DIR="$CASE_DIR/reports/$REPORT_NAME"
REPORT_HTML="$REPORT_DIR/report.html"
DB_JSON="$REPORT_DIR/db/databases.json"

mkdir -p "$REPORT_DIR"

# Check if the file actually exists before trying to read it
if [[ -f "$DB_JSON" ]]; then
    DB_DATA_CONTENT=$(cat "$DB_JSON")
else
    # Fallback: Try to find it in the case dir if it's not in the report dir yet
    DB_DATA_CONTENT=$(cat "$CASE_DIR/reports/$REPORT_NAME/db/databases.json" 2>/dev/null || echo "[]")
fi

CASE_ID=$(basename "$CASE_DIR")
PACKAGES_JSON=$(python3 -c "
import sys, json
pkgs = open('$CASE_DIR/packages.txt').read().splitlines() if __import__('os').path.exists('$CASE_DIR/packages.txt') else []
print(json.dumps(pkgs))
" 2>/dev/null || echo '[]')
COMMIT_COUNT=$(git -C "$CASE_DIR" rev-list --count HEAD 2>/dev/null || echo "0")
LAST_COMMIT_MSG=$(git -C "$CASE_DIR" log -1 --format="%s" 2>/dev/null | sed 's/"/\\"/g' || echo "—")

GIT_LOG_JSON=$(git -C "$CASE_DIR" log --format="%h|||%ci|||%s" --all 2>/dev/null | head -30 | \
    python3 -c "
import sys, json
log = []
for line in sys.stdin:
    if '|||' in line:
        h, d, s = line.strip().split('|||')
        log.append({'hash': h, 'date': d, 'msg': s})
print(json.dumps(log))
" 2>/dev/null || echo "[]")

# -- Manifest diff -------------------------------------------------------------
COMMIT_COUNT_INT=$(git -C "$CASE_DIR" rev-list --count HEAD 2>/dev/null || echo 0)
MANIFEST_DIFF_JSON=$(
    if [[ "$COMMIT_COUNT_INT" -ge 2 ]]; then
        git -C "$CASE_DIR" diff HEAD~1 HEAD -- manifest.sha256 2>/dev/null \
            | grep -E "^\+[^+]|^-[^-]" \
            | python3 -c "
import sys, json
rows = []
for line in sys.stdin:
    line = line.rstrip()
    if not line: continue
    rows.append({'op': line[0], 'text': line[1:]})
print(json.dumps(rows))
" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
)

# -- Permissions diff ----------------------------------------------------------
FIRST_PKG=$(head -1 "$CASE_DIR/packages.txt" 2>/dev/null || echo "")
PERMS_DIFF_JSON=$(python3 - <<'EOF'
import sys, json
rows = []
for line in sys.stdin:
    line = line.rstrip()
    if not line: continue
    rows.append({'op': line[0], 'text': line[1:]})
print(json.dumps(rows, separators=(',',':')), end='')  # <-- key: end=''
EOF
)

# -- APK hash ------------------------------------------------------------------
APK_HASH=""
APK_HASH_FILE=$(find "$CASE_DIR/data" -name "apk.sha256" 2>/dev/null | head -1)
[[ -n "$APK_HASH_FILE" ]] && APK_HASH=$(cat "$APK_HASH_FILE" 2>/dev/null | cut -d' ' -f1) || true
APK_CHANGED="unknown"
if [[ "$COMMIT_COUNT_INT" -ge 2 ]]; then
    APK_DIFF=$(git -C "$CASE_DIR" diff HEAD~1 HEAD -- "*/apk/apk.sha256" 2>/dev/null || true)
    [[ -n "$APK_DIFF" ]] && APK_CHANGED="true" || APK_CHANGED="false"
fi

# -- Embed DB JSON -------------------------------------------------------------
# Base64-encode so DB content (quotes, slashes, </script>, backticks)
# can never break JS. Decoded client-side with atob() + JSON.parse().
DB_JSON_B64=$(echo "[]" | base64 -w0)
if [[ -f "$DB_JSON" ]]; then
    DB_JSON_B64=$(base64 -w0 < "$DB_JSON")
fi
# -- Write HTML ----------------------------------------------------------------
cat > "$REPORT_HTML" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Forensic Report — ${CASE_ID}</title>
<style>
:root {
  --bg:#0d1117;--surface:#161b22;--surface2:#21262d;--border:#30363d;
  --text:#e6edf3;--muted:#7d8590;--green:#3fb950;--red:#f85149;
  --yellow:#d29922;--blue:#58a6ff;--purple:#bc8cff;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;line-height:1.6}
.container{max-width:1300px;margin:0 auto;padding:24px}
header{border-bottom:1px solid var(--border);padding-bottom:18px;margin-bottom:24px;display:flex;align-items:baseline;gap:16px}
header h1{font-size:20px;color:var(--blue)}
header .meta{color:var(--muted);font-size:12px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:24px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:18px}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin-bottom:12px}
.stat{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid var(--border);font-size:13px}
.stat:last-child{border-bottom:none}
.stat .label{color:var(--muted)}
.stat .value{font-family:monospace;word-break:break-all;text-align:right;max-width:70%}
.badge{display:inline-block;padding:2px 8px;border-radius:20px;font-size:11px;font-weight:600;margin-left:4px}
.badge.ok{background:#1a3a1a;color:var(--green)}
.badge.warn{background:#3a2a0a;color:var(--yellow)}
.badge.err{background:#3a0a0a;color:var(--red)}
.badge.info{background:var(--surface2);color:var(--muted)}
section{margin-bottom:28px}
section>h2{font-size:15px;border-bottom:1px solid var(--border);padding-bottom:8px;margin-bottom:14px}
.commit{padding:3px 0;font-size:12px;display:flex;gap:8px}
.sha{font-family:monospace;color:var(--purple);flex-shrink:0}
.date{color:var(--muted);flex-shrink:0;font-size:11px}
.msg{color:var(--text)}
.diff-viewer{border:1px solid var(--border);border-radius:6px;overflow:hidden;font-family:monospace;font-size:12px}
.diff-file{border-bottom:1px solid var(--border)}
.diff-file:last-child{border-bottom:none}
.diff-file-header{display:flex;align-items:center;gap:8px;padding:7px 12px;background:var(--surface2);cursor:pointer;user-select:none}
.diff-file-header:hover{background:var(--surface)}
.diff-toggle{color:var(--muted);font-size:10px;flex-shrink:0;width:12px}
.diff-op{font-size:10px;font-weight:700;padding:2px 6px;border-radius:3px;flex-shrink:0}
.diff-op.add{background:#1a3a1a;color:var(--green)}
.diff-op.mod{background:#1a2a3a;color:var(--blue)}
.diff-op.rem{background:#3a0a0a;color:var(--red)}
.diff-filepath{color:var(--muted);flex:1;word-break:break-all;font-size:11px}
.diff-hash{color:var(--purple);font-size:10px;flex-shrink:0}
.diff-body{display:none;padding:8px 12px;background:var(--bg);border-top:1px solid var(--border)}
.diff-body.open{display:block}
.diff-line{padding:1px 0}
.diff-line.add{color:var(--green)}
.diff-line.rem{color:var(--red)}
.no-change{color:var(--muted);font-style:italic;font-size:13px}
.no-change{color:var(--muted);font-style:italic;font-size:13px}

/* -- DB Explorer -- */
.db-explorer{display:grid;grid-template-columns:280px 1fr;gap:0;border:1px solid var(--border);border-radius:8px;overflow:hidden;min-height:400px}
.db-sidebar{background:var(--surface2);border-right:1px solid var(--border);overflow-y:auto}
.db-sidebar-header{padding:10px 14px;font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);border-bottom:1px solid var(--border)}
.db-item{padding:8px 14px;cursor:pointer;border-bottom:1px solid var(--border);transition:background .1s}
.db-item:hover{background:var(--surface)}
.db-item.active{background:var(--surface);border-left:2px solid var(--blue)}
.db-item-name{font-size:13px;font-weight:600;color:var(--text)}
.db-item-meta{font-size:11px;color:var(--muted);margin-top:2px}
.db-main{background:var(--surface);overflow:hidden;display:flex;flex-direction:column}
.db-main-header{padding:12px 18px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.db-main-title{font-size:15px;font-weight:600;color:var(--blue);flex:1}
.db-main-path{font-family:monospace;font-size:11px;color:var(--muted);padding:6px 18px;border-bottom:1px solid var(--border)}
.db-content{display:grid;grid-template-columns:200px 1fr;flex:1;overflow:hidden}
.table-sidebar{border-right:1px solid var(--border);overflow-y:auto;background:var(--bg)}
.table-sidebar-header{padding:8px 12px;font-size:11px;color:var(--muted);border-bottom:1px solid var(--border);text-transform:uppercase;letter-spacing:.04em}
.table-item{padding:7px 12px;cursor:pointer;border-bottom:1px solid var(--border);font-size:12px;font-family:monospace;color:var(--text);transition:background .1s}
.table-item:hover{background:var(--surface2)}
.table-item.active{background:var(--surface2);color:var(--blue)}
.table-detail{overflow-y:auto;padding:16px}
.table-detail h3{font-size:13px;margin-bottom:10px;color:var(--text)}
.schema-table{width:100%;border-collapse:collapse;font-size:12px;margin-bottom:16px}
.schema-table th{background:var(--surface2);color:var(--muted);padding:5px 10px;text-align:left;border:1px solid var(--border);font-size:11px;text-transform:uppercase}
.schema-table td{padding:4px 10px;border:1px solid var(--border);font-family:monospace}
.pk-badge{background:#1a2a3a;color:var(--blue);padding:1px 6px;border-radius:4px;font-size:10px}
.nn-badge{background:#1a1a2a;color:var(--purple);padding:1px 6px;border-radius:4px;font-size:10px}
.sample-section{margin-top:12px}
.sample-section h4{font-size:12px;color:var(--muted);margin-bottom:8px;text-transform:uppercase;letter-spacing:.04em}
.sample-table{width:100%;border-collapse:collapse;font-size:12px}
.sample-table th{background:var(--surface2);color:var(--muted);padding:4px 10px;text-align:left;border:1px solid var(--border);font-size:11px;white-space:nowrap}
.sample-table td{padding:4px 10px;border:1px solid var(--border);font-family:monospace;max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sample-table tr:nth-child(even) td{background:rgba(255,255,255,.02)}
.idx-list{font-size:11px;color:var(--muted);margin-bottom:12px}
.placeholder{display:flex;align-items:center;justify-content:center;height:100%;color:var(--muted);font-size:13px;font-style:italic}
.stat-row{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}

@media(max-width:900px){
  .grid{grid-template-columns:1fr}
  .db-explorer{grid-template-columns:1fr;min-height:auto}
  .db-sidebar{max-height:200px}
  .db-content{grid-template-columns:1fr;max-height:600px}
  .table-sidebar{max-height:150px;border-right:none;border-bottom:1px solid var(--border)}
}
</style>
</head>
<body>
<div class="container">

<header>
  <h1>🔍 Forensic Report</h1>
  <div class="meta">${CASE_ID} &nbsp;·&nbsp; ${REPORT_NAME}</div>
</header>

<div class="grid">
  <div class="card">
    <h2>Case Info</h2>
    <div class="stat"><span class="label">Case ID</span><span class="value">${CASE_ID}</span></div>
    <div class="stat"><span class="label">Snapshots</span><span class="value">${COMMIT_COUNT}</span></div>
    <div class="stat"><span class="label">Last commit</span><span class="value">${LAST_COMMIT_MSG}</span></div>
    <div class="stat"><span class="label">APK SHA-256</span><span class="value">${APK_HASH:-—}</span></div>
    <div class="stat" id="apk-status-row"><span class="label">APK integrity</span><span class="value" id="apk-status">—</span></div>
    <div class="stat"><span class="label">Packages</span><span class="value" id="pkg-list" style="white-space:pre-line"></span></div>
  </div>
  <div class="card">
    <h2>Snapshot History</h2>
    <div id="git-log"></div>
  </div>
</div>

<section>
  <h2>📂 File Changes</h2>
  <div id="manifest-diff"></div>
</section>

<section>
  <h2>🔐 Permission Changes</h2>
  <div id="perms-diff"></div>
</section>

<section>
  <h2>🗄️ Database Explorer</h2>
  <div class="db-explorer">
    <div class="db-sidebar">
      <div class="db-sidebar-header">Databases</div>
      <div id="db-list"></div>
    </div>
    <div class="db-main" id="db-main">
      <div class="placeholder">← Select a database</div>
    </div>
  </div>
</section>

</div>

<script>
// -- Data embedded at report generation time -------------------------------
const CASE_ID    = ${CASE_ID@Q};
const PACKAGES   = ${PACKAGES_JSON:-[]};
const GIT_LOG    = ${GIT_LOG_JSON:-[]};
const MANIFEST   = ${MANIFEST_DIFF_JSON:-[]};
const PERMS      = ${PERMS_DIFF_JSON:-[]};
const APK_CHANGED = "${APK_CHANGED:-unknown}";
const DBS        = JSON.parse(atob("${DB_JSON_B64:-W10=}"));

// -- Render static sections ------------------------------------------------
document.getElementById('pkg-list').textContent = PACKAGES.join('\n');

const apkEl = document.getElementById('apk-status');
if (APK_CHANGED === 'true')    apkEl.innerHTML = '<span class="badge warn">CHANGED</span>';
else if (APK_CHANGED === 'false') apkEl.innerHTML = '<span class="badge ok">Unchanged</span>';
else apkEl.textContent = '—';

// Git log
const logEl = document.getElementById('git-log');
if (!GIT_LOG.length) { logEl.innerHTML = '<span style="color:var(--muted);font-style:italic">No commits yet</span>'; }
else GIT_LOG.forEach(c => {
  logEl.innerHTML += \`<div class="commit">
    <span class="sha">\${esc(c.sha)}</span>
    <span class="date">\${esc(c.date.slice(0,16))}</span>
    <span class="msg">\${esc(c.msg)}</span>
  </div>\`;
});

// Diffs
function renderDiff(data, elId, emptyMsg) {
  const el = document.getElementById(elId);
  if (!data.length) { el.innerHTML = \`<div class="no-change">\${emptyMsg}</div>\`; return; }

  // Group by file path (first field of manifest line: "<hash>  <path>")
  // Each line is: "+ <hash>  <path>" or "- <hash>  <path>"
  // For perms lines they have no path structure — treat each as its own entry
  const files = new Map();
  data.forEach(r => {
    // manifest lines: "<sha256>  <filepath>"
    const m = r.text.match(/^([0-9a-f]{64})\s{2}(.+)$/);
    const key = m ? m[2] : r.text.trim();
    const hash = m ? m[1].slice(0,8) : '';
    if (!files.has(key)) files.set(key, { adds:[], rems:[], hash:'' });
    if (r.op === '+') { files.get(key).adds.push(r.text); files.get(key).hash = hash; }
    else              { files.get(key).rems.push(r.text); }
  });

  let html = '<div class="diff-viewer">';
  files.forEach((v, key) => {
    const isAdd = v.adds.length && !v.rems.length;
    const isRem = v.rems.length && !v.adds.length;
    const isMod = v.adds.length && v.rems.length;
    const opClass = isAdd ? 'add' : isRem ? 'rem' : 'mod';
    const opLabel = isAdd ? '[+]' : isRem ? '[-]' : '[M]';
    const uid = Math.random().toString(36).slice(2);
    html += \`<div class="diff-file">
      <div class="diff-file-header" onclick="toggleDiff('\${uid}')">
        <span class="diff-toggle" id="tog-\${uid}">▶</span>
        <span class="diff-op \${opClass}">\${opLabel}</span>
        <span class="diff-filepath">\${esc(key)}</span>
        \${v.hash ? \`<span class="diff-hash">\${esc(v.hash)}</span>\` : ''}
      </div>
      <div class="diff-body" id="body-\${uid}">\`;
    v.rems.forEach(l => { html += \`<div class="diff-line rem">- \${esc(l)}</div>\`; });
    v.adds.forEach(l => { html += \`<div class="diff-line add">+ \${esc(l)}</div>\`; });
    html += '</div></div>';
  });
  html += '</div>';
  el.innerHTML = html;
}

function toggleDiff(uid) {
  const body = document.getElementById('body-' + uid);
  const tog  = document.getElementById('tog-'  + uid);
  const open = body.classList.toggle('open');
  tog.textContent = open ? '▼' : '▶';
}

renderDiff(MANIFEST, 'manifest-diff', 'No file changes since last snapshot.');
renderDiff(PERMS,    'perms-diff',    'No permission changes.');

// -- DB Explorer -----------------------------------------------------------
let activeDb    = null;
let activeTable = null;

const dbList = document.getElementById('db-list');
const dbMain = document.getElementById('db-main');

if (!DBS.length) {
  dbList.innerHTML = '<div style="padding:12px;color:var(--muted);font-size:12px">No databases found</div>';
} else {
  DBS.forEach((db, i) => {
    const el = document.createElement('div');
    el.className = 'db-item';
    el.innerHTML = \`<div class="db-item-name">\${esc(db.name)}\${db.has_wal ? ' <span class="badge warn" style="font-size:9px">WAL</span>' : ''}</div>
      <div class="db-item-meta">\${(db.table_count||0)} tables · \${fmt(db.size_bytes)} bytes\${db.error ? ' · <span style="color:var(--red)">error</span>' : ''}</div>\`;
    el.onclick = () => selectDb(i, el);
    dbList.appendChild(el);
  });
}

function selectDb(i, el) {
  document.querySelectorAll('.db-item').forEach(x => x.classList.remove('active'));
  el.classList.add('active');
  activeDb = i;
  activeTable = null;
  renderDb(DBS[i]);
}

function renderDb(db) {
  if (db.error) {
    dbMain.innerHTML = \`<div class="db-main-header"><span class="db-main-title">\${esc(db.name)}</span><span class="badge err">Error: \${esc(db.error)}</span></div>
      <div class="placeholder">Cannot read this database</div>\`;
    return;
  }
  dbMain.innerHTML = \`
    <div class="db-main-header">
      <span class="db-main-title">\${esc(db.name)}</span>
      \${db.has_wal ? '<span class="badge warn">WAL present</span>' : ''}
      <span class="badge info">\${fmt(db.size_bytes)} bytes</span>
      <span class="badge info">\${db.table_count} tables</span>
      <span class="badge info">\${db.trigger_count} triggers</span>
      <span class="badge info">SQLite \${esc(db.sqlite_version)}</span>
      <span class="badge info">\${esc(db.encoding)}</span>
    </div>
    <div class="db-main-path">\${esc(db.path)}</div>
    <div class="db-content">
      <div class="table-sidebar">
        <div class="table-sidebar-header">Tables (\${(db.tables||[]).length})</div>
        <div id="table-list"></div>
      </div>
      <div class="table-detail" id="table-detail">
        <div class="placeholder">← Select a table</div>
      </div>
    </div>
  \`;

  const tList = document.getElementById('table-list');
  (db.tables || []).forEach((t, ti) => {
    const el = document.createElement('div');
    el.className = 'table-item';
    el.textContent = t.name;
    el.title = \`\${t.row_count} rows\`;
    el.onclick = () => selectTable(ti, el, db);
    tList.appendChild(el);
  });
}

function selectTable(ti, el, db) {
  document.querySelectorAll('.table-item').forEach(x => x.classList.remove('active'));
  el.classList.add('active');
  activeTable = ti;
  renderTable(db.tables[ti]);
}

function renderTable(t) {
  const detail = document.getElementById('table-detail');

  // Schema
  const cols = (t.columns || []).map(c => \`<tr>
    <td>\${c.cid}</td>
    <td><strong>\${esc(c.name)}</strong></td>
    <td>\${esc(c.type||'')}</td>
    <td>\${c.pk ? '<span class="pk-badge">PK</span>' : ''}</td>
    <td>\${c.notnull ? '<span class="nn-badge">NOT NULL</span>' : ''}</td>
  </tr>\`).join('');

  // Sample rows — columns as headers, pipe-split values as cells
  let sampleHtml = '';
  if (t.sample && t.sample.length) {
    const colNames = (t.columns||[]).map(c => c.name);
    const headerCells = colNames.map(n => \`<th>\${esc(n)}</th>\`).join('');
    const rows = t.sample.map(row => {
      const cells = row.split(' | ').map((v,i) => \`<td title="\${esc(v)}">\${esc(v)}</td>\`).join('');
      return \`<tr>\${cells}</tr>\`;
    }).join('');
    sampleHtml = \`<div class="sample-section">
      <h4>Sample data (\${t.sample.length} rows)</h4>
      <div style="overflow-x:auto">
        <table class="sample-table">
          <thead><tr>\${headerCells}</tr></thead>
          <tbody>\${rows}</tbody>
        </table>
      </div>
    </div>\`;
  }

  const idxHtml = t.indexes && t.indexes.length
    ? \`<div class="idx-list">Indexes: \${t.indexes.map(i => \`<code>\${esc(i)}</code>\`).join(', ')}</div>\`
    : '';

  detail.innerHTML = \`
    <div class="stat-row">
      <span class="badge info">\${t.row_count} rows</span>
      <span class="badge info">\${(t.columns||[]).length} columns</span>
      \${t.indexes && t.indexes.length ? \`<span class="badge info">\${t.indexes.length} indexes</span>\` : ''}
    </div>
    <h3>Schema — \${esc(t.name)}</h3>
    <table class="schema-table">
      <thead><tr><th>#</th><th>Column</th><th>Type</th><th>PK</th><th>NOT NULL</th></tr></thead>
      <tbody>\${cols}</tbody>
    </table>
    \${idxHtml}
    \${sampleHtml}
  \`;
}

// -- Helpers ---------------------------------------------------------------
function esc(s) {
  return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function fmt(n) { return Number(n).toLocaleString(); }
</script>
</body>
</html>
HTMLEOF

echo -e "\033[0;32m[  OK ]\033[0m Report → $REPORT_HTML"
