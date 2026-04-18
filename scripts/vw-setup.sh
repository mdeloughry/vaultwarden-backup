#!/bin/bash
# vw-setup.sh — One-time setup: installs scripts, initializes restic repos
#
# Usage: sudo ./vw-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/vaultwarden-backup"
BIN_DIR="/usr/local/bin"

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo."
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Vaultwarden Backup — Setup                                ║"
echo "╚════════════════════════════════════════════════════════════╝"

# ──────────────── Dependencies ────────────────

echo ""
echo "[1/5] Checking dependencies..."
MISSING=()
for cmd in restic sqlite3 tar docker curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "    Missing: ${MISSING[*]}"
    read -p "Install missing packages via apt? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        apt update
        apt install -y "${MISSING[@]}"
    else
        echo "Install them manually and re-run setup."
        exit 1
    fi
else
    echo "    ✓ All dependencies present"
fi

# ──────────────── Config dir ────────────────

echo ""
echo "[2/5] Creating config directory at $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/backup.env" ]; then
    cp "$SCRIPT_DIR/../config/backup.env.example" "$CONFIG_DIR/backup.env"
    chmod 600 "$CONFIG_DIR/backup.env"
    echo "    ✓ Created $CONFIG_DIR/backup.env from example"
    echo "    → EDIT THIS FILE to set VW_DATA, credentials, and repo URLs"
else
    echo "    ✓ $CONFIG_DIR/backup.env already exists (not overwritten)"
fi

# ──────────────── Restic password ────────────────

echo ""
echo "[3/5] Setting up restic password..."
if [ ! -f "$CONFIG_DIR/restic-pw" ]; then
    echo ""
    echo "    A restic password encrypts all your backups."
    echo "    If you lose this password, your backups are UNRECOVERABLE."
    echo ""
    read -p "    Generate a random password? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        PASSWORD=$(openssl rand -base64 32)
        echo "$PASSWORD" > "$CONFIG_DIR/restic-pw"
        chmod 600 "$CONFIG_DIR/restic-pw"
        echo ""
        echo "    ✓ Generated password saved to $CONFIG_DIR/restic-pw"
        echo ""
        echo "    ⚠️  COPY THIS PASSWORD AND STORE IT OUTSIDE VAULTWARDEN NOW:"
        echo ""
        echo "        $PASSWORD"
        echo ""
        echo "    Suggested places:"
        echo "      - Your work 1Password"
        echo "      - Printed on paper in a safe"
        echo "      - Encrypted note on a USB drive"
        echo ""
        read -p "    Press Enter once you've stored it securely..."
    else
        echo "    Manually create $CONFIG_DIR/restic-pw with your password."
        echo "    Then: chmod 600 $CONFIG_DIR/restic-pw"
    fi
else
    echo "    ✓ $CONFIG_DIR/restic-pw already exists"
fi

# ──────────────── Install scripts ────────────────

echo ""
echo "[4/5] Installing scripts to $BIN_DIR..."
for script in vw-backup.sh vw-restore.sh vw-test-restore.sh; do
    cp "$SCRIPT_DIR/$script" "$BIN_DIR/$script"
    chmod 755 "$BIN_DIR/$script"
    echo "    ✓ $BIN_DIR/$script"
done

# ──────────────── Init repos ────────────────

echo ""
echo "[5/5] Initialize restic repositories?"
echo ""
echo "    This creates the repo structure at each destination."
echo "    Edit $CONFIG_DIR/backup.env first with your actual credentials,"
echo "    then run:"
echo ""
echo "        sudo $BIN_DIR/vw-backup.sh --init-repos"
echo ""
echo "    Or init them manually:"
echo "        sudo bash -c 'source $CONFIG_DIR/backup.env && \\"
echo "          RESTIC_PASSWORD_FILE=$CONFIG_DIR/restic-pw \\"
echo "          restic -r \"\$RESTIC_REPO_LOCAL\" init'"
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Setup complete                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Edit:     sudo nano $CONFIG_DIR/backup.env"
echo "  2. Init:     sudo restic -r <each-repo> init"
echo "  3. Test:     sudo vw-backup.sh"
echo "  4. Verify:   sudo vw-test-restore.sh local"
echo "  5. Schedule: sudo crontab -e"
echo "       0 3 * * * /usr/local/bin/vw-backup.sh --quiet"
echo ""
