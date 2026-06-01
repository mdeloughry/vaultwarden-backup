# Vaultwarden Backup & Restore

Encrypted, automated backups of a self-hosted Vaultwarden instance to **local disk + Backblaze B2 + Cloudflare R2** using [restic](https://restic.net/). Includes a test-restore script so you can actually verify your backups work — the part everyone skips.

## What this does

- **`vw-tui`** — interactive Text User Interface (TUI) to run backups, view logs, browse snapshots, edit config, and trigger test/production restores in one dashboard.
- **`vw-backup.sh`** — nightly backup script. Snapshots SQLite cleanly (no downtime), archives the data directory, pushes encrypted snapshots to all three destinations, applies a retention policy.
- **`vw-test-restore.sh`** — restores any snapshot to a throwaway location, runs integrity checks, optionally spins up a test Vaultwarden container on a different port so you can log in and verify.
- **`vw-restore.sh`** — production restore. Stops your live Vaultwarden, preserves current data as `.pre-restore-TIMESTAMP`, restores the chosen snapshot, restarts the container.
- **`vw-setup.sh`** — one-time installer. Installs dependencies, generates a restic password, copies scripts to `/usr/local/bin`, creates config skeleton at `/etc/vaultwarden-backup/`.

## Prerequisites

- Linux host running Vaultwarden in Docker (tested on CasaOS / ZimaBlade)
- `restic`, `sqlite3`, `tar`, `docker`, `curl` (setup script will install these)
- A Backblaze B2 account with a bucket + scoped application key
- A Cloudflare R2 account with a bucket + scoped API token
- A mounted local disk for the local backup copy

## Installation

```bash
git clone https://github.com/YOUR-USERNAME/vaultwarden-backup.git
cd vaultwarden-backup
sudo ./scripts/vw-setup.sh
```

The setup script will:
1. Install missing dependencies via apt
2. Create `/etc/vaultwarden-backup/` (root-only)
3. Generate a random restic password and **display it once** — save this somewhere outside Vaultwarden
4. Copy scripts to `/usr/local/bin/`

## Configuration

Edit `/etc/vaultwarden-backup/backup.env`:

```bash
sudo nano /etc/vaultwarden-backup/backup.env
```

Set at minimum:

- `VW_DATA` — path to Vaultwarden's data directory (e.g. `/DATA/AppData/vaultwarden`)
- `RESTIC_REPO_LOCAL` — path to local backup directory
- `RESTIC_REPO_B2` + `B2_ACCOUNT_ID` + `B2_ACCOUNT_KEY`
- `RESTIC_REPO_R2` + `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`

Leave any `RESTIC_REPO_*` blank to skip that destination.

## Initialize repos

One-time, before first backup:

```bash
sudo bash -c '
  source /etc/vaultwarden-backup/backup.env
  export RESTIC_PASSWORD_FILE=/etc/vaultwarden-backup/restic-pw

  restic -r "$RESTIC_REPO_LOCAL" init

  export B2_ACCOUNT_ID B2_ACCOUNT_KEY
  restic -r "$RESTIC_REPO_B2" init

  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  restic -r "$RESTIC_REPO_R2" init
'
```

## Usage

### Manage via TUI

For an interactive dashboard to trigger backups, consistency checks, view logs, browse snapshots, edit config, and run test or production restores, run:

```bash
sudo vw-tui
```

### Run a backup manually

```bash
sudo vw-backup.sh
```

Add `--quiet` to suppress stdout (useful for cron).

### Schedule nightly via cron

```bash
sudo crontab -e
```

Add:

```
0 3 * * * /usr/local/bin/vw-backup.sh --quiet
```

Runs at 3 AM daily. Logs go to `/var/log/vw-backup.log`.

### Test a restore (do this quarterly!)

```bash
sudo vw-test-restore.sh local         # latest snapshot from local
sudo vw-test-restore.sh b2             # latest from B2
sudo vw-test-restore.sh r2 abc123      # specific snapshot from R2
```

This restores to `/tmp/vw-restore-test`, runs SQLite integrity checks, and optionally starts a disposable test Vaultwarden container:

- **HTTP** on port `18080` (override with `TEST_PORT`) — browser on the same host
- **HTTPS** on port `18443` (override with `TEST_HTTPS_PORT`) — serves via Caddy with an auto-generated self-signed cert valid for 7 days, so you can point Bitwarden mobile/desktop apps at it and test real login flows

The self-signed cert includes the machine's primary IP, Tailscale IP (if available), localhost, and hostname as Subject Alternative Names. Your browser will warn about the unknown issuer — click through. Some mobile apps refuse self-signed certs entirely; in that case, test via a browser.

Cleanup is automatic on exit (Ctrl+C) — containers stopped, network removed, restored data wiped.

### Production restore (disaster recovery)

⚠️ **This overwrites your live Vaultwarden data.**

```bash
sudo vw-restore.sh local               # latest from local
sudo vw-restore.sh b2 abc123           # specific snapshot from B2
```

The script:
1. Stops the Vaultwarden container
2. Moves current data to `$VW_DATA.pre-restore-TIMESTAMP` (so you can recover if the restore is bad)
3. Restores the chosen snapshot
4. Restarts the container

You must type `RESTORE` to confirm.

### List snapshots

```bash
# Load env + password
sudo bash -c '
  source /etc/vaultwarden-backup/backup.env
  export RESTIC_PASSWORD_FILE=/etc/vaultwarden-backup/restic-pw
  export B2_ACCOUNT_ID B2_ACCOUNT_KEY
  restic -r "$RESTIC_REPO_B2" snapshots
'
```

## Monitoring (optional)

Sign up at [healthchecks.io](https://healthchecks.io) (free tier), create a check, and paste the ping URL into `backup.env` as `HEALTHCHECK_URL`. You'll get emails when backups stop running or fail.

## Retention policy

Defaults:
- 7 daily snapshots
- 4 weekly snapshots
- 12 monthly snapshots

Override in `backup.env` with `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY`.

## Security notes

- `/etc/vaultwarden-backup/` is root-only (mode 700)
- `backup.env` and `restic-pw` are mode 600
- Credentials live in `backup.env`, NEVER in the scripts themselves
- The restic password encrypts all backups — losing it means losing your backups
- **Store the restic password outside Vaultwarden**: work 1Password, paper in a safe, trusted family member, whatever. Just not inside the thing you're backing up.

## Troubleshooting

**`Permission denied` when running script** — run with `sudo`. The scripts need to read Vaultwarden's data directory and `/etc/vaultwarden-backup/`.

**`sqlite3: command not found`** — `sudo apt install sqlite3`

**`restic: command not found`** — `sudo apt install restic`

**tar `--exclude has no effect`** — your tar version needs `--exclude` BEFORE the source path. The script handles this already; check you've not modified the tar line.

**`unable to open config file`** — repo isn't initialized. Run `restic -r <repo> init` first.

**Backup runs but no snapshots appear** — check `/var/log/vw-backup.log` for errors. The script exits on first failure so only repos that ran before the failure will have snapshots.

## License

MIT
