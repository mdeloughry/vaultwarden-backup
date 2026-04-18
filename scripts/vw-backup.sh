#!/bin/bash
# vw-backup.sh — Backup Vaultwarden data to local, B2, and R2 via restic
#
# Usage: sudo ./vw-backup.sh [--quiet]
#
# Requires: sqlite3, restic, tar
# Env file: /etc/vaultwarden-backup/backup.env
# Restic password file: /etc/vaultwarden-backup/restic-pw

set -euo pipefail

# ──────────────── Config ────────────────

ENV_FILE="${VW_BACKUP_ENV:-/etc/vaultwarden-backup/backup.env}"
LOG_FILE="${VW_BACKUP_LOG:-/var/log/vw-backup.log}"
QUIET=0

for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=1 ;;
        --help|-h)
            grep '^#' "$0" | head -15
            exit 0
            ;;
    esac
done

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
    [ "$QUIET" -eq 0 ] && echo "$msg"
}

die() {
    log "ERROR: $*"
    # Ping healthcheck failure endpoint if configured
    [ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS --retry 3 -m 10 "${HEALTHCHECK_URL}/fail" -d "$*" >/dev/null 2>&1 || true
    exit 1
}

# ──────────────── Load env ────────────────

[ -f "$ENV_FILE" ] || die "Env file not found at $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

# Required variables
: "${VW_DATA:?VW_DATA must be set in $ENV_FILE}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE must be set in $ENV_FILE}"
export RESTIC_PASSWORD_FILE

# ──────────────── Pre-flight ────────────────

[ -d "$VW_DATA" ] || die "Vaultwarden data dir $VW_DATA does not exist"
[ -f "$VW_DATA/db.sqlite3" ] || die "No db.sqlite3 found in $VW_DATA"
[ -f "$RESTIC_PASSWORD_FILE" ] || die "Restic password file $RESTIC_PASSWORD_FILE does not exist"

command -v restic >/dev/null || die "restic is not installed"
command -v sqlite3 >/dev/null || die "sqlite3 is not installed"

# Ping healthcheck start endpoint if configured
[ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS --retry 3 -m 10 "${HEALTHCHECK_URL}/start" >/dev/null 2>&1 || true

log "Starting Vaultwarden backup"

# ──────────────── Snapshot ────────────────

TMP=$(mktemp -d -t vw-backup-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

log "Creating SQLite snapshot"
sqlite3 "$VW_DATA/db.sqlite3" ".backup '$TMP/db.sqlite3'" \
    || die "SQLite backup failed"

log "Archiving data directory (excluding live db)"
tar --exclude='./db.sqlite3' \
    --exclude='./db.sqlite3-wal' \
    --exclude='./db.sqlite3-shm' \
    --exclude='./tmp' \
    --exclude='./icon_cache' \
    -czf "$TMP/vw-data.tar.gz" \
    -C "$VW_DATA" . \
    || die "tar failed"

SIZE=$(du -sh "$TMP" | cut -f1)
log "Snapshot prepared ($SIZE)"

# ──────────────── Retention policy ────────────────

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

# ──────────────── Backup function ────────────────

backup_to() {
    local name="$1"
    local repo="$2"
    log "→ Backing up to $name"

    if ! restic -r "$repo" backup "$TMP" \
        --tag "vaultwarden" --tag "auto" \
        --host "$(hostname)" 2>&1 | tee -a "$LOG_FILE" >/dev/null; then
        die "Backup to $name failed"
    fi

    log "→ Applying retention policy to $name (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
    if ! restic -r "$repo" forget \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --prune 2>&1 | tee -a "$LOG_FILE" >/dev/null; then
        log "WARN: forget/prune on $name failed (backup itself succeeded)"
    fi

    log "✓ $name complete"
}

# ──────────────── Run backups ────────────────

FAILED=0

# Local HDD
if [ -n "${RESTIC_REPO_LOCAL:-}" ]; then
    backup_to "local" "$RESTIC_REPO_LOCAL" || FAILED=$((FAILED+1))
else
    log "Skipping local (RESTIC_REPO_LOCAL not set)"
fi

# Backblaze B2
if [ -n "${RESTIC_REPO_B2:-}" ] && [ -n "${B2_ACCOUNT_ID:-}" ]; then
    export B2_ACCOUNT_ID B2_ACCOUNT_KEY
    backup_to "B2" "$RESTIC_REPO_B2" || FAILED=$((FAILED+1))
else
    log "Skipping B2 (RESTIC_REPO_B2 or B2_ACCOUNT_ID not set)"
fi

# Cloudflare R2
if [ -n "${RESTIC_REPO_R2:-}" ] && [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    backup_to "R2" "$RESTIC_REPO_R2" || FAILED=$((FAILED+1))
else
    log "Skipping R2 (RESTIC_REPO_R2 or AWS_ACCESS_KEY_ID not set)"
fi

# ──────────────── Finish ────────────────

if [ "$FAILED" -gt 0 ]; then
    die "$FAILED destination(s) failed"
fi

log "All backups completed successfully"

# Ping healthcheck success
[ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS --retry 3 -m 10 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true

exit 0
