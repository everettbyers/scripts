# ClamAV standalone CLI tools

Debian/Ubuntu headless ClamAV toolkit. The installer uses the current Git checkout location, installs root-owned copies of the utilities, configures FreshClam, and schedules a scan for midnight **server-local** time.

## Install

From a clone of `https://github.com/everettbyers/scripts`:

```bash
sudo bash "$HOME/scripts/clamav-tools/install-clamav.sh"
```

The installer also creates a private quarantine directory (`/var/quarantine/clamav`), a log directory (`/home/<login-user>/clamav-logs`), and a user configuration file. It offers an optional detection-only scan of `/etc` at the end.

## Commands

```bash
# Detection-only manual scan; does not move files
sudo bash /usr/local/sbin/scan-clamav.sh --dry-run

# Scan default directories; move detections to root-only quarantine
sudo bash /usr/local/sbin/scan-clamav.sh

# Scan a specific existing directory (detection only)
sudo bash /usr/local/sbin/scan-clamav.sh --dry-run /srv/data

# Read-only quarantine inventory
sudo /usr/local/sbin/list-clamav-quarantine.sh

# Interactive management: list, inspect, restore, delete, usage
sudo /usr/local/sbin/manage-clamav-quarantine.sh
```

The manager requires an interactive terminal and root privileges. **Restore** defaults to a protected directory at `/var/quarantine/clamav-review/`; an advanced option accepts an explicitly entered absolute target path. It does not guess the original location because `clamscan --move` does not store it. Scan logs may help identify that location. Never restore potentially infected files into active Docker/Nextcloud application data without verifying them. **Delete** permanently removes one selected quarantined file and requires typing `DELETE`. Neither action is performed automatically.

The manager never executes quarantined files. Inspection displays file metadata and a SHA-256 hash, plus the detected file type when `file` is installed. Both manager and scanner coordinate through `/run/lock/clamav-host-scan.lock` to prevent simultaneous changes.

## Cron schedule

The installer creates `/etc/cron.d/clamav-host-scan`:

```cron
0 0 * * * root /bin/bash /usr/local/sbin/scan-clamav.sh
```

The scanner refreshes FreshClam signatures before scanning, aborts if that update fails, and records scan output in `/home/<login-user>/clamav-logs`. Quarantine actions during regular scans may disrupt live applications; review default targets before enabling unattended scans.

## Updating from GitHub

```bash
git -C "$HOME/scripts" pull --ff-only
# Review the changes before installing as root:
git -C "$HOME/scripts" diff HEAD~1..HEAD -- clamav-tools/
sudo bash "$HOME/scripts/clamav-tools/install-clamav.sh"
```

A Git pull **does not** update installed, root-owned scripts until the installer is rerun. Avoid executing root cron scripts directly from the user-writable Git working tree.
