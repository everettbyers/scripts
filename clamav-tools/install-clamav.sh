#!/usr/bin/env bash
# Debian/Ubuntu headless ClamAV standalone installer.
# Usage: sudo bash install-clamav.sh [login_user]
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo 'ERROR: Run using sudo (or as root with a username argument).' >&2
    exit 2
fi
if (( $# > 1 )); then
    echo 'Usage: sudo bash install-clamav.sh [login_user]' >&2
    exit 2
fi
if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    echo 'ERROR: Requires a Debian/Ubuntu systemd host with APT.' >&2
    exit 2
fi

# Locate repo files regardless of the Git clone path.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCANNER_SOURCE="$SCRIPT_DIR/scan-clamav.sh"
CRON_SOURCE="$SCRIPT_DIR/cron/clamav-host-scan"
LIST_SOURCE="$SCRIPT_DIR/list-quarantine.sh"
MANAGER_SOURCE="$SCRIPT_DIR/manage-quarantine.sh"
SCANNER_INSTALLED=/usr/local/sbin/scan-clamav.sh
CRON_INSTALLED=/etc/cron.d/clamav-host-scan
LIST_INSTALLED=/usr/local/sbin/list-clamav-quarantine.sh
MANAGER_INSTALLED=/usr/local/sbin/manage-clamav-quarantine.sh
EXPECTED_CRON='0 0 * * * root /bin/bash /usr/local/sbin/scan-clamav.sh'

for source_file in "$SCANNER_SOURCE" "$CRON_SOURCE" "$LIST_SOURCE" "$MANAGER_SOURCE"; do
    if [[ ! -f "$source_file" ]]; then
        echo "ERROR: Missing required repository file: $source_file" >&2
        exit 2
    fi
done
bash -n "$SCANNER_SOURCE"
bash -n "$LIST_SOURCE"
bash -n "$MANAGER_SOURCE"

# Validate the actual scheduled command before installing anything.
if ! grep -Fxq -- "$EXPECTED_CRON" "$CRON_SOURCE"; then
    echo 'ERROR: Cron template must include the exact midnight scanner command:' >&2
    echo "  $EXPECTED_CRON" >&2
    exit 2
fi

# Optional legacy username argument is accepted but no longer used.
LOG_DIR=/var/log/clamav
if [[ -L "$LOG_DIR" ]]; then
    echo "ERROR: Refusing symlink for log directory: $LOG_DIR" >&2
    exit 2
fi
QUARANTINE_DIR=/var/quarantine/clamav

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y clamav clamav-freshclam cron util-linux

# Preserve existing package-managed ClamAV directory permissions.
if [[ ! -d "$LOG_DIR" ]]; then
    install -d -o clamav -g "$(id -gn clamav)" -m 0750 "$LOG_DIR"
fi
if ! runuser -u clamav -- test -w "$LOG_DIR"; then
    echo "ERROR: clamav cannot write to $LOG_DIR; check permissions." >&2
    exit 2
fi
install -d -o root -g root -m 0700 "$QUARANTINE_DIR"

# Install reviewed, root-owned copies rather than running Git worktree files.
install -o root -g root -m 0750 "$SCANNER_SOURCE" "$SCANNER_INSTALLED"
install -o root -g root -m 0750 "$LIST_SOURCE" "$LIST_INSTALLED"
install -o root -g root -m 0750 "$MANAGER_SOURCE" "$MANAGER_INSTALLED"
install -o root -g root -m 0644 "$CRON_SOURCE" "$CRON_INSTALLED"

systemctl enable --now clamav-freshclam
systemctl enable --now cron

printf '\n=== Installation verification ===\n'
clamscan --version
printf 'FreshClam: '
systemctl is-active clamav-freshclam
printf 'Cron: '
systemctl is-active cron
printf 'Scanner syntax: '
bash -n "$SCANNER_INSTALLED" && echo 'OK'
printf 'Installed schedule:\n'
cat "$CRON_INSTALLED"

printf '\n========================================\n'
printf ' ClamAV Installation Complete\n'
printf '========================================\n'
printf 'Scanner:    %s\n' "$SCANNER_INSTALLED"
printf 'List:       %s\n' "$LIST_INSTALLED"
printf 'Manager:    %s\n' "$MANAGER_INSTALLED"
printf 'Logs:       %s\n' "$LOG_DIR"
printf 'Quarantine: %s\n' "$QUARANTINE_DIR"
printf 'Schedule:   Every night at midnight (server local time)\n\n'

# Optional post-installation dry run; skip for unattended installation.
if [[ -t 0 ]]; then
    REPLY=''
    if read -r -p 'Run a ClamAV detection-only scan of /etc now? [y/N]: ' REPLY; then
        case "$REPLY" in
            [Yy]|[Yy][Ee][Ss])
                echo 'Running detection-only scan; no files will be moved or deleted.'
                SCAN_RESULT=0
                bash "$SCANNER_INSTALLED" --dry-run /etc || SCAN_RESULT=$?
                case "$SCAN_RESULT" in
                    0) echo 'Dry run completed: no threats detected.' ;;
                    1) echo "Dry run completed: detections found. Review $LOG_DIR." ;;
                    *) echo "ERROR: Scan failed (exit $SCAN_RESULT)." >&2; exit "$SCAN_RESULT" ;;
                esac
                ;;
            *) echo 'Dry run skipped.' ;;
        esac
    else
        echo 'No response received; dry run skipped.'
    fi
else
    echo 'Non-interactive installation: dry run skipped.'
fi

printf '\nManual detection-only scan:\n  sudo bash %s --dry-run /etc\n' "$SCANNER_INSTALLED"
printf 'Normal scan (moves detections to quarantine):\n  sudo bash %s\n' "$SCANNER_INSTALLED"
printf 'List quarantined files:\n  sudo %s\n' "$LIST_INSTALLED"
printf 'Manage quarantined files:\n  sudo %s\n' "$MANAGER_INSTALLED"
printf '\nGit pulls do not replace the installed root-owned scanner.\n'
printf 'Rerun this installer after reviewing and approving scanner updates.\n'
