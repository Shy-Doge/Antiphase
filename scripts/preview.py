#!/usr/bin/env python3
"""
Live visual preview for the plasmoid UI.

Runs the real main.qml (daemon connection + state) together with the real
FullRepresentation inside a visible window, so the design can be iterated on
via screenshots (grim) without touching plasmashell.

Usage: python3 preview.py [seconds] [out.png]
  With out.png: self-capture the window (grabWindow) after 1.5s and exit —
  immune to window stacking / multi-monitor placement.
  Without: window stays open until timeout / Ctrl-C.
"""

import sys
import os

from PyQt6.QtCore import qInstallMessageHandler, QTimer
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtQml import QQmlApplicationEngine


def _h(mode, ctx, msg):
    s = str(msg)
    if "metadata.desktop" not in s and "installEventFilter" not in s:
        print(f"[{mode}] {s}", flush=True)


qInstallMessageHandler(_h)
app = QGuiApplication(sys.argv)
engine = QQmlApplicationEngine()

# SONY_PREVIEW_STATE: connected | list | dual | disconnected
engine.rootContext().setContextProperty(
    "previewState", os.environ.get("SONY_PREVIEW_STATE", "connected")
)

# Window width override (SONY_PREVIEW_WIDTH=460) to exercise the adaptive
# wide/narrow detail header without a real panel.
engine.rootContext().setContextProperty(
    "previewWidth", int(os.environ.get("SONY_PREVIEW_WIDTH", "0"))
)

# Force a detail header arrangement (SONY_PREVIEW_DETAIL=stacked|side)
# to screenshot both layouts independent of width/config.
engine.rootContext().setContextProperty(
    "previewDetail", os.environ.get("SONY_PREVIEW_DETAIL", "")
)

# Optional self-capture destination (argv[2]); preview.qml grabs and quits.
engine.rootContext().setContextProperty(
    "previewOut", sys.argv[2] if len(sys.argv) > 2 else ""
)

ui_dir = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "contents", "ui"
)
engine.load(os.path.join(ui_dir, "preview.qml"))
if not engine.rootObjects():
    print("FAILED to load preview.qml", flush=True)
    sys.exit(1)

hold = float(sys.argv[1]) if len(sys.argv) > 1 else 0

# With previewOut set, preview.qml self-captures via
# contentItem.grabToImage() (Wayland-safe) and quits. Otherwise the window
# stays on screen until the timeout.
if hold > 0:
    QTimer.singleShot(int(hold * 1000), app.quit)

app.exec()
