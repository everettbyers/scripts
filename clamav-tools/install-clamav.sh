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

# Under sudo, USER is usually root. SUDO_USER names the real login account.
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
    echo "ERROR: $USER_HOME does not exist (logs are configured for /home/<user>)." >&2
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

# Logs are writable by the login account; the scanner writes logs with that
# account's privileges even though filesystem scans run as root.
install -d -o "$LOGIN_USER" -g "$USER_GROUP" -m 0700 "$LOG_DIR"
chmod 0700 "$LOG_DIR"
install -d -o root -g root -m 0700 "$QUARANTINE_DIR"

# Cron cannot rely on SUDO_USER or USER. Persist the chosen account.
printf '%s\n' "$LOGIN_USER" > "$CONFIG_FILE"
chown root:root "$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

systemctl enable --now clamav-freshclam
systemctl enable --now cron

printf '\nInstallation complete.\n'
clamscan --version
printf 'Log directory: %s\nQuarantine directory: %s\n' "$LOG_DIR" "$QUARANTINE_DIR"
printf 'Signature updater: '
systemctl is-active clamav-freshclam
printf 'Cron: '
systemctl is-active cron
printf '\nTry a detection-only scan from the Git checkout:\n'
printf '  sudo bash /opt/clamav-tools/scan-clamav.sh --dry-run\n'
printf '\nRun normally to move detected files to quarantine:\n'
printf '  sudo bash /opt/clamav-tools/scan-clamav.sh\n'
