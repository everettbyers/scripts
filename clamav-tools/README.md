# Headless ClamAV standalone scanner (Debian/Ubuntu)

Two scripts:

- `install-clamav.sh`: installs `clamav`, `clamav-freshclam`, `cron`, and `util-linux`; enables FreshClam; creates the log and quarantine directories; records the login username for cron.
- `scan-clamav.sh`: checks signatures with `freshclam` **before every scan**, then runs standalone `clamscan`, writing timestamped logs. In normal mode, detections are **moved into quarantine, never deleted**. `--dry-run` performs detection-only scans.

`clamd` and Docker are not required.

## Setup from GitHub

Replace `OWNER/REPO` with the repository you uploaded these files to:

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/OWNER/REPO.git /opt/clamav-tools
sudo bash /opt/clamav-tools/install-clamav.sh
```

**Log account:** Under `sudo`, the installer automatically uses `SUDO_USER` rather than `USER=root`. If installing from a root shell, supply the username explicitly: `sudo bash /opt/clamav-tools/install-clamav.sh pi`. The user must have `/home/<user>`.

- Scan logs: `/home/<login-user>/clamav-logs/host-scan-*.log`
- Quarantine: `/var/quarantine/clamav/<timestamp>-<pid>/` (root-only)
- Configured login user: `/etc/clamav-host-scan-user` (root-owned)

The login user can read and modify their logs. These are convenience logs, **not tamper-resistant system audit logs**.

## Run a scan

First, check detections without moving anything:

```bash
sudo bash /opt/clamav-tools/scan-clamav.sh --dry-run
```

Normal mode moves detections into quarantine:

```bash
sudo bash /opt/clamav-tools/scan-clamav.sh
```

Override scan targets with absolute directories:

```bash
sudo bash /opt/clamav-tools/scan-clamav.sh --dry-run /etc /usr/local
sudo bash /opt/clamav-tools/scan-clamav.sh /srv /home
```

Defaults: `/home`, `/root`, `/opt`, `/srv`, `/var/www`, `/tmp`, `/var/tmp`, and `/var/spool` (only paths that exist). `/etc` and `/usr/local` are deliberately excluded from defaults to avoid removing critical host files. `--cross-fs=no` avoids crossing into mounted filesystems while recursing; symlinks aren't followed. Docker engine storage, `/proc`, `/sys`, `/dev`, `/run`, quarantine, and the user log directory are excluded. Application bind-mount data within `/home` or `/srv` **may still be moved if ClamAV detects malware**. Review these locations before scheduling automatic quarantine.

A failed FreshClam run causes the scan to **abort** instead of proceeding without a successful update check. The updater daemon is paused during the manual check and restarted if it had been running.

## Optional weekly cron job

```bash
sudo install -m 0644 /opt/clamav-tools/cron/clamav-host-scan /etc/cron.d/clamav-host-scan
sudo systemctl enable --now cron
sudo cat /etc/cron.d/clamav-host-scan
```

The cron example executes **every Sunday at 03:30 in server-local time**. It runs the scanner **directly from the clone**, and automatically uses the username saved by the installer. Change the `/etc/cron.d/clamav-host-scan` command to include `--dry-run` if automatic quarantine is not appropriate for your data.

Logs:

```bash
sudo ls -lt /home/$(cat /etc/clamav-host-scan-user)/clamav-logs/
sudo grep -h 'FOUND' /home/$(cat /etc/clamav-host-scan-user)/clamav-logs/host-scan-*.log
sudo ls -laR /var/quarantine/clamav/
```

If there is no MTA configured, cron itself may not send email for failures; the scan process writes its own per-run log. Errors before logging begins show up in cron's local logs (`journalctl -u cron`).

## Update the scripts

```bash
sudo git -C /opt/clamav-tools pull --ff-only
```

Keep the Git checkout **root-owned** and not writable by unprivileged accounts, and review incoming changes before pulling: cron executes the scripts as root. The cron job does **not** automatically update the Git checkout.

`clamscan` exit status: `0` clean, `1` threats found, `2` error. A full scan can take significant time/memory, particularly on a Raspberry Pi. Automatically quarantining files used by active services can break them, so start with a dry run.
