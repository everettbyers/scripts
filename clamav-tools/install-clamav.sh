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
QUARANTINE_SOURCE="$SCRIPT_DIR/list-quarantine.sh"

SCANNER_INSTALLED=/usr/local/sbin/scan-clamav.sh
CRON_INSTALLED=/etc/cron.d/clamav-host-scan
QUARANTINE_INSTALLED=/usr/local/sbin/list-clamav-quarantine.sh
EXPECTED_CRON='0 0 * * * root /bin/bash /usr/local/sbin/scan-clamav.sh'

# Verify all required repository files exist
for file in "$SCANNER_SOURCE" "$CRON_SOURCE" "$QUARANTINE_SOURCE"; do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Missing required file: $file" >&2
        exit 2
    fi
done

# Validate Bash scripts before installation
bash -n "$SCANNER_SOURCE"
bash -n "$QUARANTINE_SOURCE"

# Validate the actual scheduled command before installing anything.
if ! grep -Fxq -- "$EXPECTED_CRON" "$CRON_SOURCE"; then
    echo 'ERROR: Cron template must include the exact midnight scanner command:' >&2
    echo "  $EXPECTED_CRON" >&2
    exit 2
fi

# SUDO_USER is the invoking account; root's USER cannot identify it.
LOGIN_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$LOGIN_USER" || "$LOGIN_USER" == root ]]; then
    echo 'ERROR: Specify the account for /home/<user>/clamav-logs.' >&2
    echo 'Example: sudo bash install-clamav.sh pi' >&2
    exit 2
fi
if [[ ! "$LOGIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || ! id "$LOGIN_USER" >/dev/null 2>&1; then
    echo "ERROR: Invalid or unknown username: $LOGIN_USER" >&2
    exit 2
fi
USER_HOME="/home/$LOGIN_USER"
if [[ ! -d "$USER_HOME" ]]; then
    echo "ERROR: $USER_HOME does not exist." >&2
    exit 2
fi
USER_GROUP="$(id -gn "$LOGIN_USER")"
LOG_DIR="$USER_HOME/clamav-logs"
if [[ -L "$LOG_DIR" ]]; then
    echo "ERROR: Refusing symlink for log directory: $LOG_DIR" >&2
    exit 2
fi
QUARANTINE_DIR=/var/quarantine/clamav
CONFIG_FILE=/etc/clamav-host-scan-user

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y clamav clamav-freshclam cron util-linux

# Scanner writes user-readable logs; quarantine remains root-only.
install -d -o "$LOGIN_USER" -g "$USER_GROUP" -m 0700 "$LOG_DIR"
install -d -o root -g root -m 0700 "$QUARANTINE_DIR"

# Root cron uses this saved account instead of relying on $USER.
printf '%s\n' "$LOGIN_USER" > "$CONFIG_FILE"
chown root:root "$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

# Install reviewed, root-owned tools
install -o root -g root -m 0750 \
    "$SCANNER_SOURCE" "$SCANNER_INSTALLED"

install -o root -g root -m 0750 \
    "$QUARANTINE_SOURCE" "$QUARANTINE_INSTALLED"

# Install midnight cron configuration
install -o root -g root -m 0644 \
    "$CRON_SOURCE" "$CRON_INSTALLED"

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
printf 'Logs:       %s\n' "$LOG_DIR"
printf 'Quarantine: %s\n' "$QUARANTINE_DIR"
printf 'Schedule:   Every night at midnight (server local time)\n\n'
printf '\nView quarantined files:\n'
printf '  sudo %s\n' "$QUARANTINE_INSTALLED"

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
printf '\nGit pulls do not replace the installed root-owned scanner.\n'
printf 'Rerun this installer after reviewing and approving scanner updates.\n'
