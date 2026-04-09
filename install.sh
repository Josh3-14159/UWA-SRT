#!/bin/bash
# install.sh — deploy or update the SRT controller.
# Run as root from inside the cloned repo: sudo bash install.sh
#
# Fresh install:  copies all files to /mnt/srt/, installs and enables all
#                 systemd services and the watchdog timer, then deletes the
#                 repo directory.
# Update:         detects existing install, shows a diff of what will change,
#                 asks confirmation, stops services, updates files, restarts.

set -euo pipefail

DEST=/mnt/srt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DROPIN_DIR=/etc/systemd/system/rp2040fs@srt.service.d
DROPIN_SRC="$SCRIPT_DIR/systemd/rp2040fs@srt.service.d/allow_other.conf"
DROPIN_DST="$DROPIN_DIR/allow_other.conf"

# Files managed by this installer
HAL_SCRIPTS=(hal/srt-setup hal/srt-init hal/srt-go)
CTL_SCRIPTS=(control/srt-gs232 control/srt-watchdog)
CONFIGS=(config/pin_map config/az_cal config/el_cal)
UNITS=(
    srt-init.service
    srt-go.service
    srt-gs232.service
    srt-gs232-dev.service
    srt-watchdog.service
    srt-watchdog.timer
)
SERVICES=(
    srt-init.service
    srt-go.service
    srt-gs232.service
    srt-gs232-dev.service
)
TIMER=srt-watchdog.timer

log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*"; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ── preflight ─────────────────────────────────────────────────────────────────

[ "$EUID" -eq 0 ] \
    || die "Run as root: sudo bash install.sh"
id srt &>/dev/null \
    || die "'srt' user does not exist. Run: sudo useradd --system --no-create-home srt"
command -v inotifywait &>/dev/null \
    || die "inotifywait not found. Run: sudo apt install inotify-tools"
command -v python3 &>/dev/null \
    || die "python3 not found. Run: sudo apt install python3"
systemctl list-unit-files rp2040fs@.service &>/dev/null \
    || warn "rp2040fs@.service not found — install rp2040-gpio-fs first."

# ── fuse.conf ─────────────────────────────────────────────────────────────────

apply_fuse_conf() {
    if grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
        log "fuse.conf: user_allow_other already enabled."
    else
        log "fuse.conf: enabling user_allow_other."
        if [ -f /etc/fuse.conf ]; then
            sed -i 's/#\s*user_allow_other/user_allow_other/' /etc/fuse.conf
        fi
        grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null \
            || echo "user_allow_other" >> /etc/fuse.conf
    fi
}

# ── rp2040fs drop-in ──────────────────────────────────────────────────────────

apply_dropin() {
    mkdir -p "$DROPIN_DIR"
    if [ -f "$DROPIN_DST" ] && diff -q "$DROPIN_SRC" "$DROPIN_DST" &>/dev/null; then
        log "rp2040fs drop-in: already up to date."
    else
        log "rp2040fs drop-in: installing allow_other override."
        cp "$DROPIN_SRC" "$DROPIN_DST"
    fi
}

# ── install a set of scripts preserving subdir structure ──────────────────────

install_scripts() {
    local scripts=("$@")
    for s in "${scripts[@]}"; do
        local dst_dir="$DEST/$(dirname "$s")"
        mkdir -p "$dst_dir"
        cp "$SCRIPT_DIR/$s" "$DEST/$s"
        chmod +x "$DEST/$s"
    done
}

# ── copy config files individually (avoids cp -r directory confusion) ─────────

install_config() {
    mkdir -p "$DEST/config"
    for f in "${CONFIGS[@]}"; do
        cp "$SCRIPT_DIR/$f" "$DEST/$f"
    done
}

# ── detect changed files between src and dst ──────────────────────────────────

changed_files() {
    local src_pfx="$1" dst_pfx="$2"
    shift 2
    local changed=()
    for f in "$@"; do
        local src="$src_pfx/$f" dst="$dst_pfx/$f"
        if [ -f "$src" ] && [ -f "$dst" ]; then
            diff -q "$src" "$dst" &>/dev/null || changed+=("$f")
        elif [ -f "$src" ]; then
            changed+=("$f  [NEW]")
        fi
    done
    printf '%s\n' "${changed[@]+"${changed[@]}"}"
}

# ── detect existing install ───────────────────────────────────────────────────

EXISTING=0
[ -d "$DEST" ] && [ -f "$DEST/hal/srt-setup" ] && EXISTING=1

# =============================================================================
# UPDATE PATH
# =============================================================================

if [ "$EXISTING" -eq 1 ]; then
    echo ""
    echo "  Existing SRT installation detected at $DEST"
    echo ""

    ALL_SCRIPTS=("${HAL_SCRIPTS[@]}" "${CTL_SCRIPTS[@]}")

    mapfile -t CHANGED_S   < <(changed_files "$SCRIPT_DIR"          "$DEST"                  "${ALL_SCRIPTS[@]}")
    mapfile -t CHANGED_CFG < <(changed_files "$SCRIPT_DIR"          "$DEST"                  "${CONFIGS[@]}")
    mapfile -t CHANGED_U   < <(changed_files "$SCRIPT_DIR/systemd"  "/etc/systemd/system"    "${UNITS[@]}")

    DROPIN_CHANGED=0
    { [ ! -f "$DROPIN_DST" ] || ! diff -q "$DROPIN_SRC" "$DROPIN_DST" &>/dev/null; } \
        && DROPIN_CHANGED=1

    TOTAL=$(( ${#CHANGED_S[@]} + ${#CHANGED_CFG[@]} + ${#CHANGED_U[@]} + DROPIN_CHANGED ))

    if [ "$TOTAL" -eq 0 ]; then
        echo "  No changes detected — installed files match repo."
        echo ""
        confirm "  Force reinstall anyway?" || { echo "  Aborted."; exit 0; }
        mapfile -t CHANGED_S   < <(printf '%s\n' "${ALL_SCRIPTS[@]}")
        mapfile -t CHANGED_CFG < <(printf '%s\n' "${CONFIGS[@]}")
        mapfile -t CHANGED_U   < <(printf '%s\n' "${UNITS[@]}")
        DROPIN_CHANGED=1
    else
        echo "  The following will be updated:"
        echo ""
        for f in "${CHANGED_S[@]+"${CHANGED_S[@]}"}";   do echo "    $f"; done
        for f in "${CHANGED_CFG[@]+"${CHANGED_CFG[@]}"}"; do echo "    $f"; done
        for f in "${CHANGED_U[@]+"${CHANGED_U[@]}"}";   do echo "    systemd/$f"; done
        [ "$DROPIN_CHANGED" -eq 1 ] \
            && echo "    systemd/rp2040fs@srt.service.d/allow_other.conf"
        echo ""

        if confirm "  Show full diff before continuing?"; then
            echo ""
            for s in "${ALL_SCRIPTS[@]}"; do
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
            [ "$DROPIN_CHANGED" -eq 1 ] && [ -f "$DROPIN_DST" ] \
                && diff --color=always -u "$DROPIN_DST" "$DROPIN_SRC" || true
            echo ""
        fi

        confirm "  Proceed with update?" || { echo "  Aborted."; exit 0; }
    fi

    # Stop services
    log "Stopping services..."
    systemctl stop srt-watchdog.timer    2>/dev/null || true
    systemctl stop srt-watchdog.service  2>/dev/null || true
    for s in "${SERVICES[@]}"; do systemctl stop "$s" 2>/dev/null || true; done

    # Zero drive pins for safety
    log "Zeroing drive pins."
    for f in cw ccw up dn; do
        echo "0" > "$DEST/drive/$f" 2>/dev/null || true
        echo "0" > "$DEST/go/$f"    2>/dev/null || true
    done

    apply_fuse_conf
    apply_dropin

    log "Updating HAL scripts"
    install_scripts "${HAL_SCRIPTS[@]}"

    log "Updating control scripts"
    install_scripts "${CTL_SCRIPTS[@]}"

    # Config — per-file confirmation to protect local calibration edits
    for c in "${CHANGED_CFG[@]+"${CHANGED_CFG[@]}"}"; do
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
            mkdir -p "$DEST/$(dirname "$cf")"
            cp "$src" "$dst"; log "Installed new $cf"
        fi
    done

    log "Updating systemd units"
    for u in "${UNITS[@]}"; do
        [ -f "$SCRIPT_DIR/systemd/$u" ] \
            && cp "$SCRIPT_DIR/systemd/$u" "/etc/systemd/system/$u"
    done

    chown -R srt:srt "$DEST"
    chown root:root "$DEST/control/srt-watchdog"

    log "Reloading systemd and restarting services"
    systemctl daemon-reload
    systemctl enable "${SERVICES[@]}" "$TIMER"
    systemctl restart rp2040fs@srt.service
    for s in "${SERVICES[@]}"; do systemctl restart --no-block "$s"; done
    systemctl restart "$TIMER"

    log "Cleaning up repo directory"
    cd /; rm -rf "$SCRIPT_DIR"
    echo ""; echo "[install] ✓ Update complete. Repo directory removed."

# =============================================================================
# FRESH INSTALL PATH
# =============================================================================

else
    echo ""; echo "  No existing installation found. Fresh install to $DEST"; echo ""
    confirm "  Continue?" || { echo "  Aborted."; exit 0; }

    apply_fuse_conf
    apply_dropin

    mkdir -p "$DEST"

    log "Installing HAL scripts"
    install_scripts "${HAL_SCRIPTS[@]}"

    log "Installing control scripts"
    install_scripts "${CTL_SCRIPTS[@]}"

    log "Copying config"
    install_config

    log "Installing systemd units"
    for u in "${UNITS[@]}"; do
        cp "$SCRIPT_DIR/systemd/$u" "/etc/systemd/system/$u"
    done

    chown -R srt:srt "$DEST"
    chown root:root "$DEST/control/srt-watchdog"

    log "Enabling and starting services"
    systemctl daemon-reload
    systemctl enable "${SERVICES[@]}" "$TIMER"
    systemctl restart rp2040fs@srt.service
    for s in "${SERVICES[@]}"; do systemctl start --no-block "$s"; done
    systemctl start "$TIMER"

    log "Removing repo directory"
    cd /; rm -rf "$SCRIPT_DIR"
    echo ""; echo "[install] ✓ Installation complete. Repo directory removed."
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "  Live files:  $DEST"
echo "  Layout:"
echo "    $DEST/hal/         srt-setup  srt-init  srt-go"
echo "    $DEST/control/     srt-gs232  srt-watchdog"
echo "    $DEST/config/      pin_map  az_cal  el_cal"
echo ""
echo "  Services:"
echo "    srt-init.service      HAL initialiser + sentinel"
echo "    srt-go.service        go/ axis controller"
echo "    srt-gs232.service     GS-232 PTY daemon"
echo "    srt-gs232-dev.service PTY symlink in /dev"
echo "    srt-watchdog.timer    health check every 30s"
echo ""
echo "  Check status:"
echo "    systemctl status srt-init srt-go srt-gs232 srt-watchdog.timer"
echo "    journalctl -fu srt-init"
echo "    journalctl -fu srt-go"
echo "    journalctl -fu srt-gs232"
echo "    journalctl -fu srt-watchdog"
echo ""
echo "  Quick test once RP2040 is connected:"
echo "    cat /mnt/srt/enc/az_raw"
echo "    echo 1 > /mnt/srt/go/cw && sleep 1 && echo 0 > /mnt/srt/go/cw"
echo "    minicom -D /dev/srt_rotator   # send: C"
