#!/bin/bash
# vw-setup.sh — One-time setup: installs scripts, initializes restic repos
#
# Usage: sudo ./vw-setup.sh [--non-interactive]
#
# Options:
#   --non-interactive, -y    Skip all interactive prompts and use defaults

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/vaultwarden-backup"
BIN_DIR="/usr/local/bin"

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo."
    exit 1
fi

NON_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --non-interactive|-y) NON_INTERACTIVE=1 ;;
    esac
done

echo "╔════════════════════════════════════════════════════════════╗"
# shellcheck disable=SC2028
echo "║  Vaultwarden Backup — Setup                                ║"
echo "╚════════════════════════════════════════════════════════════╝"

# ──────────────── Dependencies ────────────────

echo ""
echo "[1/6] Checking dependencies..."
MISSING=()
for cmd in restic sqlite3 tar docker curl openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "    Missing: ${MISSING[*]}"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        REPLY="y"
    else
        read -p "Install missing packages via apt? [y/N] " -n 1 -r
        echo ""
    fi
    if [[ ${REPLY:-n} =~ ^[Yy]$ ]]; then
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
echo "[2/6] Creating config directory at $CONFIG_DIR..."
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
echo "[3/6] Setting up restic password..."
if [ ! -f "$CONFIG_DIR/restic-pw" ]; then
    echo ""
    echo "    A restic password encrypts all your backups."
    echo "    If you lose this password, your backups are UNRECOVERABLE."
    echo ""
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        REPLY="y"
    else
        read -p "    Generate a random password? [Y/n] " -n 1 -r
        echo ""
    fi
    if [[ ! ${REPLY:-n} =~ ^[Nn]$ ]]; then
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
        if [ "$NON_INTERACTIVE" -eq 0 ]; then
            read -p "    Press Enter once you've stored it securely..."
        fi
    else
        echo "    Manually create $CONFIG_DIR/restic-pw with your password."
        echo "    Then: chmod 600 $CONFIG_DIR/restic-pw"
    fi
else
    echo "    ✓ $CONFIG_DIR/restic-pw already exists"
fi

# ──────────────── Install scripts ────────────────

echo ""
echo "[4/6] Installing scripts to $BIN_DIR..."
for script in vw-backup.sh vw-restore.sh vw-test-restore.sh vw-check.sh vw-tui.py; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        dest_name="$script"
        if [ "$script" = "vw-tui.py" ]; then
            dest_name="vw-tui"
        fi
        cp "$SCRIPT_DIR/$script" "$BIN_DIR/$dest_name"
        chmod 755 "$BIN_DIR/$dest_name"
        echo "    ✓ $BIN_DIR/$dest_name"
    else
        echo "    ⚠ Warning: Source script $script not found in $SCRIPT_DIR"
    fi
done

# ──────────────── Systemd units ────────────────
echo ""
echo "[5/6] Creating systemd service & timer files..."

# Service for backup
cat <<EOF > /tmp/vw-backup.service
[Unit]
Description=Vaultwarden Automated Backup
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vw-backup.sh --quiet
EOF

# Timer for backup (Runs daily at 3 AM)
cat <<EOF > /tmp/vw-backup.timer
[Unit]
Description=Run Vaultwarden Backup Daily

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Service for weekly check
cat <<EOF > /tmp/vw-check.service
[Unit]
Description=Vaultwarden Restic Repository Consistency Check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vw-check.sh
EOF

# Timer for weekly check (Runs weekly on Sunday at 4 AM)
cat <<EOF > /tmp/vw-check.timer
[Unit]
Description=Run Vaultwarden Repository Consistency Check Weekly

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

if [ "$NON_INTERACTIVE" -eq 1 ]; then
    INSTALL_SYSTEMD="n" # Default to no in non-interactive unless enabled manually
else
    read -p "    Install systemd services and timers? [y/N] " -n 1 -r
    echo ""
    INSTALL_SYSTEMD="${REPLY:-n}"
fi

if [[ $INSTALL_SYSTEMD =~ ^[Yy]$ ]]; then
    mv /tmp/vw-backup.service /etc/systemd/system/vw-backup.service
    mv /tmp/vw-backup.timer /etc/systemd/system/vw-backup.timer
    mv /tmp/vw-check.service /etc/systemd/system/vw-check.service
    mv /tmp/vw-check.timer /etc/systemd/system/vw-check.timer
    systemctl daemon-reload || echo "    WARN: Could not reload systemd daemon (are you running in a container?)"
    echo "    ✓ Installed systemd services and timers."
    echo "    → To enable them, run:"
    echo "        sudo systemctl enable --now vw-backup.timer"
    echo "        sudo systemctl enable --now vw-check.timer"
else
    rm -f /tmp/vw-backup.service /tmp/vw-backup.timer /tmp/vw-check.service /tmp/vw-check.timer
    echo "    Skipped systemd installation."
fi

# ──────────────── Init repos instructions ────────────────

echo ""
echo "[6/6] Initialize restic repositories?"
echo ""
echo "    This creates the repo structure at each destination."
echo "    Edit $CONFIG_DIR/backup.env first with your actual credentials,"
# shellcheck disable=SC2028
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
# shellcheck disable=SC2028
echo "║  Setup complete                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Edit:     sudo nano $CONFIG_DIR/backup.env"
echo "  2. Init:     sudo restic -r <each-repo> init"
echo "  3. Test:     sudo vw-backup.sh"
echo "  4. Verify:   sudo vw-test-restore.sh local"
echo "  5. Schedule: Either enable systemd timers:"
echo "                 sudo systemctl enable --now vw-backup.timer"
echo "                 sudo systemctl enable --now vw-check.timer"
echo "               Or schedule nightly via cron:"
echo "                 sudo crontab -e"
echo "                 0 3 * * * /usr/local/bin/vw-backup.sh --quiet"
echo "                 0 4 * * 0 /usr/local/bin/vw-check.sh"
echo ""

