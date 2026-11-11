#!/usr/bin/env bash
# Antiphase — removes the plasmoid, the daemon service and the installed
# backend copy. Saved scenes and caches are kept unless you pass --purge.
set -euo pipefail

BACKEND_DIR="$HOME/.local/share/antiphase/backend"
SERVICE="$HOME/.config/systemd/user/antiphase.service"

echo "==> Removing Antiphase"

if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --uninstall com.github.antiphase 2>/dev/null \
        || rm -rf "$HOME/.local/share/plasma/plasmoids/com.github.antiphase"
else
    rm -rf "$HOME/.local/share/plasma/plasmoids/com.github.antiphase"
fi

# Stop and unregister the systemd user service.
if systemctl --user status >/dev/null 2>&1; then
    systemctl --user disable --now antiphase.service 2>/dev/null || true
    rm -f "$SERVICE"
    systemctl --user daemon-reload
fi

# Legacy autostart entry and any daemon still running (from the service,
# the old autostart, or a manual start).
rm -f "$HOME/.config/autostart/antiphase.desktop"
pkill -f "python3 .*/backend/daemon.py" 2>/dev/null || true
echo "==> Daemon stopped"

# The installed backend copy (the repo checkout is untouched).
rm -rf "$BACKEND_DIR"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/.local/share/antiphase" "$HOME/.cache/antiphase"
    echo "==> Saved scenes and cache purged"
else
    echo "==> Kept ~/.local/share/antiphase (scenes) and ~/.cache/antiphase"
    echo "    Remove them with: uninstall.sh --purge"
fi

echo "Done. If the widget is still on a panel, remove it in panel Edit Mode."
