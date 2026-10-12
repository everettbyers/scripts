#!/usr/bin/env bash
# List ClamAV quarantined files with modification date, size and full path.
# Usage: sudo bash list-quarantine.sh
set -Eeuo pipefail

QUARANTINE_DIR=/var/quarantine/clamav

if (( EUID != 0 )); then
    echo 'ERROR: Run with sudo to access the protected quarantine directory.' >&2
    exit 1
fi

if [[ ! -d "$QUARANTINE_DIR" ]]; then
    echo "No quarantine directory found: $QUARANTINE_DIR"
    exit 0
fi

if [[ -z "$(find "$QUARANTINE_DIR" -type f -print -quit)" ]]; then
    echo "No quarantined files found in $QUARANTINE_DIR"
    exit 0
fi

printf 'ClamAV quarantine: %s\n' "$QUARANTINE_DIR"
printf '%-16s %14s  %s\n' 'LAST MODIFIED' 'SIZE (bytes)' 'FULL PATH'
printf '%-16s %14s  %s\n' '-------------' '------------' '---------'

find "$QUARANTINE_DIR" -type f \
    -printf '%TY-%Tm-%Td %TH:%TM %14s  %p\n' | sort -r

printf '\nNote: Date is the file modification time, not necessarily its quarantine time.\n'
