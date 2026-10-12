# ClamAV CLI scanner for Debian / Ubuntu

Run `install-clamav.sh` once on each server. It installs the packages, creates a per-user log directory and root-only quarantine, records the login username for cron, installs a **root-owned** copy of the scanner, enables FreshClam, and installs the midnight cron job.

The scanner (`scan-clamav.sh`) runs `freshclam` before **each** scan, aborts if signatures could not be checked, uses standalone `clamscan` (no persistent `clamd` daemon), writes timestamped logs, and normally **moves** detected files to quarantine (never deletes them). Use `--dry-run` to detect without moving files.

## Repository layout

```text
scripts/
  clamav-tools/
    install-clamav.sh
    scan-clamav.sh
    cron/clamav-host-scan
    README.md
```

## Clone and install

For the GitHub repository `everettbyers/scripts`:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/everettbyers/scripts.git "$HOME/scripts"
sudo bash "$HOME/scripts/clamav-tools/install-clamav.sh"
```

If the repo was cloned already, skip `git clone`. Under `sudo`, the installer uses `SUDO_USER` to select `/home/<user>/clamav-logs`. From a root login shell, specify the login account explicitly, for example:

```bash
bash /home/pi/scripts/clamav-tools/install-clamav.sh pi
```

**Install locations:**

- Installed scanner: `/usr/local/sbin/scan-clamav.sh` (`root:root`, mode `750`)
- Installed cron file: `/etc/cron.d/clamav-host-scan` (`root:root`, mode `644`)
- Configuration: `/etc/clamav-host-scan-user` (`root:root`, mode `600`)
- Logs: `/home/<login-user>/clamav-logs/`
- Quarantine: `/var/quarantine/clamav/`

Cron runs every night at **00:00 (server local time)**. It executes the installed root-owned scanner, not the user-writable Git checkout.

## Verify and run manually

```bash
sudo cat /etc/cron.d/clamav-host-scan
systemctl is-active cron
sudo bash -n /usr/local/sbin/scan-clamav.sh
sudo bash /usr/local/sbin/scan-clamav.sh --dry-run /etc
```

The last command is a **manual test**, not part of installation or cron. It updates/checks virus signatures first. Run normally to quarantine detections:

```bash
sudo bash /usr/local/sbin/scan-clamav.sh
```

You can override the default scan directories by supplying absolute paths. Defaults: `/home /root /opt /srv /var/www /tmp /var/tmp /var/spool` when present. The script avoids mounted filesystems, symlinks, virtual filesystems, Docker engine storage, its own logs and quarantine. Docker application data under `/home` or `/srv` may still be scanned and quarantined.

Scan logs are readable by the configured user, but they are not tamper-resistant audit records. Quarantine is root-only.

## Update the Git checkout

As the account that owns the checkout:

```bash
git -C "$HOME/scripts" pull --ff-only
```

**Important:** Git pull does *not* automatically deploy changed root-owned scanner code or cron configuration. Review the code and rerun the installer to deploy an approved update:

```bash
sudo bash "$HOME/scripts/clamav-tools/install-clamav.sh"
```

The existing separate 10 PM Git-pull cron can update your repository without automatically elevating new code to root. The installed midnight ClamAV job remains unchanged until you rerun the installer.

**Caution:** Automatic quarantine can disrupt live applications, especially Docker bind mounts. Test with `--dry-run` first. A full scan may take significant time and memory on a Raspberry Pi.
