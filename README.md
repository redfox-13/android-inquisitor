# android-inquisitor

A collection of scripts for acquiring and analysing Android app data for forensic research. Focused on single-app or app-bundle analysis — not a full device acquisition tool.

**Note:** These scripts were developed with the help of AI.

## Scripts

- [snapshot.sh](#snapshotsh) — case lifecycle management
- [acquisition.sh](#acquisitionsh) — ADB data pull
- [db-report.sh](#db-reportsh) — SQLite introspector
- [report.sh](#reportsh) — HTML report generator
- [activity-viewer.sh](#activity-viewersh) — activity launcher
- [photo-timeline.sh](#photo-timelinesh) — file identity timeline

---

## Requirements

- `adb` — Android Debug Bridge, in PATH
- `git` — required for state tracking and versioning
- `python3` — used for JSON processing and report generation
- `sqlite3` — required for database parsing

## Configuration

| Variable    | Default           | Description                   |
| ----------- | ----------------- | ----------------------------- |
| `ADB`       | `adb` (from PATH) | Path to a specific ADB binary |
| `CASES_DIR` | `./cases`         | Root directory for all cases  |

```bash
# Custom ADB binary
ADB=/path/to/custom/adb ./snapshot.sh snap my-case -d

# Custom cases directory
CASES_DIR=/mnt/externalSSD/Forensics ./snapshot.sh list

# Persist for the session
export CASES_DIR="/mnt/externalSSD/Forensics"
```

---

## Evidence Structure

```
cases/
└── com.example.app/               ← git repository root
    ├── data/
    │   └── com.example.app/
    │       ├── apk/               ← APK(s) + apk.sha256
    │       ├── app_data/          ← pulled data directories
    │       ├── meta/              ← dumpsys, permissions
    │       └── network/           ← keystore/net files, cert paths
    ├── reports/
    │   └── <timestamp>/
    │       ├── db/
    │       │   ├── databases.json
    │       │   └── databases.txt
    │       └── report.html
    ├── case.json                  ← case metadata (not git-tracked)
    ├── manifest.sha256            ← SHA-256 of all files in data/
    ├── packages.txt               ← tracked package IDs
    └── snapshot.log               ← snapshot timestamps (not git-tracked)
```

The `data/` directory appears to be overwritten on each snapshot, but the full history of every file is preserved in the git log. `case.json` and `snapshot.log` are intentionally excluded from git tracking so analysts can add notes freely without affecting evidence integrity.

---

## Script Reference

### snapshot.sh

Main entrypoint. Manages case lifecycle: creation, snapshots, git history, and reports.

Each snapshot pulls all app data, builds a SHA-256 manifest, diffs it against the previous one, commits the result to git, and generates a report.

```bash
# Create a new case (emulator)
./snapshot.sh new-case com.example.app -e

# Create a new case (USB device)
./snapshot.sh new-case com.example.app -d

# Take a new snapshot
./snapshot.sh snap com.example.app -e

# Add a package to an existing case
./snapshot.sh add-package com.example.app com.example.app.companion -e

# Regenerate the latest report without snapshotting
./snapshot.sh report com.example.app

# List all cases
./snapshot.sh list
```

Device flags: `-e` for emulator (default), `-d` for USB device.

When creating a case, sibling packages (same base name) are detected automatically and you are prompted to include them.

---

### acquisition.sh

Interfaces directly with ADB to pull app files, APKs, and system metadata into a structured output directory. Called automatically by `snapshot.sh`, but can also be used standalone.

Pulls into `<out_dir>/`:

- `app_data/` — full data directories (`/data/data`, `/data/user`, `/data/user_de`, `/data_mirror`, `/storage/emulated`) including WAL/SHM files
- `apk/` — installed APK(s) with SHA-256 hashes
- `meta/` — `dumpsys` package info, declared permissions, granted permissions
- `network/` — UID-specific keystore/net files; cert/SSL paths noted from `app_data`

```bash
./acquisition.sh <package> <device_flag> <out_dir>

# Examples
./acquisition.sh com.example.app -e ./output
./acquisition.sh com.example.app -d /mnt/cases/com.example.app/data/com.example.app
```

Root access is detected automatically, trying `adb root`, `su -c`, `su 0 -c`, and `su 0` in order. Without root, acquisition is partial.

---

### db-report.sh

SQLite introspector. Walks all `.db` files in a case directory, extracts schema and row statistics, and writes structured output for use by `report.sh`.

```bash
./db-report.sh <case_dir> <report_name>

# Example
./db-report.sh ./cases/com.example.app 2024-01-15T10:00:00Z
```

Output goes to `<case_dir>/reports/<report_name>/db/`:

- `databases.json` — full schema, column info, row counts, and sample rows for all databases found
- `databases.txt` — plain text summary

Handles WAL/SHM journaling by copying sidecar files before querying. Skips encrypted or corrupt files with a warning.

---

### report.sh

Generates a standalone HTML report for a given snapshot. Called automatically by `snapshot.sh`, but can be run independently.

```bash
./report.sh <case_dir> <report_name>

# Example
./report.sh ./cases/com.example.app 2024-01-15T10:00:00Z
```

Output: `<case_dir>/reports/<report_name>/report.html`

The report includes:

- Case summary (packages, APK hash, snapshot count)
- Git commit history
- File manifest diff (added, removed, modified files since last snapshot)
- Permission changes
- Interactive database explorer (schema, row counts, sample data) — requires `db-report.sh` to have run first

All data is embedded in the HTML file; no server required to view it.

---

### activity-viewer.sh

Parses `dumpsys` output to list all activities registered for a package and lets you launch one interactively.

```bash
./activity-viewer.sh <package.name>

# Example
./activity-viewer.sh com.example.app
```

Displays a numbered menu of all activities found in the Activity Resolver Table. Select one to launch it on the connected device via `adb shell am start`.

---

### photo-timeline.sh

Hash-deduplicates files from an Android directory (or a local directory), groups identical content by first-seen timestamp, and prints a timeline. Useful for analysing app image caches, contact photos, and similar directories.

```bash
# Pull from device and analyse
./photo-timeline.sh <remote_path> [-d|-e]

# Analyse a local directory directly
./photo-timeline.sh <local_path>

# Examples
./photo-timeline.sh /data/data/com.example.app/cache/contact_photos -e
./photo-timeline.sh /data/data/com.example.app/cache/contact_photos -d
./photo-timeline.sh ./pulled_cache
```

Options:

| Flag         | Description                                                  |
| ------------ | ------------------------------------------------------------ |
| `--no-image` | Skip inline image rendering                                  |
| `--keep`     | Keep pulled files in `./photo_timeline_pull/` after analysis |

Each unique content hash is assigned a deterministic human-readable name (e.g. `frozen-signal-3a7f`) for easy cross-reference. Files with the same content but different names or timestamps are grouped together, and any with a gap of more than one day between appearances are flagged as notable.

Inline image rendering is supported for Kitty, iTerm2, WezTerm, and Sixel-capable terminals.
