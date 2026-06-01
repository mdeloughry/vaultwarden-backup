#!/bin/bash
# test_suite.sh — Hermetic unit testing for Vaultwarden backup script suite.
set -euo pipefail

export TEST_ROOT="/home/matt/projects/vaultwarden-backup/scratch/test_env"
export TMPDIR="$TEST_ROOT"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/etc" "$TEST_ROOT/data" "$TEST_ROOT/repo_local" "$TEST_ROOT/log"

# Define mock logs
export MOCK_RESTIC_LOG="$TEST_ROOT/log/mock_restic.log"
export MOCK_CURL_LOG="$TEST_ROOT/log/mock_curl.log"
export MOCK_DOCKER_LOG="$TEST_ROOT/log/mock_docker.log"
touch "$MOCK_RESTIC_LOG" "$MOCK_CURL_LOG" "$MOCK_DOCKER_LOG"

# Create mock restic binary
cat > "$TEST_ROOT/bin/restic" <<'EOF'
#!/bin/bash
echo "MOCK RESTIC: $*" >> "$MOCK_RESTIC_LOG"

REPO=""
TARGET_DIR=""
CMD=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -r)
            REPO="$2"
            shift 2
            ;;
        --target)
            TARGET_DIR="$2"
            shift 2
            ;;
        --password-file|--tag|--host|--compression|--read-data-subset|--latest|--keep-daily|--keep-weekly|--keep-monthly)
            shift 2
            ;;
        -*)
            shift
            ;;
        init|backup|forget|snapshots|check|restore|prune)
            CMD="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

case "$CMD" in
    init)
        echo "Mock init success"
        exit 0
        ;;
    backup)
        if [ "${MOCK_RESTIC_FAIL_BACKUP:-0}" -eq 1 ]; then
            echo "Mock backup error" >&2
            exit 1
        fi
        echo "Mock backup success"
        exit 0
        ;;
    forget)
        echo "Mock forget success"
        exit 0
        ;;
    snapshots)
        echo "Mock snapshots list:"
        echo 'ID        Time                 Host        Tags        Paths'
        echo '----------------------------------------------------------------------'
        echo 'abc123def  2026-05-22 10:00:00  test-host   vaultwarden /tmp/vw-backup'
        exit 0
        ;;
    check)
        if [ "${MOCK_RESTIC_FAIL_CHECK:-0}" -eq 1 ]; then
            echo "Mock check error: integrity compromised" >&2
            exit 1
        fi
        echo "Mock check success"
        exit 0
        ;;
    restore)
        if [ -n "$TARGET_DIR" ]; then
            mkdir -p "$TARGET_DIR"
            cp "$MOCK_RESTORE_SOURCE_DB" "$TARGET_DIR/db.sqlite3"
            cp "$MOCK_RESTORE_SOURCE_TAR" "$TARGET_DIR/vw-data.tar.gz"
            echo "Mock restore success to $TARGET_DIR"
            exit 0
        else
            echo "Error: --target not specified" >&2
            exit 1
        fi
        ;;
    *)
        echo "Unknown restic command: $CMD" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/restic"

# Create mock curl binary
cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/bash
echo "MOCK CURL CALLED WITH: $*" >> "$MOCK_CURL_LOG"
# Write stdin to log
if [ -t 0 ]; then
    :
else
    cat >> "$MOCK_CURL_LOG"
    echo "" >> "$MOCK_CURL_LOG"
fi
exit 0
EOF
chmod +x "$TEST_ROOT/bin/curl"

# Create mock docker binary
cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/bin/bash
echo "MOCK DOCKER: $*" >> "$MOCK_DOCKER_LOG"
if [ "$1" = "inspect" ]; then
    echo "running"
fi
if [ "$1" = "logs" ] && [ "$2" = "-f" ]; then
    cp "$TEST_ROOT"/vw-restore-*/caddy/openssl.cnf "$TEST_ROOT/openssl.cnf" 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$TEST_ROOT/bin/docker"

# Create mock database
create_healthy_db() {
    rm -f "$TEST_ROOT/data/db.sqlite3"
    sqlite3 "$TEST_ROOT/data/db.sqlite3" "CREATE TABLE users (id INTEGER PRIMARY KEY); INSERT INTO users VALUES (1);"
    sqlite3 "$TEST_ROOT/data/db.sqlite3" "CREATE TABLE ciphers (id INTEGER PRIMARY KEY);"
    sqlite3 "$TEST_ROOT/data/db.sqlite3" "CREATE TABLE organizations (id INTEGER PRIMARY KEY);"
    sqlite3 "$TEST_ROOT/data/db.sqlite3" "CREATE TABLE dummy (val TEXT); INSERT INTO dummy VALUES (hex(randomblob(8000)));"
}
create_healthy_db

# Create other data files for tar archive
echo "hello world" > "$TEST_ROOT/data/config.json"
dd if=/dev/urandom of="$TEST_ROOT/data/dummy.bin" bs=1024 count=15 >/dev/null 2>&1
tar -czf "$TEST_ROOT/data/vw-data.tar.gz" -C "$TEST_ROOT/data" config.json dummy.bin

# Copy restore sources to a separate folder so they are unaffected by cleanups
mkdir -p "$TEST_ROOT/data_backup"
cp "$TEST_ROOT/data/db.sqlite3" "$TEST_ROOT/data_backup/db.sqlite3"
cp "$TEST_ROOT/data/vw-data.tar.gz" "$TEST_ROOT/data_backup/vw-data.tar.gz"
export MOCK_RESTORE_SOURCE_DB="$TEST_ROOT/data_backup/db.sqlite3"
export MOCK_RESTORE_SOURCE_TAR="$TEST_ROOT/data_backup/vw-data.tar.gz"

# Create restic password file
echo "supersecret" > "$TEST_ROOT/etc/restic-pw"

# Create backup.env file
cat > "$TEST_ROOT/etc/backup.env" <<EOF
export VW_DATA="$TEST_ROOT/data"
export RESTIC_PASSWORD_FILE="$TEST_ROOT/etc/restic-pw"
export RESTIC_REPO_LOCAL="$TEST_ROOT/repo_local"
export RESTIC_REPO_B2="b2:mybucket"
export RESTIC_REPO_R2="r2:mybucket"
export B2_ACCOUNT_ID="b2-id"
export B2_ACCOUNT_KEY="b2-key"
export AWS_ACCESS_KEY_ID="r2-id"
export AWS_SECRET_ACCESS_KEY="r2-key"
export RESTIC_COMPRESSION="max"
export WEBHOOK_URL="http://localhost:9999/webhook"
export WEBHOOK_TYPE="generic"
export KEEP_DAILY=7
export KEEP_WEEKLY=4
export KEEP_MONTHLY=12
EOF

export VW_BACKUP_ENV="$TEST_ROOT/etc/backup.env"
export VW_BACKUP_LOCK="$TEST_ROOT/etc/vw-backup.lock"
export VW_CHECK_LOCK="$TEST_ROOT/etc/vw-backup.lock"
export VW_BACKUP_LOG="$TEST_ROOT/log/vw-backup.log"
export VW_CHECK_LOG="$TEST_ROOT/log/vw-check.log"
export PATH="$TEST_ROOT/bin:$PATH"

# Setup testing utility functions
assert_contains() {
    local file="$1"
    local term="$2"
    if grep -q -- "$term" "$file"; then
        echo "  [PASS] Found '$term' in $file"
    else
        echo "  [FAIL] Expected '$term' in $file, but not found"
        exit 1
    fi
}

assert_not_contains() {
    local file="$1"
    local term="$2"
    if ! grep -q -- "$term" "$file"; then
        echo "  [PASS] Did not find '$term' in $file"
    else
        echo "  [FAIL] Did not expect '$term' in $file, but found"
        exit 1
    fi
}

echo "──────────────────────────────────────────────"
echo "Running Test 1: Successful Backup"
echo "──────────────────────────────────────────────"
create_healthy_db
truncate -s 0 "$MOCK_RESTIC_LOG" "$MOCK_CURL_LOG" "$VW_BACKUP_LOG"

./scripts/vw-backup.sh
assert_contains "$VW_BACKUP_LOG" "Creating SQLite snapshot"
assert_contains "$VW_BACKUP_LOG" "Snapshot prepared and verified successfully"
assert_contains "$VW_BACKUP_LOG" "→ Backing up to local"
assert_contains "$VW_BACKUP_LOG" "✓ local complete"
assert_contains "$VW_BACKUP_LOG" "✓ B2 complete"
assert_contains "$VW_BACKUP_LOG" "✓ R2 complete"
assert_contains "$MOCK_RESTIC_LOG" "--compression max backup"
assert_contains "$MOCK_CURL_LOG" '"status": "SUCCESS"'

echo "──────────────────────────────────────────────"
echo "Running Test 2: Backup Sense Check - 0 Users"
echo "──────────────────────────────────────────────"
sqlite3 "$TEST_ROOT/data/db.sqlite3" "DELETE FROM users;"
truncate -s 0 "$MOCK_CURL_LOG" "$VW_BACKUP_LOG"

if ./scripts/vw-backup.sh; then
    echo "  [FAIL] Expected backup to fail due to 0 users check"
    exit 1
else
    echo "  [PASS] Backup failed as expected"
fi
assert_contains "$VW_BACKUP_LOG" "User count in database snapshot is 0"
assert_contains "$MOCK_CURL_LOG" '"status": "FAILURE"'
assert_contains "$MOCK_CURL_LOG" "User count in database snapshot is 0"

echo "──────────────────────────────────────────────"
echo "Running Test 3: Backup Sense Check - SQL Corrupt"
echo "──────────────────────────────────────────────"
create_healthy_db
echo "garbage" > "$TEST_ROOT/data/db.sqlite3"
truncate -s 0 "$MOCK_CURL_LOG" "$VW_BACKUP_LOG"

if ./scripts/vw-backup.sh; then
    echo "  [FAIL] Expected backup to fail due to corrupt SQLite file"
    exit 1
else
    echo "  [PASS] Backup failed as expected"
fi
assert_contains "$VW_BACKUP_LOG" "SQLite backup failed"

echo "──────────────────────────────────────────────"
echo "Running Test 4: Multi-Destination Resiliency"
echo "──────────────────────────────────────────────"
create_healthy_db
truncate -s 0 "$MOCK_RESTIC_LOG" "$MOCK_CURL_LOG" "$VW_BACKUP_LOG"
export MOCK_RESTIC_FAIL_BACKUP=1

if ./scripts/vw-backup.sh; then
    echo "  [FAIL] Expected backup to return non-zero exit code due to failures"
    exit 1
else
    echo "  [PASS] Backup returned error exit code as expected"
fi
assert_contains "$VW_BACKUP_LOG" "ERROR: Backup to local failed"
assert_contains "$VW_BACKUP_LOG" "ERROR: Backup to B2 failed"
assert_contains "$VW_BACKUP_LOG" "ERROR: Backup to R2 failed"
assert_contains "$MOCK_CURL_LOG" '"status": "FAILURE"'
assert_contains "$MOCK_CURL_LOG" "3 destination(s) failed"
unset MOCK_RESTIC_FAIL_BACKUP

echo "──────────────────────────────────────────────"
echo "Running Test 5: Weekly Repository Checks"
echo "──────────────────────────────────────────────"
truncate -s 0 "$MOCK_RESTIC_LOG" "$MOCK_CURL_LOG"
./scripts/vw-check.sh
assert_contains "$MOCK_RESTIC_LOG" "repo_local"
assert_contains "$MOCK_RESTIC_LOG" "b2:mybucket"

# Test weekly check failure webhooks
export MOCK_RESTIC_FAIL_CHECK=1
truncate -s 0 "$MOCK_CURL_LOG"
if ./scripts/vw-check.sh; then
    echo "  [FAIL] Expected vw-check.sh to exit with error when restic check fails"
    exit 1
else
    echo "  [PASS] vw-check.sh failed as expected"
fi
assert_contains "$MOCK_CURL_LOG" "repository check(s) failed"
unset MOCK_RESTIC_FAIL_CHECK

echo "──────────────────────────────────────────────"
echo "Running Test 6: Production Restore (vw-restore.sh)"
echo "──────────────────────────────────────────────"
# Create original target folder and assign fake permissions
RESTORE_TARGET="$TEST_ROOT/restored_data"
rm -rf "$RESTORE_TARGET"
mkdir -p "$RESTORE_TARGET"
touch "$RESTORE_TARGET/dummy"

# Verify fallback ownership detection
# Modify env to use RESTORE_TARGET
sed -i 's|export VW_DATA=.*|export VW_DATA="'"$RESTORE_TARGET"'"|' "$TEST_ROOT/etc/backup.env"
# Unset VW_UID and VW_GID to test fallback detection
sed -i '/export VW_UID/d' "$TEST_ROOT/etc/backup.env"
sed -i '/export VW_GID/d' "$TEST_ROOT/etc/backup.env"

# Perform restore
echo -e "RESTORE\n" | ./scripts/vw-restore.sh local latest

# Verify files are restored
[ -f "$RESTORE_TARGET/db.sqlite3" ] || { echo "  [FAIL] db.sqlite3 not restored"; exit 1; }
[ -f "$RESTORE_TARGET/config.json" ] || { echo "  [FAIL] config.json not restored"; exit 1; }
echo "  [PASS] Files successfully restored to live directory"

# Verify error handling recovery paths on extraction failure
# Let's corrupt the tar file copy source
echo "bad" > "$MOCK_RESTORE_SOURCE_TAR"
if echo -e "RESTORE\n" | ./scripts/vw-restore.sh local latest; then
    echo "  [FAIL] Expected restore to fail on corrupt tar file"
    exit 1
else
    echo "  [PASS] Restore failed correctly"
fi

# Reset target and DB source
create_healthy_db
cp "$TEST_ROOT/data/db.sqlite3" "$MOCK_RESTORE_SOURCE_DB"
tar -czf "$MOCK_RESTORE_SOURCE_TAR" -C "$TEST_ROOT/data" config.json dummy.bin

echo "──────────────────────────────────────────────"
echo "Running Test 7: Test Restore SAN IP parsing (vw-test-restore.sh)"
echo "──────────────────────────────────────────────"
# Run vw-test-restore.sh and feed 'y\n' (to trigger live container and config generation)
# Since we want to test alt_names certificate config, we check that it generates valid alt_names
export HOST_IP="192.168.1.50"
rm -f "$TEST_ROOT/openssl.cnf"
echo -e "y\n" | ./scripts/vw-test-restore.sh local latest || true

# Check the alt_names in openssl.cnf generated inside the hermetic test root
if [ -f "$TEST_ROOT/openssl.cnf" ]; then
    assert_contains "$TEST_ROOT/openssl.cnf" "IP.2 = 192.168.1.50"
else
    echo "  [FAIL] openssl.cnf not found in test restore directory"
    exit 1
fi

# Test invalid HOST_IP fallback
export HOST_IP="invalid_host"
rm -f "$TEST_ROOT/openssl.cnf"
echo -e "y\n" | ./scripts/vw-test-restore.sh local latest || true
if [ -f "$TEST_ROOT/openssl.cnf" ]; then
    assert_contains "$TEST_ROOT/openssl.cnf" "DNS.3 = invalid_host"
    assert_not_contains "$TEST_ROOT/openssl.cnf" "IP.2 ="
else
    echo "  [FAIL] openssl.cnf not found in test restore directory for fallback check"
    exit 1
fi

echo "──────────────────────────────────────────────"
echo "ALL TESTS PASSED SUCCESSFULLY!"
echo "──────────────────────────────────────────────"
