#!/usr/bin/env bash
# FreshClam update -> standalone clamscan -> logged scan/quarantine.
# Works manually and in cron, directly from a root-owned Git checkout.
set -Eeuo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage: sudo bash scan-clamav.sh [--dry-run] [--] [ABSOLUTE_DIRECTORY ...]

No directory arguments: scan /home /root /opt /srv /var/www /tmp /var/tmp /var/spool
--dry-run    Detect and log, but do not quarantine files.
--help       Show this help.

Exit status: 0 clean, 1 detections, 2 errors.
USAGE
}

DRY_RUN=0
TARGETS=()
while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        --) shift; TARGETS+=("$@"); break ;;
        -*) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) TARGETS+=("$1") ;;
    esac
    shift
done

if (( EUID != 0 )); then
    echo 'ERROR: Run with sudo.' >&2
    exit 2
fi
for tool in clamscan freshclam flock systemctl tee runuser; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Missing command: $tool (run install-clamav.sh first)" >&2
        exit 2
    fi
done

LOG_DIR=/var/log/clamav
if [[ -L "$LOG_DIR" || ! -d "$LOG_DIR" ]]; then
    echo "ERROR: Invalid or missing log directory: $LOG_DIR" >&2
    exit 2
fi
if ! runuser -u clamav -- test -w "$LOG_DIR"; then
    echo "ERROR: clamav cannot write to $LOG_DIR; check permissions." >&2
    exit 2
fi

# Reject overlapping runs before updating signatures or writing scan output.
exec 9>/run/lock/clamav-host-scan.lock
if ! flock -n 9; then
    echo 'ERROR: Another ClamAV host scan is already running.' >&2
    exit 2
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
LOG_FILE="$LOG_DIR/host-scan-$RUN_ID.log"
QUARANTINE_BASE=/var/quarantine/clamav
QUARANTINE_DIR="$QUARANTINE_BASE/$RUN_ID"

# Verify that the log file can be created before scanning.
if ! runuser -u clamav -- touch -- "$LOG_FILE"; then
    echo "ERROR: Cannot create scan log: $LOG_FILE" >&2
    exit 2
fi

# Write operational logs as clamav, not root.
# These logs are not tamper-resistant security audit records.
exec > >(runuser -u clamav -- tee -a -- "$LOG_FILE") 2>&1
printf 'ClamAV scan started: %s\nLog: %s\nMode: %s\n' \
    "$(date -Is)" "$LOG_FILE" "$([[ $DRY_RUN == 1 ]] && echo detection-only || echo quarantine)"

RESTART_FRESHCLAM=0
restore_updater() {
    if (( RESTART_FRESHCLAM )); then
        echo 'Restoring the clamav-freshclam service...'
        if systemctl start clamav-freshclam; then
            RESTART_FRESHCLAM=0
        else
            echo 'ERROR: Could not restart clamav-freshclam.' >&2
        fi
    fi
}
trap restore_updater EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '\n[1/3] Updating signature database using FreshClam...\n'
if systemctl is-active --quiet clamav-freshclam; then
    RESTART_FRESHCLAM=1
    systemctl stop clamav-freshclam
fi
if ! freshclam --stdout; then
    echo 'ERROR: FreshClam update/check failed. Scan aborted.' >&2
    exit 2
fi
if (( RESTART_FRESHCLAM )); then
    if ! systemctl start clamav-freshclam; then
        echo 'ERROR: Update succeeded, but clamav-freshclam did not restart.' >&2
        exit 2
    fi
    RESTART_FRESHCLAM=0
fi
clamscan --version

if (( ${#TARGETS[@]} == 0 )); then
    TARGETS=(/home /root /opt /srv /var/www /tmp /var/tmp /var/spool)
fi
EXISTING=()
for path in "${TARGETS[@]}"; do
    if [[ "$path" != /* ]]; then
        echo "ERROR: Scan directories must be absolute: $path" >&2
        exit 2
    fi
    if [[ -d "$path" ]]; then
        EXISTING+=("$path")
    else
        echo "Skipping missing directory: $path"
    fi
done
if (( ${#EXISTING[@]} == 0 )); then
    echo 'ERROR: No scan directories exist.' >&2
    exit 2
fi

SCAN_OPTS=(
    --recursive
    --infected
    --cross-fs=no
    --follow-dir-symlinks=0
    --follow-file-symlinks=0
    '--exclude-dir=^/proc(/|$)'
    '--exclude-dir=^/sys(/|$)'
    '--exclude-dir=^/dev(/|$)'
    '--exclude-dir=^/run(/|$)'
    '--exclude-dir=^/var/lib/docker(/|$)'
    '--exclude-dir=^/var/lib/containerd(/|$)'
    '--exclude-dir=^/var/quarantine(/|$)'
    '--exclude-dir=^/var/log/clamav(/|$)'
)

if (( DRY_RUN == 0 )); then
    install -d -o root -g root -m 0700 "$QUARANTINE_DIR"
    SCAN_OPTS+=("--move=$QUARANTINE_DIR")
    echo "Quarantine: $QUARANTINE_DIR"
else
    echo 'DRY RUN: detections will be logged but no files will be moved.'
fi

printf '\n[2/3] Scanning the following directories:\n'
printf '  %s\n' "${EXISTING[@]}"
RESULT=0
clamscan "${SCAN_OPTS[@]}" "${EXISTING[@]}" || RESULT=$?

printf '\n[3/3] Finished: %s\nLog: %s\n' "$(date -Is)" "$LOG_FILE"
case "$RESULT" in
    0) echo 'STATUS: CLEAN' ;;
    1)
        if (( DRY_RUN )); then
            echo 'STATUS: DETECTED (dry run; no files moved)'
        else
            echo 'STATUS: DETECTED (review logs and quarantine)'
        fi
        ;;
    *) echo "STATUS: ERROR OR INCOMPLETE SCAN (exit $RESULT)" ;;
esac
exit "$RESULT"
