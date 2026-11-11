#!/usr/bin/env bash
# Antiphase — one-shot installer
#
# Installs the plasmoid, copies the daemon backend to a stable location
# (~/.local/share/antiphase/backend) so the checkout can be moved or renamed
# freely, registers it as a systemd user service (autostart .desktop as a
# fallback) and starts it right away. Safe to re-run (upgrades in place).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/plasma/plasmoids/com.github.antiphase"
AUTOSTART="$HOME/.config/autostart/antiphase.desktop"
BACKEND_DIR="$HOME/.local/share/antiphase/backend"
SERVICE="$HOME/.config/systemd/user/antiphase.service"
PYTHON="$(command -v python3)"

echo "==> Installing Antiphase from $SRC"

# 0. Dependencies: python3 + dbus-python (already present on most Plasma
#    systems; the daemon needs nothing else).
if ! "$PYTHON" -c "import dbus" 2>/dev/null; then
    echo "ERROR: the 'dbus' Python module is missing." >&2
    echo "  Arch:   sudo pacman -S python-dbus" >&2
    echo "  Debian: sudo apt install python3-dbus" >&2
    exit 1
fi

# 1. The plasmoid itself
if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --install "$SRC" 2>/dev/null \
        || kpackagetool6 --type Plasma/Applet --upgrade "$SRC"
else
    mkdir -p "$DEST"
    cp -r "$SRC/contents" "$SRC/metadata.json" "$SRC/LICENSE" "$SRC/README.md" "$DEST/"
fi
echo "==> Plasmoid installed"

# 2. Copy the backend to a stable location. The repo is pure source from
#    here on: renaming or moving the checkout no longer breaks the daemon.
#    (Re-run install.sh after changing the backend code.)
mkdir -p "$BACKEND_DIR"
cp "$SRC/contents/backend/backend.py" "$SRC/contents/backend/daemon.py" "$BACKEND_DIR/"
rm -rf "$BACKEND_DIR/__pycache__"
echo "==> Backend installed to $BACKEND_DIR"

# 3. Stop the daemon — the service first (so systemd doesn't auto-restart
#    it mid-install), then any legacy autostart/manual instance — so the
#    new unit can bind the port cleanly.
if systemctl --user is-active --quiet antiphase.service 2>/dev/null \
        || systemctl --user is-failed --quiet antiphase.service 2>/dev/null; then
    systemctl --user stop antiphase.service
fi
pkill -f "python3 .*/backend/daemon.py" 2>/dev/null || true

# 4. Register the daemon. Prefer a systemd user service (starts on login,
#    restarts on crash); fall back to an autostart entry otherwise.
if systemctl --user status >/dev/null 2>&1; then
    mkdir -p "$(dirname "$SERVICE")"
    cat > "$SERVICE" <<EOF
[Unit]
Description=Antiphase Sony headphone daemon
After=pulseaudio.service

[Service]
ExecStart=$PYTHON $BACKEND_DIR/daemon.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
    # Drop the legacy autostart entry; systemd owns startup now.
    rm -f "$AUTOSTART"
    systemctl --user daemon-reload
    systemctl --user enable antiphase.service
    systemctl --user restart antiphase.service
    sleep 1
    if systemctl --user is-active --quiet antiphase.service; then
        echo "==> Daemon running as systemd user service 'antiphase'"
    else
        echo "WARNING: the daemon service failed to start:" >&2
        systemctl --user status antiphase.service --no-pager >&2 || true
    fi
else
    mkdir -p "$HOME/.config/autostart"
    cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Antiphase daemon
Exec=$PYTHON $BACKEND_DIR/daemon.py
X-KDE-autostart-after=panel
EOF
    setsid nohup "$PYTHON" "$BACKEND_DIR/daemon.py" >/dev/null 2>&1 &
    sleep 1
    echo "==> Autostart entry written to $AUTOSTART (no systemd user instance)"
fi

echo
echo "Done! Last step, in KDE:"
echo "  Right-click the panel -> Enter Edit Mode -> Add Widgets -> search 'Antiphase'"
echo "  (then drag it into the system tray area)"
