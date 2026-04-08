#!/bin/bash
# install.sh — deploy or update the SRT controller.
# Run as root from inside the cloned repo: sudo bash install.sh
#
# Fresh install:  copies files to /mnt/srt/, installs and enables all services,
#                 then deletes the repo directory.
# Update:         detects existing install, shows diff, asks confirmation,
#                 stops services, updates files, restarts.

set -euo pipefail

DEST=/mnt/srt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVICES=(srt-init.service srt-go.service)
TIMER=srt-watchdog.timer
UNITS=(srt-init.service srt-go.service srt-watchdog.service srt-watchdog.timer)

log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*"; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ── preflight ─────────────────────────────────────────────────────────────────

[ "$EUID" -eq 0 ] || die "Run as root: sudo bash install.sh"
id srt &>/dev/null      || die "'srt' user does not exist. Run: sudo useradd --system --no-create-home srt"
command -v inotifywait &>/dev/null || die "inotifywait not found. Run: sudo apt install inotify-tools"
systemctl list-unit-files rp2040fs@.service &>/dev/null || warn "rp2040fs@.service not found — install rp2040-gpio-fs first."

SCRIPTS=(srt-setup srt-go srt-init srt-watchdog)
CONFIGS=(config/pin_map config/az_cal config/el_cal)

# ── detect existing install ───────────────────────────────────────────────────

EXISTING=0
[ -d "$DEST" ] && [ -f "$DEST/srt-setup" ] && EXISTING=1

# ═════════════════════════════════════════════════════════════════════════════
# UPDATE PATH
# ═════════════════════════════════════════════════════════════════════════════

if [ "$EXISTING" -eq 1 ]; then
    echo ""
    echo "  Existing SRT installation detected at $DEST"
    echo ""

    CHANGED=()
    for s in "${SCRIPTS[@]}"; do
        src="$SCRIPT_DIR/$s"; dst="$DEST/$s"
        if   [ -f "$src" ] && [ -f "$dst" ]; then diff -q "$src" "$dst" &>/dev/null || CHANGED+=("$s")
        elif [ -f "$src" ];                  then CHANGED+=("$s  [NEW]"); fi
    done

    CHANGED_CFG=()
    for c in "${CONFIGS[@]}"; do
        src="$SCRIPT_DIR/$c"; dst="$DEST/$c"
        if   [ -f "$src" ] && [ -f "$dst" ]; then diff -q "$src" "$dst" &>/dev/null || CHANGED_CFG+=("$c")
        elif [ -f "$src" ];                  then CHANGED_CFG+=("$c  [NEW]"); fi
    done

    CHANGED_UNITS=()
    for u in "${UNITS[@]}"; do
        src="$SCRIPT_DIR/systemd/$u"; dst="/etc/systemd/system/$u"
        if   [ -f "$src" ] && [ -f "$dst" ]; then diff -q "$src" "$dst" &>/dev/null || CHANGED_UNITS+=("$u")
        elif [ -f "$src" ];                  then CHANGED_UNITS+=("$u  [NEW]"); fi
    done

    TOTAL=$(( ${#CHANGED[@]} + ${#CHANGED_CFG[@]} + ${#CHANGED_UNITS[@]} ))

    if [ "$TOTAL" -eq 0 ]; then
        echo "  No changes detected — installed files match repo."
        echo ""
        confirm "  Force reinstall anyway?" || { echo "  Aborted."; exit 0; }
        CHANGED=("${SCRIPTS[@]}")
        CHANGED_CFG=("${CONFIGS[@]}")
        CHANGED_UNITS=("${UNITS[@]}")
    else
        echo "  The following files will be updated:"
        echo ""
        for f in "${CHANGED[@]}";       do echo "    scripts/  $f"; done
        for f in "${CHANGED_CFG[@]}";   do echo "    config/   $f"; done
        for f in "${CHANGED_UNITS[@]}"; do echo "    systemd/  $f"; done
        echo ""

        if confirm "  Show full diff before continuing?"; then
            echo ""
            for s in "${SCRIPTS[@]}"; do
                src="$SCRIPT_DIR/$s"; dst="$DEST/$s"
                [ -f "$src" ] && [ -f "$dst" ] && diff --color=always -u "$dst" "$src" || true
            done
            for c in "${CONFIGS[@]}"; do
                src="$SCRIPT_DIR/$c"; dst="$DEST/$c"
                [ -f "$src" ] && [ -f "$dst" ] && diff --color=always -u "$dst" "$src" || true
            done
            for u in "${UNITS[@]}"; do
                src="$SCRIPT_DIR/systemd/$u"; dst="/etc/systemd/system/$u"
                [ -f "$src" ] && [ -f "$dst" ] && diff --color=always -u "$dst" "$src" || true
            done
            echo ""
        fi

        confirm "  Proceed with update?" || { echo "  Aborted."; exit 0; }
    fi

    log "Stopping services..."
    systemctl stop srt-watchdog.timer   2>/dev/null || true
    systemctl stop srt-watchdog.service 2>/dev/null || true
    for s in "${SERVICES[@]}"; do systemctl stop "$s" 2>/dev/null || true; done

    log "Zeroing drive pins for safety."
    for f in cw ccw up dn; do
        echo "0" > "$DEST/drive/$f" 2>/dev/null || true
        echo "0" > "$DEST/go/$f"    2>/dev/null || true
    done

    log "Updating scripts"
    for s in "${SCRIPTS[@]}"; do
        [ -f "$SCRIPT_DIR/$s" ] && cp "$SCRIPT_DIR/$s" "$DEST/$s" && chmod +x "$DEST/$s"
    done

    for c in "${CHANGED_CFG[@]}"; do
        cf="${c%  \[NEW\]}"
        src="$SCRIPT_DIR/$cf"; dst="$DEST/$cf"
        if [ -f "$dst" ]; then
            echo ""; echo "  Config file changed: $cf"
            diff --color=always -u "$dst" "$src" || true; echo ""
            if confirm "  Overwrite $cf?"; then
                cp "$src" "$dst"; log "Updated $cf"
            else
                log "Kept existing $cf"
            fi
        else
            cp "$src" "$dst"; log "Installed new $cf"
        fi
    done

    log "Updating systemd units"
    for u in "${UNITS[@]}"; do
        [ -f "$SCRIPT_DIR/systemd/$u" ] && cp "$SCRIPT_DIR/systemd/$u" "/etc/systemd/system/$u"
    done

    chown -R srt:srt "$DEST"
    chown root:root "$DEST/srt-watchdog"

    log "Reloading systemd and restarting services"
    systemctl daemon-reload
    systemctl enable "${SERVICES[@]}" "$TIMER"
    for s in "${SERVICES[@]}"; do systemctl restart "$s"; done
    systemctl restart "$TIMER"

    log "Cleaning up repo directory"
    cd /; rm -rf "$SCRIPT_DIR"
    echo ""; echo "[install] ✓ Update complete. Repo directory removed."

# ═════════════════════════════════════════════════════════════════════════════
# FRESH INSTALL PATH
# ═════════════════════════════════════════════════════════════════════════════

else
    echo ""; echo "  No existing installation found. Fresh install to $DEST"; echo ""
    confirm "  Continue?" || { echo "  Aborted."; exit 0; }

    mkdir -p "$DEST"

    log "Copying scripts"
    for s in "${SCRIPTS[@]}"; do cp "$SCRIPT_DIR/$s" "$DEST/$s" && chmod +x "$DEST/$s"; done

    log "Copying config"
    cp -r "$SCRIPT_DIR/config" "$DEST/"

    log "Installing systemd units"
    for u in "${UNITS[@]}"; do cp "$SCRIPT_DIR/systemd/$u" "/etc/systemd/system/$u"; done

    chown -R srt:srt "$DEST"
    chown root:root "$DEST/srt-watchdog"

    log "Enabling and starting services"
    systemctl daemon-reload
    systemctl enable "${SERVICES[@]}" "$TIMER"
    for s in "${SERVICES[@]}"; do systemctl start "$s"; done
    systemctl start "$TIMER"

    log "Removing repo directory"
    cd /; rm -rf "$SCRIPT_DIR"
    echo ""; echo "[install] ✓ Installation complete. Repo directory removed."
fi

# ── post-install summary ──────────────────────────────────────────────────────

echo ""
echo "  Live files:  $DEST"
echo ""
echo "  Services:"
echo "    srt-init.service      — pin initialiser + sentinel writer"
echo "    srt-go.service        — go/ axis controller"
echo "    srt-watchdog.timer    — health check every 30s"
echo ""
echo "  Check status:"
echo "    systemctl status srt-init srt-go srt-watchdog.timer"
echo "    journalctl -fu srt-init"
echo "    journalctl -fu srt-go"
echo "    journalctl -fu srt-watchdog"
echo ""
echo "  Quick test once RP2040 is connected:"
echo "    cat /mnt/srt/enc/az_raw"
echo "    echo 1 > /mnt/srt/go/cw && sleep 1 && echo 0 > /mnt/srt/go/cw"
