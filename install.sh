#!/usr/bin/env bash
# Antiphase — one-shot installer
#
# Installs the plasmoid, registers the daemon as a autostart entry, and
# starts the daemon right away. Safe to re-run (upgrades in place).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/plasma/plasmoids/com.github.antiphase"
AUTOSTART="$HOME/.config/autostart/antiphase.desktop"
DAEMON="$SRC/contents/backend/daemon.py"

echo "==> Installing Antiphase from $SRC"

# 0. Dependencies: python3 + dbus-python (already present on most Plasma
#    systems; the daemon needs nothing else).
if ! python3 -c "import dbus" 2>/dev/null; then
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

# 2. Autostart the daemon on login. The path points into this checkout,
#    so keep it in place (or re-run install.sh after moving it).
mkdir -p "$HOME/.config/autostart"
cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Antiphase daemon
Exec=python3 $DAEMON
X-KDE-autostart-after=panel
EOF
echo "==> Autostart entry written to $AUTOSTART"

# 3. Start the daemon now (skip when one is already running)
if pgrep -f "backend/daemon.py" >/dev/null 2>&1; then
    echo "==> Daemon already running"
else
    setsid nohup python3 "$DAEMON" >/dev/null 2>&1 &
    sleep 1
    echo "==> Daemon started"
fi

echo
echo "Done! Last step, in KDE:"
echo "  Right-click the panel -> Enter Edit Mode -> Add Widgets -> search 'Antiphase'"
echo "  (then drag it into the system tray area)"
