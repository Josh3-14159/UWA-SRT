#!/bin/bash
# install.sh — deploy SRT controller from a cloned repo to /mnt/srt/
# Run as root from inside the cloned repo: sudo bash install.sh
#
# After this script completes the repo directory is deleted —
# the live copy of everything is at /mnt/srt/.

set -euo pipefail

DEST=/mnt/srt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── preflight checks ──────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root: sudo bash install.sh" >&2
    exit 1
fi

if ! id srt &>/dev/null; then
    echo "ERROR: 'srt' user does not exist."
    echo "       Run: sudo useradd --system --no-create-home srt"
    exit 1
fi

if ! command -v inotifywait &>/dev/null; then
    echo "ERROR: inotifywait not found."
    echo "       Run: sudo apt install inotify-tools"
    exit 1
fi

if ! systemctl list-unit-files rp2040fs@.service &>/dev/null; then
    echo "WARNING: rp2040fs@.service not found — install rp2040-gpio-fs first."
    echo "         Continuing anyway, but srt-init will fail until it is present."
fi

# ── create destination ────────────────────────────────────────────────────────

echo "[install] Creating $DEST"
mkdir -p "$DEST"

# ── copy files ────────────────────────────────────────────────────────────────

echo "[install] Copying config"
cp -r "$SCRIPT_DIR/config" "$DEST/"

echo "[install] Copying scripts"
cp "$SCRIPT_DIR/srt-setup" "$DEST/srt-setup"
cp "$SCRIPT_DIR/srt-go"    "$DEST/srt-go"
cp "$SCRIPT_DIR/srt-init"  "$DEST/srt-init"
chmod +x "$DEST/srt-setup" "$DEST/srt-go" "$DEST/srt-init"

# ── systemd ───────────────────────────────────────────────────────────────────

echo "[install] Installing systemd services"
cp "$SCRIPT_DIR/systemd/srt-init.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/srt-go.service"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable srt-init.service srt-go.service

# ── ownership ─────────────────────────────────────────────────────────────────

echo "[install] Setting ownership to srt:srt"
chown -R srt:srt "$DEST"

# ── clean up repo ─────────────────────────────────────────────────────────────

echo "[install] Removing repo directory: $SCRIPT_DIR"
cd /
rm -rf "$SCRIPT_DIR"

# ── done ──────────────────────────────────────────────────────────────────────

echo ""
echo "[install] ✓ Installation complete. Repo directory removed."
echo ""
echo "  Live files:  $DEST"
echo "  Services:    srt-init.service  srt-go.service"
echo ""
echo "  Plug in the RP2040 to start automatically, or:"
echo "    systemctl start srt-init srt-go"
echo ""
echo "  Check status:"
echo "    systemctl status srt-init srt-go"
echo "    journalctl -fu srt-init"
echo "    journalctl -fu srt-go"
echo ""
echo "  Quick test once connected:"
echo "    cat /mnt/srt/enc/az_raw"
echo "    echo 1 > /mnt/srt/go/cw"
echo "    echo 0 > /mnt/srt/go/cw"
