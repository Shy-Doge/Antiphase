/**
 * Antiphase — Compact (tray) representation
 *
 * Left click toggles the expanded view; right click is left untouched so
 * PlasmoidItem shows its native context menu.
 *
 * Three layouts, chosen by the "trayLayout" setting:
 *   icon    — just the headset icon
 *   compact — icon + battery percentage
 *   wide    — product render + device name + codec/mode/DSEE + battery
 *   auto    — the widest of the above that fits the free panel space
 *
 * The panel reads a representation's Layout.preferredWidth once, when the
 * applet is first laid out, and does not re-read it afterwards. So the mode
 * is resolved at load and the cell is sized for the widest content that
 * layout can show (e.g. "100%"), keeping the label from overflowing onto
 * neighbouring icons when a session connects a moment later.
 */

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

import "modelImages.js" as ModelImages

Item {
    id: root
    required property PlasmoidItem plasmoidItem

    readonly property bool showPercent: plasmoidItem._connected
                                        && plasmoidItem._batteryPercent >= 0

    readonly property string cfgMode: Plasmoid.configuration.trayLayout
    // "auto" is resolved to a concrete layout once, at load (the panel
    // reads a preferredWidth only at first layout). An explicit choice in
    // the config stays live because resolvedMode remains a binding.
    property string autoResolved: ""
    readonly property string resolvedMode: cfgMode === "auto"
        ? (autoResolved !== "" ? autoResolved : "compact")
        : cfgMode
    readonly property bool isWide: resolvedMode === "wide"

    // The panel assigns the icon size as this item's height; fall back to
    // the medium icon size before that first assignment lands.
    readonly property int iconSize: height > 0 ? Math.round(height)
                                               : Kirigami.Units.iconSizes.medium
    readonly property int imageWidth: Math.round(iconSize * 1.5)

    // ── Product render (shared table in modelImages.js) ─────────────────────
    readonly property string deviceLabel:
        plasmoidItem._modelName || plasmoidItem._deviceName || "Sony Headphones"
    readonly property string imageSource: ModelImages.imageSourceFor(deviceLabel)

    readonly property string statusLine: {
        if (!plasmoidItem._connected)
            return "Not connected"
        var bits = []
        if (plasmoidItem._codec)
            bits.push(plasmoidItem._codec)
        // Noise mode as a short badge: Off / NC / Ambient Sound.
        bits.push(["OFF", "NC", "AS"][plasmoidItem._noiseMode] || "OFF")
        if (plasmoidItem._dsee)
            bits.push("DSEE")
        return bits.join(" · ")
    }

    // ── Width reservation ────────────────────────────────────────────────────
    // The text column is as wide as its widest line — the name or the
    // status line — plus a smallSpacing of slack: at exactly-metric width
    // the RowLayout's rounding elides the last character.
    readonly property int nameWidth: Math.min(Math.max(nameMetric.implicitWidth,
                                                       statusMetric.implicitWidth)
                                              + Kirigami.Units.smallSpacing,
                                              Kirigami.Units.gridUnit * 12)
    readonly property int neededWidth: {
        switch (resolvedMode) {
        case "icon":
            return iconSize
        case "wide":
            return imageWidth + row.spacing + nameWidth
                 + row.spacing + batteryMetric.implicitWidth + Kirigami.Units.smallSpacing
        default: // compact
            return iconSize + row.spacing + batteryMetric.implicitWidth
        }
    }

    implicitWidth: neededWidth
    implicitHeight: Kirigami.Units.iconSizes.medium
    Layout.preferredWidth: neededWidth

    // ── Automatic mode: measure the free panel width at load ─────────────────
    function panelFreeWidth() {
        let layout = root.parent
        while (layout && !(layout instanceof GridLayout))
            layout = layout.parent
        if (!layout)
            return -1
        let mine = root.parent
        while (mine && mine.parent !== layout)
            mine = mine.parent
        let used = 0
        for (let i = 0; i < layout.children.length; i++) {
            const c = layout.children[i]
            if (!c.visible || c === mine)
                continue
            // A flexible sibling (expanding spacer) simply shrinks towards
            // zero when we claim width, so it contributes nothing used.
            if (c.Layout.fillWidth)
                continue
            if (c.Layout.preferredWidth > 0)
                used += c.Layout.preferredWidth
        }
        // The panel's layout spans the available tray width; the old
        // Plasmoid.containmentItem does not exist in Plasma 6.
        return layout.width - used
    }

    function autoPick() {
        const free = panelFreeWidth()
        if (free < 0)
            return "compact"
        if (free >= neededForMode("wide") + Kirigami.Units.largeSpacing * 2)
            return "wide"
        if (free >= neededForMode("compact") + Kirigami.Units.largeSpacing)
            return "compact"
        return "icon"
    }

    // Estimate a mode's width using the medium icon size (height is not yet
    // assigned when this runs at load).
    function neededForMode(mode) {
        const icon = Kirigami.Units.iconSizes.medium
        const gap = Kirigami.Units.smallSpacing
        switch (mode) {
        case "icon":
            return icon
        case "wide":
            return Math.round(icon * 1.5) + gap + nameWidth + gap
                 + batteryMetric.implicitWidth + gap
        default:
            return icon + gap + batteryMetric.implicitWidth
        }
    }

    Component.onCompleted: {
        if (cfgMode === "auto")
            autoResolved = autoPick()
    }

    MouseArea {
        anchors.fill: parent
        onClicked: mouse => {
            if (mouse.button === Qt.LeftButton)
                plasmoidItem.expanded = !plasmoidItem.expanded
        }
    }

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        // Product render (wide) or icon (icon / compact)
        Item {
            Layout.preferredWidth: root.isWide ? root.imageWidth : root.iconSize
            Layout.preferredHeight: root.iconSize
            Layout.alignment: Qt.AlignVCenter

            Image {
                id: trayImage
                anchors.fill: parent
                anchors.margins: 1
                visible: root.isWide && root.imageSource !== "" && status === Image.Ready
                source: root.imageSource
                fillMode: Image.PreserveAspectFit
                asynchronous: true
            }
            Kirigami.Icon {
                anchors.fill: parent
                // Fallback whenever the render is absent, still loading or
                // failed — the wide cell must never go blank.
                visible: !root.isWide || trayImage.status !== Image.Ready
                source: Plasmoid.icon
            }
        }

        // Name + status (wide only)
        ColumnLayout {
            visible: root.isWide
            Layout.fillHeight: true
            Layout.maximumWidth: root.nameWidth
            spacing: 0

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: root.deviceLabel
                font.pixelSize: 12
                font.bold: true
                elide: Text.ElideRight
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: root.statusLine
                font.pixelSize: 9
                color: Kirigami.Theme.disabledTextColor
                elide: Text.ElideRight
            }
        }

        Item {
            visible: root.isWide
            Layout.fillWidth: true
            Layout.preferredWidth: 0
        }

        // Battery percentage (compact / wide)
        PlasmaComponents3.Label {
            visible: root.resolvedMode !== "icon"
            Layout.alignment: Qt.AlignVCenter
            text: root.showPercent ? plasmoidItem._batteryPercent + "%"
                                   : (root.isWide ? "—" : "")
            font.bold: true
            color: plasmoidItem._batteryPercent <= 20 && root.showPercent
                   ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
        }
    }

    // Hidden metrics used to reserve a stable width (widest readouts).
    PlasmaComponents3.Label {
        id: batteryMetric
        visible: false
        font.bold: true
        text: "100%"
    }
    PlasmaComponents3.Label {
        id: nameMetric
        visible: false
        font.pixelSize: 12
        font.bold: true
        // Tracks the live label; at load this is the "Sony Headphones"
        // fallback, which is wider than any known model name, so the
        // reservation covers the real name once it arrives.
        text: root.deviceLabel
    }
    PlasmaComponents3.Label {
        id: statusMetric
        visible: false
        font.pixelSize: 9
        // Widest status the line can ever show.
        text: "LDAC · NC · DSEE"
    }
}
