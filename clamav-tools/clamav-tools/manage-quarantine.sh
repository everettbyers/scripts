#!/usr/bin/env bash
# Interactive, root-only ClamAV quarantine manager.
# Usage: sudo bash manage-quarantine.sh
# Does not execute or open quarantined content.
set -Eeuo pipefail
umask 077

QUARANTINE_DIR=/var/quarantine/clamav
REVIEW_DIR=/var/quarantine/clamav-review

if (( EUID != 0 )); then
    echo 'ERROR: Run this manager with sudo.' >&2
    exit 2
fi
if [[ ! -t 0 ]]; then
    echo 'ERROR: An interactive terminal is required.' >&2
    exit 2
fi
if [[ -L "$QUARANTINE_DIR" || -L "$REVIEW_DIR" ]]; then
    echo 'ERROR: Refusing a symlinked quarantine or review directory.' >&2
    exit 2
fi
if [[ ! -d "$QUARANTINE_DIR" ]]; then
    echo "No quarantine directory found: $QUARANTINE_DIR" >&2
    echo 'Run install-clamav.sh first.' >&2
    exit 2
fi

# Coordinate with the nightly scanner: do not modify quarantine mid-scan.
exec 9>/run/lock/clamav-host-scan.lock
if ! flock -n 9; then
    echo 'ERROR: A ClamAV host scan is running. Manage quarantine afterward.' >&2
    exit 2
fi

FILES=()
refresh_files() {
    # NUL-delimited listing handles whitespace, quotes, and newlines in names.
    mapfile -d '' -t FILES < <(find "$QUARANTINE_DIR" -type f -print0 | sort -z)
}

list_files() {
    refresh_files
    printf '\nClamAV quarantine: %s\n' "$QUARANTINE_DIR"
    if (( ${#FILES[@]} == 0 )); then
        echo 'No quarantined files found.'
        return
    fi
    printf '%-5s  %-16s  %12s  %s\n' 'INDEX' 'LAST MODIFIED' 'SIZE (bytes)' 'FULL PATH'
    for i in "${!FILES[@]}"; do
        file=${FILES[$i]}
        modified=$(stat -c '%y' -- "$file")
        modified=${modified:0:16}
        size=$(stat -c '%s' -- "$file")
        printf '%-5d  %-16s  %12s  %q\n' "$((i + 1))" "$modified" "$size" "$file"
    done
    echo 'Note: LAST MODIFIED is the file timestamp, not the quarantine date.'
}

SELECTED=''
select_file() {
    list_files
    (( ${#FILES[@]} > 0 )) || return 1
    local number
    read -r -p 'Select file number (Enter to cancel): ' number || return 1
    [[ "$number" =~ ^[0-9]+$ ]] || { echo 'Cancelled.'; return 1; }
    (( 10#$number >= 1 && 10#$number <= ${#FILES[@]} )) || { echo 'Invalid selection.'; return 1; }
    SELECTED=${FILES[$((10#$number - 1))]}
    # Recheck to avoid following or selecting a changed/symlinked file.
    if [[ ! -f "$SELECTED" || -L "$SELECTED" ]]; then
        echo 'ERROR: The selected file no longer exists as a regular file.' >&2
        return 1
    fi
    local resolved
    resolved=$(realpath -e -- "$SELECTED") || return 1
    [[ "$resolved" == "$QUARANTINE_DIR/"* ]] || {
        echo 'ERROR: Selected file resolves outside quarantine.' >&2
        return 1
    }
}

inspect_file() {
    select_file || return 0
    printf '\nSelected file: %q\n' "$SELECTED"
    stat -c 'Modified: %y' -- "$SELECTED"
    stat -c 'Size:     %s bytes' -- "$SELECTED"
    stat -c 'Owner:    %U:%G' -- "$SELECTED"
    stat -c 'Mode:     %a' -- "$SELECTED"
    if command -v file >/dev/null 2>&1; then
        printf 'Type:     '
        file -b -- "$SELECTED"
    fi
    printf 'SHA-256:  '
    sha256sum -- "$SELECTED" | cut -d ' ' -f 1
    echo 'Inspection does not execute the file or assert it is safe.'
}

restore_file() {
    select_file || return 0
    printf '\nSelected for restoration: %q\n' "$SELECTED"
    echo 'No original filesystem path is stored with --move; scan logs may help identify it.'
    echo '1) Restore to protected review directory (recommended)'
    echo '2) Restore to manually specified absolute path (advanced)'
    echo 'Enter) Cancel'
    local method dest parent answer run_dir
    read -r -p 'Choose destination [1/2]: ' method || return 0
    case "$method" in
        1)
            if [[ -L "$REVIEW_DIR" ]]; then
                echo 'ERROR: Review directory is a symlink.' >&2
                return 0
            fi
            run_dir=$(basename -- "$(dirname -- "$SELECTED")")
            if [[ "$run_dir" == . || "$run_dir" == / ]]; then
                echo 'ERROR: Invalid quarantine batch.' >&2
                return 0
            fi
            install -d -o root -g root -m 0700 -- "$REVIEW_DIR" "$REVIEW_DIR/$run_dir"
            dest="$REVIEW_DIR/$run_dir/$(basename -- "$SELECTED")"
            ;;
        2)
            echo 'WARNING: An infected file may be quarantined again, or compromise a live service.'
            echo 'Never restore to active Docker/Nextcloud data without verifying the file first.'
            read -r -p 'Enter the EXACT destination full path: ' dest || return 0
            if [[ "$dest" != /* || "$dest" == */ || "$dest" == *'/../'* || "$dest" == *'/./'* ]]; then
                echo 'ERROR: Use an absolute filename without parent-directory traversal.' >&2
                return 0
            fi
            parent=$(dirname -- "$dest")
            if [[ ! -d "$parent" || -L "$parent" ]]; then
                echo 'ERROR: Destination parent must exist and cannot be a symlink.' >&2
                return 0
            fi
            ;;
        *) echo 'Cancelled.'; return 0 ;;
    esac

    # Never overwrite an existing file or restore inside live quarantine.
    case "$dest" in
        "$QUARANTINE_DIR"/*|/proc/*|/sys/*|/dev/*|/run/*)
            echo 'ERROR: Unsafe destination path.' >&2
            return 0
            ;;
    esac
    if [[ -e "$dest" || -L "$dest" ]]; then
        printf 'ERROR: Destination already exists: %q\n' "$dest" >&2
        return 0
    fi
    printf 'Restore from: %q\n' "$SELECTED"
    printf 'Restore to:   %q\n' "$dest"
    read -r -p 'Type RESTORE to confirm: ' answer || return 0
    [[ "$answer" == RESTORE ]] || { echo 'Cancelled.'; return 0; }
    # Restore is an explicit move, not a content inspection or decontamination.
    mv --no-clobber -- "$SELECTED" "$dest"
    if [[ -e "$SELECTED" ]]; then
        echo 'ERROR: Source still exists. Check for destination conflict.' >&2
    else
        echo "Moved to: $dest"
        echo 'Treat this file as suspicious until a false positive is confirmed.'
    fi
}

delete_file() {
    select_file || return 0
    printf '\nFile to PERMANENTLY DELETE: %q\n' "$SELECTED"
    read -r -p 'Type DELETE to confirm: ' answer || return 0
    if [[ "$answer" == DELETE ]]; then
        rm -- "$SELECTED"
        echo 'File deleted.'
    else
        echo 'Cancelled.'
    fi
}

disk_usage() {
    echo
    printf 'Quarantine files: '
    find "$QUARANTINE_DIR" -type f -printf '.\n' | wc -l
    du -sh -- "$QUARANTINE_DIR"
    if [[ -d "$REVIEW_DIR" ]]; then
        printf 'Restored-to-review files: '
        find "$REVIEW_DIR" -type f -printf '.\n' | wc -l
        du -sh -- "$REVIEW_DIR"
    fi
}

while true; do
    printf '\n========================================\n'
    printf '       ClamAV Quarantine Manager\n'
    printf '========================================\n'
    printf '1) List quarantined files\n'
    printf '2) Inspect a quarantined file\n'
    printf '3) Restore a quarantined file\n'
    printf '4) Delete a quarantined file\n'
    printf '5) View quarantine disk usage\n'
    printf '6) Exit\n'
    if ! read -r -p 'Select [1-6]: ' choice; then
        printf '\n'
        break
    fi
    case "$choice" in
        1) list_files ;;
        2) inspect_file ;;
        3) restore_file ;;
        4) delete_file ;;
        5) disk_usage ;;
        6) break ;;
        *) echo 'Choose a number from 1 through 6.' ;;
    esac
done
