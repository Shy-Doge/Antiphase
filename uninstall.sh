#!/usr/bin/env bash
# Antiphase — removes the plasmoid, the autostart entry and the daemon.
# Saved scenes and caches are kept unless you pass --purge.
set -euo pipefail

echo "==> Removing Antiphase"

if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --uninstall com.github.antiphase 2>/dev/null \
        || rm -rf "$HOME/.local/share/plasma/plasmoids/com.github.antiphase"
else
    rm -rf "$HOME/.local/share/plasma/plasmoids/com.github.antiphase"
fi

rm -f "$HOME/.config/autostart/antiphase.desktop"

pkill -f "backend/daemon.py" 2>/dev/null || true
echo "==> Daemon stopped"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/.local/share/antiphase" "$HOME/.cache/antiphase"
    echo "==> Saved scenes and cache purged"
else
    echo "==> Kept ~/.local/share/antiphase (scenes) and ~/.cache/antiphase"
    echo "    Remove them with: uninstall.sh --purge"
fi

echo "Done. If the widget is still on a panel, remove it in panel Edit Mode."
