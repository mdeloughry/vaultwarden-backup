#!/bin/bash
# vw-restore.sh — PRODUCTION restore of Vaultwarden from a backup.
#
# ⚠️  WARNING: This OVERWRITES your live Vaultwarden data directory.
#              Use vw-test-restore.sh first to verify the backup is good.
#
# Usage: sudo ./vw-restore.sh [local|b2|r2] [snapshot-id]
#        snapshot-id defaults to 'latest'

set -euo pipefail

ENV_FILE="${VW_BACKUP_ENV:-/etc/vaultwarden-backup/backup.env}"

# ──────────────── Parse args ────────────────

DEST="${1:-}"
SNAPSHOT="${2:-latest}"

if [ -z "$DEST" ]; then
    cat <<EOF
Usage: $0 [local|b2|r2] [snapshot-id]

⚠️  This will REPLACE your live Vaultwarden data.
   The current data will be backed up to \$VW_DATA.pre-restore-TIMESTAMP first.

Examples:
  $0 local              # restore latest from local
  $0 b2 abc123def       # restore specific snapshot from B2
EOF
    exit 1
fi

# ──────────────── Load env ────────────────

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${VW_DATA:?VW_DATA must be set in env}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE must be set in env}"
export RESTIC_PASSWORD_FILE

case "$DEST" in
    local) REPO="${RESTIC_REPO_LOCAL:?}" ;;
    b2)    REPO="${RESTIC_REPO_B2:?}"; export B2_ACCOUNT_ID B2_ACCOUNT_KEY ;;
    r2)    REPO="${RESTIC_REPO_R2:?}"; export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY ;;
    *)     echo "ERROR: Unknown destination '$DEST'"; exit 1 ;;
esac

# ──────────────── Confirm ────────────────

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ⚠️   PRODUCTION RESTORE — this will overwrite live data  ⚠️  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Source:          $DEST ($REPO)"
echo "Snapshot:        $SNAPSHOT"
echo "Will overwrite:  $VW_DATA"
echo ""

echo "Recent snapshots in $DEST:"
if restic -r "$REPO" snapshots --latest 5 2>/dev/null; then
    :
else
    restic -r "$REPO" snapshots
fi
echo ""

read -p "Type 'RESTORE' to proceed: " CONFIRM
if [ "$CONFIRM" != "RESTORE" ]; then
    echo "Cancelled."
    exit 0
fi

# ──────────────── Find Vaultwarden container ────────────────

# Try common CasaOS/docker container names
CONTAINER=""
for name in vaultwarden bigbearcasaos-vaultwarden casaos-vaultwarden; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        CONTAINER="$name"
        break
    fi
done

if [ -z "$CONTAINER" ]; then
    echo "WARN: Could not auto-detect Vaultwarden container name."
    read -p "Enter container name (or leave blank to skip stop/start): " CONTAINER
fi

# ──────────────── Stop Vaultwarden ────────────────

if [ -n "$CONTAINER" ]; then
    echo ""
    echo "[1/5] Stopping Vaultwarden container ($CONTAINER)..."
    docker stop "$CONTAINER" || echo "    (container was not running)"
fi

# ──────────────── Back up existing data ────────────────

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="${VW_DATA}.pre-restore-${TIMESTAMP}"

if [ -d "$VW_DATA" ] && [ "$(ls -A "$VW_DATA" 2>/dev/null)" ]; then
    echo ""
    echo "[2/5] Moving existing data to $BACKUP_PATH..."
    mv "$VW_DATA" "$BACKUP_PATH"
    mkdir -p "$VW_DATA"
else
    echo ""
    echo "[2/5] No existing data to preserve."
    mkdir -p "$VW_DATA"
fi

# ──────────────── Restore from restic ────────────────

RESTORE_STAGING="/tmp/vw-restore-staging-$$"
mkdir -p "$RESTORE_STAGING"

echo ""
echo "[3/5] Restoring snapshot $SNAPSHOT from $DEST..."
restic -r "$REPO" restore "$SNAPSHOT" --target "$RESTORE_STAGING" --verify

TAR_FILE=$(find "$RESTORE_STAGING" -name "vw-data.tar.gz" | head -1)
DB_FILE=$(find "$RESTORE_STAGING" -name "db.sqlite3" | head -1)

if [ ! -f "$TAR_FILE" ] || [ ! -f "$DB_FILE" ]; then
    echo "ERROR: Restore did not produce expected files."
    echo "Your original data is still safe at $BACKUP_PATH"
    rm -rf "$RESTORE_STAGING"
    exit 1
fi

# ──────────────── Extract to live location ────────────────

echo ""
echo "[4/5] Extracting data to $VW_DATA..."
tar xzf "$TAR_FILE" -C "$VW_DATA"
cp "$DB_FILE" "$VW_DATA/db.sqlite3"

# Fix ownership — Vaultwarden typically runs as UID 1000 in the container
if [ -n "${VW_UID:-}" ] && [ -n "${VW_GID:-}" ]; then
    chown -R "$VW_UID:$VW_GID" "$VW_DATA"
    echo "    Set ownership to $VW_UID:$VW_GID"
fi

rm -rf "$RESTORE_STAGING"

# Verify
sqlite3 "$VW_DATA/db.sqlite3" "PRAGMA integrity_check;" | head -1
echo "    ✓ SQLite integrity check passed"

# ──────────────── Restart ────────────────

if [ -n "$CONTAINER" ]; then
    echo ""
    echo "[5/5] Starting Vaultwarden container..."
    docker start "$CONTAINER"

    echo ""
    echo "Waiting for container to respond..."
    sleep 3

    # Check health
    for i in {1..15}; do
        STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
        if [ "$STATUS" = "running" ]; then
            echo "    ✓ Container is running"
            break
        fi
        sleep 1
    done
fi

# ──────────────── Done ────────────────

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✓ Restore complete                                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Previous data preserved at: $BACKUP_PATH"
echo "  Delete it once you've verified the restore:"
echo "    sudo rm -rf '$BACKUP_PATH'"
echo ""
echo "  Test login via web vault before deleting the backup!"
