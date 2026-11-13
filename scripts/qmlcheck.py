#!/usr/bin/env python3
"""
QML validation harness using PyQt6.

Loads the plasmoid's QML files the way plasmashell would and captures:
  - QQmlComponent.errors() (structured compile errors)
  - QML engine log messages via qInstallMessageHandler

Usage: python3 qmlcheck.py <ui_dir>

Note: the instantiation harness file is created BEFORE any other load so that
the engine's directory scan sees a stable file set (adding files to an already
scanned directory mid-process triggers a bogus "File name case mismatch" in
this Qt build — harmless for plasmashell, where the installed file set is static).
"""

import sys
import os

from PyQt6.QtCore import qInstallMessageHandler, QtMsgType, QUrl
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtQml import QQmlEngine, QQmlComponent

UI_DIR = (
    sys.argv[1]
    if len(sys.argv) > 1
    else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "contents",
        "ui",
    )
)

HARNESS_SRC = """
import QtQuick
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root
    width: 300
    height: 420
    property bool _connected: true
    property bool _connecting: false
    property var _devices: [
        {path: "/org/bluez/x", name: "WH-1000XM6", address: "AA:BB", paired: true, connected: false}
    ]
    property string _selectedDevice: "AA:BB"
    property string _deviceName: "WH-1000XM6"
    property string _modelName: "WH-1000XM6"
    property int _batteryPercent: 78
    property bool _charging: false
    property int _noiseMode: 2
    property int _ambientLevel: 10
    property bool _focusOnVoice: false
    property int _eqPreset: 3
    property bool _hasEq: true
    property bool _speakToChat: true
    property bool _adaptiveVolume: false
    property int _autoPowerOff: 5
    property string _firmware: "3.1.5"
    property string _codec: "LDAC"
    property var _profile: ({protocol: "MDR", eq: true, dsee: true, asc: true,
                              speakToChat: true, adaptiveVolume: false,
                              autoPowerOff: true})
    function _request(m, p) {}

    fullRepresentation: FullRepresentation { plasmoidItem: root }
    compactRepresentation: CompactRepresentation { plasmoidItem: root }
}
"""

TMP_PATH = os.path.join(UI_DIR, "___harness_tmp.qml")

collected = []


def on_msg(mode, ctx, msg):
    if mode in (
        QtMsgType.QtDebugMsg,
        QtMsgType.QtInfoMsg,
        QtMsgType.QtWarningMsg,
        QtMsgType.QtCriticalMsg,
        QtMsgType.QtFatalMsg,
    ):
        collected.append((mode.name, str(msg).strip()))


qInstallMessageHandler(on_msg)
app = QGuiApplication(sys.argv)
engine = QQmlEngine()

# Create the harness file up-front so all directory scans see the same file set.
with open(TMP_PATH, "w") as f:
    f.write(HARNESS_SRC)


def drain_msgs():
    global collected
    out, collected = collected, []
    return [
        f"  [{m}] {t}"
        for m, t in out
        if m in ("QtWarningMsg", "QtCriticalMsg", "QtFatalMsg") or "error" in t.lower()
    ]


def check_file(label, path):
    print(f"── {label} ──")
    comp = QQmlComponent(engine)
    comp.loadUrl(QUrl.fromLocalFile(path))
    errors = 0
    if comp.isError():
        for e in comp.errors():
            print(
                f"  COMPILE ERROR: {e.url()}:{e.line()}:{e.column()}: {e.description()}"
            )
            errors += 1
    else:
        print("  compiles OK")
    for line in drain_msgs():
        if "metadata.desktop" in line or "installEventFilter" in line:
            continue
        print(line)
    return errors


def create_test(label, path):
    print(f"── {label} ──")
    comp = QQmlComponent(engine)
    comp.loadUrl(QUrl.fromLocalFile(path))
    errors = 0
    if comp.isError():
        for e in comp.errors():
            print(
                f"  COMPILE ERROR: {e.url()}:{e.line()}:{e.column()}: {e.description()}"
            )
            errors += 1
    else:
        obj = comp.create()
        if obj is None:
            print("  CREATE FAILED (create() returned None)")
            errors += 1
        else:
            print("  creates OK")
    for line in drain_msgs():
        if "metadata.desktop" in line or "installEventFilter" in line:
            continue
        print(line)
    return errors


# 1. Compile each file standalone
total = 0
try:
    total += check_file("main.qml", os.path.join(UI_DIR, "main.qml"))
    total += check_file(
        "FullRepresentation.qml", os.path.join(UI_DIR, "FullRepresentation.qml")
    )
    total += check_file(
        "CompactRepresentation.qml", os.path.join(UI_DIR, "CompactRepresentation.qml")
    )
    total += check_file("configGeneral.qml", os.path.join(UI_DIR, "configGeneral.qml"))

    # 2. Full instantiation test: PlasmoidItem + both representations with mock state
    total += create_test(
        "instantiation: PlasmoidItem + FullRepresentation + CompactRepresentation",
        TMP_PATH,
    )
finally:
    # Never leave the harness file behind, even on a crash.
    try:
        os.unlink(TMP_PATH)
    except OSError:
        pass

print()
if total == 0:
    print("ALL CHECKS PASSED")
else:
    print(f"{total} PROBLEM(S) FOUND")
sys.exit(0 if total == 0 else 1)
