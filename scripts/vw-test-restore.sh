#!/bin/bash
# vw-test-restore.sh — Verify backups by restoring to a throwaway location
#                     and spinning up a test Vaultwarden container against it.
#
# Usage: sudo ./vw-test-restore.sh [local|b2|r2] [snapshot-id]
#        snapshot-id defaults to 'latest'
#
# What it does:
#   1. Restores the specified snapshot to /tmp/vw-restore-test
#   2. Extracts the tar.gz + SQLite db
#   3. Runs integrity checks on the SQLite db
#   4. Optionally starts a test Vaultwarden container on port 18080
#      so you can log in and verify your data
#   5. Cleans up on exit (Ctrl+C or normal finish)

set -euo pipefail

ENV_FILE="${VW_BACKUP_ENV:-/etc/vaultwarden-backup/backup.env}"
TEST_DIR="/tmp/vw-restore-test"
TEST_PORT="${TEST_PORT:-18080}"
TEST_CONTAINER="vw-restore-test"

# ──────────────── Parse args ────────────────

DEST="${1:-}"
SNAPSHOT="${2:-latest}"

if [ -z "$DEST" ]; then
    echo "Usage: $0 [local|b2|r2] [snapshot-id]"
    echo ""
    echo "Examples:"
    echo "  $0 local              # restore latest from local"
    echo "  $0 b2                 # restore latest from B2"
    echo "  $0 r2 abc123def       # restore specific snapshot from R2"
    exit 1
fi

# ──────────────── Load env ────────────────

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

export RESTIC_PASSWORD_FILE

case "$DEST" in
    local)
        REPO="${RESTIC_REPO_LOCAL:?RESTIC_REPO_LOCAL not set}"
        ;;
    b2)
        REPO="${RESTIC_REPO_B2:?RESTIC_REPO_B2 not set}"
        export B2_ACCOUNT_ID B2_ACCOUNT_KEY
        ;;
    r2)
        REPO="${RESTIC_REPO_R2:?RESTIC_REPO_R2 not set}"
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        ;;
    *)
        echo "ERROR: Unknown destination '$DEST'. Use local, b2, or r2."
        exit 1
        ;;
esac

# ──────────────── Cleanup trap ────────────────

cleanup() {
    echo ""
    echo "[cleanup] Stopping test container..."
    docker rm -f "$TEST_CONTAINER" 2>/dev/null || true
    echo "[cleanup] Removing $TEST_DIR..."
    rm -rf "$TEST_DIR"
    echo "[cleanup] Done."
}
trap cleanup EXIT INT TERM

# ──────────────── Start test ────────────────

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Vaultwarden Backup Test Restore                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo "Source:     $DEST ($REPO)"
echo "Snapshot:   $SNAPSHOT"
echo "Restore to: $TEST_DIR"
echo ""

# ──────────────── List snapshots ────────────────

echo "[1/5] Listing recent snapshots in $DEST repo..."
restic -r "$REPO" snapshots --latest 5

# ──────────────── Restore ────────────────

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

echo ""
echo "[2/5] Restoring snapshot $SNAPSHOT..."
restic -r "$REPO" restore "$SNAPSHOT" --target "$TEST_DIR" --verify

# Find the actual backup files (restic preserves paths, so they'll be nested)
TAR_FILE=$(find "$TEST_DIR" -name "vw-data.tar.gz" | head -1)
DB_FILE=$(find "$TEST_DIR" -name "db.sqlite3" | head -1)

[ -f "$TAR_FILE" ] || { echo "ERROR: vw-data.tar.gz not found in restore"; exit 1; }
[ -f "$DB_FILE" ] || { echo "ERROR: db.sqlite3 not found in restore"; exit 1; }

echo "    ✓ tar archive: $TAR_FILE"
echo "    ✓ sqlite db:   $DB_FILE"

# ──────────────── Extract + verify ────────────────

EXTRACT_DIR="$TEST_DIR/extracted"
mkdir -p "$EXTRACT_DIR"

echo ""
echo "[3/5] Extracting archive..."
tar xzf "$TAR_FILE" -C "$EXTRACT_DIR"
cp "$DB_FILE" "$EXTRACT_DIR/db.sqlite3"

echo ""
echo "[4/5] Running SQLite integrity check..."
INTEGRITY=$(sqlite3 "$EXTRACT_DIR/db.sqlite3" "PRAGMA integrity_check;")
if [ "$INTEGRITY" = "ok" ]; then
    echo "    ✓ SQLite integrity check passed"
else
    echo "    ✗ SQLite integrity check FAILED:"
    echo "$INTEGRITY"
    exit 1
fi

# Quick sanity: count users and ciphers
USER_COUNT=$(sqlite3 "$EXTRACT_DIR/db.sqlite3" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "?")
CIPHER_COUNT=$(sqlite3 "$EXTRACT_DIR/db.sqlite3" "SELECT COUNT(*) FROM ciphers;" 2>/dev/null || echo "?")
ORG_COUNT=$(sqlite3 "$EXTRACT_DIR/db.sqlite3" "SELECT COUNT(*) FROM organizations;" 2>/dev/null || echo "?")

echo "    ✓ Users:         $USER_COUNT"
echo "    ✓ Ciphers:       $CIPHER_COUNT"
echo "    ✓ Organizations: $ORG_COUNT"

# ──────────────── Optional: live test container ────────────────

echo ""
read -p "[5/5] Start a test Vaultwarden container on port $TEST_PORT to verify login? [y/N] " -n 1 -r REPLY
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Skipping live container test."
    echo "Restored data is at: $EXTRACT_DIR"
    echo "(Will be cleaned up when you exit)"
    read -p "Press Enter to clean up and exit..."
    exit 0
fi

# Stop any existing test container
docker rm -f "$TEST_CONTAINER" 2>/dev/null || true

echo ""
echo "Starting test container..."
docker run -d \
    --name "$TEST_CONTAINER" \
    -v "$EXTRACT_DIR:/data" \
    -p "$TEST_PORT:80" \
    -e DOMAIN="http://localhost:$TEST_PORT" \
    -e SIGNUPS_ALLOWED=false \
    -e WEBSOCKET_ENABLED=false \
    vaultwarden/server:latest

echo ""
echo "Waiting for container to be ready..."
for i in {1..15}; do
    if curl -sf "http://localhost:$TEST_PORT/alive" >/dev/null 2>&1; then
        echo "    ✓ Container is responding"
        break
    fi
    sleep 1
done

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Test vault ready!                                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  URL:    http://localhost:$TEST_PORT"
echo "  Login:  use your actual Vaultwarden master password"
echo ""
echo "  Verify that:"
echo "    1. You can log in"
echo "    2. Your recent items are all present"
echo "    3. TOTP codes generate correctly"
echo "    4. Shared org items appear"
echo ""
echo "  When done, press Ctrl+C here to clean up."
echo ""

# Follow the logs so they can see what's happening
docker logs -f "$TEST_CONTAINER"
