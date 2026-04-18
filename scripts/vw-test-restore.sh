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
TEST_HTTPS_PORT="${TEST_HTTPS_PORT:-18443}"
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
    echo "[cleanup] Stopping test containers..."
    docker rm -f "$TEST_CONTAINER" "${TEST_CONTAINER}-caddy" 2>/dev/null || true
    echo "[cleanup] Removing test network..."
    docker network rm vw-test-net 2>/dev/null || true
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
# Use --latest N if supported (restic 0.17+), fall back to plain snapshots
if restic -r "$REPO" snapshots --latest 5 2>/dev/null; then
    :
else
    restic -r "$REPO" snapshots
fi

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
echo "[5/5] Start a test Vaultwarden container to verify login?"
echo "      This spins up a disposable Vaultwarden on port $TEST_PORT (HTTP)"
echo "      and optionally a Caddy reverse proxy on port $TEST_HTTPS_PORT (HTTPS)"
echo "      with a self-signed certificate so you can test mobile/desktop apps."
echo ""
read -p "      Continue? [y/N] " -n 1 -r REPLY
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Skipping live container test."
    echo "Restored data is at: $EXTRACT_DIR"
    echo "(Will be cleaned up when you exit)"
    read -p "Press Enter to clean up and exit..."
    exit 0
fi

read -p "      Also start HTTPS proxy with self-signed cert? [Y/n] " -n 1 -r HTTPS_REPLY
echo ""
USE_HTTPS=1
[[ $HTTPS_REPLY =~ ^[Nn]$ ]] && USE_HTTPS=0

# Determine host IP for mobile device testing
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
# Prefer Tailscale IP if available (reachable from phone over tailnet)
if command -v tailscale >/dev/null 2>&1; then
    TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
    [ -n "$TS_IP" ] && HOST_IP="$TS_IP"
fi
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# Stop any existing test containers
docker rm -f "$TEST_CONTAINER" "${TEST_CONTAINER}-caddy" 2>/dev/null || true

# Determine the DOMAIN Vaultwarden should report
if [ "$USE_HTTPS" -eq 1 ]; then
    VW_DOMAIN="https://$HOST_IP:$TEST_HTTPS_PORT"
else
    VW_DOMAIN="http://$HOST_IP:$TEST_PORT"
fi

echo ""
echo "Starting test Vaultwarden container..."
docker run -d \
    --name "$TEST_CONTAINER" \
    -v "$EXTRACT_DIR:/data" \
    -p "$TEST_PORT:80" \
    -e DOMAIN="$VW_DOMAIN" \
    -e SIGNUPS_ALLOWED=false \
    -e WEBSOCKET_ENABLED=true \
    vaultwarden/server:latest >/dev/null

echo "Waiting for Vaultwarden to respond..."
for i in {1..20}; do
    if curl -sf "http://localhost:$TEST_PORT/alive" >/dev/null 2>&1; then
        echo "    ✓ Vaultwarden is responding"
        break
    fi
    sleep 1
done

# ──────────────── Self-signed HTTPS via Caddy ────────────────

if [ "$USE_HTTPS" -eq 1 ]; then
    CADDY_DIR="$TEST_DIR/caddy"
    mkdir -p "$CADDY_DIR/certs"

    echo ""
    echo "Generating self-signed certificate for $HOST_IP..."

    # Build SAN config: include the host IP, localhost, and hostname
    cat > "$CADDY_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $HOST_IP

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = $(hostname)
IP.1 = 127.0.0.1
IP.2 = $HOST_IP
EOF

    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$CADDY_DIR/certs/test.key" \
        -out "$CADDY_DIR/certs/test.crt" \
        -days 7 \
        -config "$CADDY_DIR/openssl.cnf" \
        -extensions v3_req 2>/dev/null

    chmod 644 "$CADDY_DIR/certs/test.crt" "$CADDY_DIR/certs/test.key"

    # Caddyfile with manual TLS and reverse proxy
    cat > "$CADDY_DIR/Caddyfile" <<EOF
{
    auto_https off
    admin off
}

:443 {
    tls /certs/test.crt /certs/test.key
    reverse_proxy vaultwarden-upstream:80
}
EOF

    echo "Starting Caddy HTTPS proxy..."
    # Create a small network so Caddy can reach Vaultwarden by name
    NET_NAME="vw-test-net"
    docker network create "$NET_NAME" 2>/dev/null || true
    docker network connect --alias vaultwarden-upstream "$NET_NAME" "$TEST_CONTAINER" 2>/dev/null || true

    docker run -d \
        --name "${TEST_CONTAINER}-caddy" \
        --network "$NET_NAME" \
        -v "$CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "$CADDY_DIR/certs:/certs:ro" \
        -p "$TEST_HTTPS_PORT:443" \
        caddy:latest >/dev/null

    echo "Waiting for HTTPS proxy to respond..."
    for i in {1..15}; do
        if curl -ksf "https://localhost:$TEST_HTTPS_PORT/alive" >/dev/null 2>&1; then
            echo "    ✓ HTTPS proxy is responding"
            break
        fi
        sleep 1
    done

    CERT_FINGERPRINT=$(openssl x509 -in "$CADDY_DIR/certs/test.crt" -noout -fingerprint -sha256 | cut -d= -f2)
fi

# ──────────────── Summary + wait ────────────────

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Test vault ready                                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Web vault (HTTP,  browser on this machine):"
echo "    http://localhost:$TEST_PORT"
echo ""

if [ "$USE_HTTPS" -eq 1 ]; then
    echo "  Web vault (HTTPS, self-signed):"
    echo "    https://$HOST_IP:$TEST_HTTPS_PORT"
    echo "    https://localhost:$TEST_HTTPS_PORT"
    echo ""
    echo "  Certificate fingerprint (SHA256):"
    echo "    $CERT_FINGERPRINT"
    echo ""
    echo "  To test with Bitwarden mobile/desktop apps:"
    echo "    1. Browser will warn about self-signed cert — click through"
    echo "       (Safari/Chrome: Advanced → Proceed anyway)"
    echo "    2. Mobile apps may refuse self-signed certs entirely — in that"
    echo "       case install the cert on the device first, or just test via"
    echo "       a browser instead."
    echo "    3. Point app at: https://$HOST_IP:$TEST_HTTPS_PORT"
    echo ""
    echo "  Cert + Caddyfile are at: $CADDY_DIR"
fi

echo "  Login: your actual Vaultwarden master password"
echo ""
echo "  Verify:"
echo "    • You can log in"
echo "    • Recent items are present"
echo "    • TOTP codes generate"
echo "    • Shared org items appear"
echo ""
echo "  Press Ctrl+C to clean up and exit."
echo ""
echo "─── Vaultwarden logs ─────────────────────────────────────────"

docker logs -f "$TEST_CONTAINER"
