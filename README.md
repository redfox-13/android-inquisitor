# android-inquisitor

A collection of scripts that help in the acquisition of android app data for forensic research. These scripts focus on the forensic analysis of a single app or app bundle and is not though out to be a full android acquisition tool.

Note: These scripts were done with the help of AI.

## Features

- **Root Detection**: Automatic root detection method that tries to apply root privilege before acquiring data.
- **Deep Acquisition**: The acquisition script searches multiple data directories, like `/data/data`, `/data/user_de` and `/storage/emulated` to pull from the device.
- **Unique location finder**: Compares all acquisition directories and verifies if they point to a unique node (inode).
- **Evidence Integrity**: All acquired files are passed through SHA256 to create a manifest with all file hashes, to verify file integrity.
- **Versioning Behavior**: For every snapshot created, a commit is done using git as the base, creating an historical database of all files.
- **SQLite Database finder**: Auxiliary script that creates a JSON file with all found databases inside the pulled directories.
- **HTML report**: Another auxiliary script that generates a standalone, searchable report with manifest diffs, permission changes, and a database explorer.

## Scripts

1. `snapshot.sh`: The main script of the collection. Manages each case lifecycle: creation, snapshot behavior and git history.
1. `acquisition.sh`: A script that interfaces with ADB to pull files, APKs and system metadata. Can be used as a standalone script.
1. `db_report.sh`: A SQLite database analyzer that handles WAL/SHM journaling and transforms all findings into a JSON file.
1. `report.sh`: The HTML file generator that produces a report on what happened on each snapshot.

## Requirements

`ADB`: Android Debug Bridge installed and in PATH.

`Git`: Required for state tracking and versioning.

`Python 3`: Used for JSON processing and report generation.

`SQLite3`: Required for database parsing.

## Usage

### 1. Start a new case

Create a new case for the app you want to investigate.

```bash
# Create a case for the app with ID com.example.app in emulator (-e)
./snapshot.sh new-case com.example.app -e

# or in connected device (-d)
./snapshot.sh new-case com.example.app -d
```

After running this command a new directory named `cases` will appear.

Inside that directory you can find all your app studies, separated by app ID. For example, all data for `com.example.app` can be found in `cases/com.example.app`.

### 2. Do some research

After creating your first case, you can go to the created case (e.g. `cases/com.example.app`) and explore the case.

More information on how evidence is stored is in [evidence strucutre](##%20Evidence%20Structure)

### 3. Create another snapshot

Whenever you require another snapshot of the app files, simply run:

```bash
# for emulator
./snapshot.sh snap <case_name> -e

# for connected device
./snapshot.sh snap <case_name> -d
```

### Other uses

Add another package to the case. Useful for apps that come in bundles.

```bash
./snapshot.sh add-package <case_id>
```

Create a report of the current commit for the chosen case.

```bash
./snapshot.sh report <case_id>
```

List all cases.

```bash
./snapshot.sh list
```

## Configuration (Environment Variables)

You can override default behaviors by setting environment variables before running the scripts.

|  Variable |     Default     | Description                                                          |
| --------: | :-------------: | -------------------------------------------------------------------- |
|       ADB | adb (from PATH) | Path to a specific ADB binary.                                       |
| CASES_DIR |     ./cases     | The root directory where all forensic cases and evidence are stored. |

Examples:

```bash
# Using a different ADB path
ADB=/path/to/custom/adb ./snapshot.sh snap my-case -d

# Read the cases from an external storage device
CASES_DIR=/mnt/externalSSD/Forensics ./snapshot.sh list

# Keep using the external storage device for this session
export CASES_DIR="/mnt/externalSSD/Forensics"
./snapshot.sh list
./snapshot.sh snap com.example.app -d

# Mix both
ADB=/path/to/custom/adb CASES_DIR=/mnt/externalSSD/Forensics ./snapshot.sh snap my-case -d
```

## Evidence structure

All cases are stored with the following structure:

- `data/`: Contains the data acquired for the defined apps bundle, separated by ID.
  - `data/<com.example.app>/apk/`: Copy of the base APK and other split APKs, together with their SHA256 hashes.
  - `data/<com.example.app>/app_data/`: All the data found by the acquisition script in each directory.
  - `data/<com.example.app>/meta/`: Metadata about the app, like declared and granted permissions and dumpsys information.
  - `data/<com.example.app>/network/`: Collects UID-specific security artefacts from `/data/misc/keystore` and `/data/misc/net`, as well as certificates found in the app files.
- `reports/`: All reports created for this case go here, separated by name (all automatic reports are named with the current time).
  - `<report_name>/db/`: Information about the databases found from the pulled files. Created with `db_report.sh`.
  - `<report_name>/report.html`: The standalone HTML file with the summary of the findings, together with a database explorer (if the database data is provided previously).
  - `case.json`: Metadata about the current case being studied. Has optional fields like `investigator` and `notes`.
  - `manifest.sha256`: Manifest with all SHA256 file hashes and names.
  - `packages.txt`: Information about the currently tracked app/package IDs.
  - `snapshot.log`: Logged information about the time of each snapshot.

**Note:** The root of each case is a local Git repository. While the `data/` folder appears to be overwritten with each snapshot, the full history of every file is preserved in the Git logs, allowing for historical debugging of the app's state.
