#!/bin/bash
# vw-backup.sh — Backup Vaultwarden data to local, B2, and R2 via restic
#
# Usage: sudo ./vw-backup.sh [--quiet]
#
# Requires: sqlite3, restic, tar, curl, openssl
# Env file: /etc/vaultwarden-backup/backup.env
# Restic password file: /etc/vaultwarden-backup/restic-pw

set -euo pipefail

# ──────────────── Lock (only one backup at a time) ────────────────

LOCK_FILE="${VW_BACKUP_LOCK:-/run/vw-backup.lock}"
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another backup is already running (lock: $LOCK_FILE). Exiting." >&2
    exit 1
fi

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

# ──────────────── Webhook Notifications ────────────────

send_webhook() {
    local status="$1"
    local message="$2"
    [ -n "${WEBHOOK_URL:-}" ] || return 0

    local payload=""
    local type="${WEBHOOK_TYPE:-generic}"

    if [ "$type" = "discord" ]; then
        local color=16711680 # Red
        [ "$status" = "SUCCESS" ] && color=65280 # Green
        payload=$(cat <<EOF
{
  "embeds": [{
    "title": "Vaultwarden Backup: $status",
    "description": "$(echo "$message" | sed 's/"/\\"/g')",
    "color": $color,
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
)
    elif [ "$type" = "slack" ]; then
        local emoji=":warning:"
        [ "$status" = "SUCCESS" ] && emoji=":white_check_mark:"
        payload=$(cat <<EOF
{
  "text": "$emoji *Vaultwarden Backup $status*\n$(echo "$message" | sed 's/"/\\"/g')"
}
EOF
)
    elif [ "$type" = "telegram" ]; then
        payload=$(cat <<EOF
{
  "text": "Vaultwarden Backup $status: $message"
}
EOF
)
    else
        payload=$(cat <<EOF
{
  "status": "$status",
  "message": "$message",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    fi

    curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

die() {
    log "ERROR: $*"
    send_webhook "FAILURE" "$*"
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

# ──────────────── Snapshot & Sense Checks ────────────────

TMP=$(mktemp -d -t vw-backup-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

log "Creating SQLite snapshot"
sqlite3 "$VW_DATA/db.sqlite3" ".backup '$TMP/db.sqlite3'" \
    || die "SQLite backup failed"

# Sense check 1: File existence and minimum size check (expecting > 10KB)
[ -f "$TMP/db.sqlite3" ] || die "SQLite snapshot file was not created"
DB_SIZE=$(stat -c%s "$TMP/db.sqlite3" 2>/dev/null || echo 0)
if [ "$DB_SIZE" -lt 10240 ]; then
    die "SQLite snapshot database size is too small ($DB_SIZE bytes). Expecting at least 10KB."
fi

# Sense check 2: PRAGMA integrity_check verification
log "Verifying SQLite snapshot database integrity"
INTEGRITY=$(sqlite3 "$TMP/db.sqlite3" "PRAGMA integrity_check;" 2>/dev/null || echo "failed")
if [ "$INTEGRITY" != "ok" ]; then
    die "SQLite snapshot database integrity check failed: $INTEGRITY"
fi

# Sense check 3: User record sanity check (suspect wiped DB if 0 users)
log "Verifying database user records count"
USER_COUNT=$(sqlite3 "$TMP/db.sqlite3" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "-1")
if [ "$USER_COUNT" -eq -1 ]; then
    die "Could not query users table in SQLite snapshot"
elif [ "$USER_COUNT" -eq 0 ]; then
    die "Sanity check failed: User count in database snapshot is 0. Wiped database suspected."
fi
log "    ✓ User count: $USER_COUNT"

log "Archiving data directory (excluding live db)"
tar --exclude='./db.sqlite3' \
    --exclude='./db.sqlite3-wal' \
    --exclude='./db.sqlite3-shm' \
    --exclude='./tmp' \
    --exclude='./icon_cache' \
    -czf "$TMP/vw-data.tar.gz" \
    -C "$VW_DATA" . \
    || die "tar failed"

# Sense check 4: Verify archive file size and validity
[ -f "$TMP/vw-data.tar.gz" ] || die "Data archive was not created"
TAR_SIZE=$(stat -c%s "$TMP/vw-data.tar.gz" 2>/dev/null || echo 0)
if [ "$TAR_SIZE" -lt 10240 ]; then
    die "Data archive size is too small ($TAR_SIZE bytes). Expecting at least 10KB."
fi

log "Verifying archive compression structure"
if ! tar -tzf "$TMP/vw-data.tar.gz" >/dev/null 2>&1; then
    die "Data archive validation failed: not a valid gzip file or corrupt."
fi

SIZE=$(du -sh "$TMP" | cut -f1)
log "Snapshot prepared and verified successfully ($SIZE)"

# ──────────────── Retention policy ────────────────

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

# ──────────────── Backup function ────────────────

backup_to() {
    local name="$1"
    local repo="$2"
    log "→ Backing up to $name"

    local compression_args=()
    if [ -n "${RESTIC_COMPRESSION:-}" ]; then
        compression_args=(--compression "$RESTIC_COMPRESSION")
    fi

    if [ "$QUIET" -eq 1 ]; then
        if ! restic -r "$repo" "${compression_args[@]}" backup "$TMP" \
            --tag "vaultwarden" --tag "auto" \
            --host "$(hostname)" >> "$LOG_FILE" 2>&1; then
            log "ERROR: Backup to $name failed"
            return 1
        fi
    else
        if ! restic -r "$repo" "${compression_args[@]}" backup "$TMP" \
            --tag "vaultwarden" --tag "auto" \
            --host "$(hostname)" 2>&1 | tee -a "$LOG_FILE"; then
            log "ERROR: Backup to $name failed"
            return 1
        fi
    fi

    log "→ Applying retention policy to $name (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
    if [ "$QUIET" -eq 1 ]; then
        if ! restic -r "$repo" forget \
            --keep-daily "$KEEP_DAILY" \
            --keep-weekly "$KEEP_WEEKLY" \
            --keep-monthly "$KEEP_MONTHLY" \
            --prune >> "$LOG_FILE" 2>&1; then
            log "WARN: forget/prune on $name failed (backup itself succeeded)"
        fi
    else
        if ! restic -r "$repo" forget \
            --keep-daily "$KEEP_DAILY" \
            --keep-weekly "$KEEP_WEEKLY" \
            --keep-monthly "$KEEP_MONTHLY" \
            --prune 2>&1 | tee -a "$LOG_FILE"; then
            log "WARN: forget/prune on $name failed (backup itself succeeded)"
        fi
    fi

    log "✓ $name complete"
    return 0
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
send_webhook "SUCCESS" "All backups completed successfully on $(hostname)"

# Ping healthcheck success
[ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS --retry 3 -m 10 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true

exit 0

