#!/bin/bash
# vw-check.sh — Run weekly integrity checks on Vaultwarden restic repositories
#
# Usage: sudo ./vw-check.sh
#
# Requires: restic, curl
# Env file: /etc/vaultwarden-backup/backup.env
# Restic password file: /etc/vaultwarden-backup/restic-pw

set -euo pipefail

# ──────────────── Lock (only one check/backup at a time) ────────────────

LOCK_FILE="${VW_CHECK_LOCK:-/run/vw-backup.lock}"
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another backup or check is already running (lock: $LOCK_FILE). Exiting." >&2
    exit 1
fi

# ──────────────── Config ────────────────

ENV_FILE="${VW_BACKUP_ENV:-/etc/vaultwarden-backup/backup.env}"
LOG_FILE="${VW_CHECK_LOG:-/var/log/vw-check.log}"

# Ensure log file exists and is writable
touch "$LOG_FILE" 2>/dev/null || true

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
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
    "title": "Vaultwarden Backup Check: $status",
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
  "text": "$emoji *Vaultwarden Backup Check $status*\n$(echo "$message" | sed 's/"/\\"/g')"
}
EOF
)
    elif [ "$type" = "telegram" ]; then
        payload=$(cat <<EOF
{
  "text": "Vaultwarden Backup Check $status: $message"
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
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE must be set in $ENV_FILE}"
export RESTIC_PASSWORD_FILE

# ──────────────── Pre-flight ────────────────

[ -f "$RESTIC_PASSWORD_FILE" ] || die "Restic password file $RESTIC_PASSWORD_FILE does not exist"
command -v restic >/dev/null || die "restic is not installed"

# Ping healthcheck start endpoint if configured
[ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS --retry 3 -m 10 "${HEALTHCHECK_URL}/start" >/dev/null 2>&1 || true

log "Starting Vaultwarden backup repository integrity checks"

# ──────────────── Check function ────────────────

check_repo() {
    local name="$1"
    local repo="$2"
    log "→ Checking repository: $name ($repo)"

    local check_args=()
    if [ -n "${CHECK_READ_SUBSET:-}" ]; then
        check_args+=(--read-data-subset="$CHECK_READ_SUBSET")
        log "  (including data verification subset: $CHECK_READ_SUBSET)"
    fi

    # Run check, output to console and log file
    if ! restic -r "$repo" check "${check_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "ERROR: Consistency check failed for $name"
        return 1
    fi

    log "✓ $name check passed"
    return 0
}

# ──────────────── Run Checks ────────────────

FAILED=0
CHECKED=0

# Local HDD
if [ -n "${RESTIC_REPO_LOCAL:-}" ]; then
    check_repo "local" "$RESTIC_REPO_LOCAL" || FAILED=$((FAILED+1))
    CHECKED=$((CHECKED+1))
else
    log "Skipping local (RESTIC_REPO_LOCAL not set)"
fi

# Backblaze B2
if [ -n "${RESTIC_REPO_B2:-}" ] && [ -n "${B2_ACCOUNT_ID:-}" ]; then
    export B2_ACCOUNT_ID B2_ACCOUNT_KEY
    check_repo "B2" "$RESTIC_REPO_B2" || FAILED=$((FAILED+1))
    CHECKED=$((CHECKED+1))
else
    log "Skipping B2 (RESTIC_REPO_B2 or B2_ACCOUNT_ID not set)"
fi

# Cloudflare R2
if [ -n "${RESTIC_REPO_R2:-}" ] && [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    check_repo "R2" "$RESTIC_REPO_R2" || FAILED=$((FAILED+1))
    CHECKED=$((CHECKED+1))
else
    log "Skipping R2 (RESTIC_REPO_R2 or AWS_ACCESS_KEY_ID not set)"
fi

# ──────────────── Finish ────────────────

if [ "$CHECKED" -eq 0 ]; then
    die "No active repositories configured to check"
fi

if [ "$FAILED" -gt 0 ]; then
    die "$FAILED repository check(s) failed"
fi

log "All repository integrity checks completed successfully"
send_webhook "SUCCESS" "All configured Restic repositories checked and verified healthy on $(hostname)"

# Ping healthcheck success
[ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS --retry 3 -m 10 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true

exit 0
