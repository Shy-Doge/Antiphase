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
    readonly property string batteryDisplay:
        Plasmoid.configuration.batteryDisplay || "text"
    readonly property bool batteryAsIcon: batteryDisplay === "icon"
    readonly property bool batteryBoth: batteryDisplay === "both"
    readonly property bool batteryGlyphRight:
        Plasmoid.configuration.batteryGlyphSide === "right"
    readonly property bool batteryOverlay:
        Plasmoid.configuration.batteryOverlay === true
    readonly property string batteryFontFamily: {
        const f = Plasmoid.configuration.batteryFont
        f && f !== "" ? f : Kirigami.Theme.defaultFont.family
    }
    readonly property int batteryPixelSize: {
        const s = Plasmoid.configuration.batteryFontSize
        s > 0 ? s : Kirigami.Theme.defaultFont.pixelSize
    }
    // "auto" is resolved to a concrete layout once, at load (the panel
    // reads a preferredWidth only at first layout). An explicit choice in
    // the config stays live because resolvedMode remains a binding.
    property string autoResolved: ""
    readonly property string resolvedMode: cfgMode === "auto"
        ? (autoResolved !== "" ? autoResolved : "compact")
        : cfgMode
    readonly property bool isWide: resolvedMode === "wide"

    // Left-to-right tray pieces, user-reorderable by dragging chips in the
    // config page ("icon,info,battery"). Pieces pack tightly in the chosen
    // order; unknown or missing tokens fall back to defaults.
    readonly property var trayTokens: {
        const raw = String(Plasmoid.configuration.trayOrder || "").split(",")
        const known = ["icon", "info", "battery"]
        const out = []
        for (const t of raw) {
            const k = t.trim()
            if (known.includes(k) && !out.includes(k))
                out.push(k)
        }
        if (!out.includes("icon"))
            out.unshift("icon")
        return out
    }

    // The panel assigns the icon size as this item's height; fall back to
    // the medium icon size before that first assignment lands.
    readonly property int iconSize: height > 0 ? Math.round(height)
                                               : Kirigami.Units.iconSizes.medium
    readonly property int imageWidth: Math.round(iconSize * 1.5)

    // Battery glyph (icon display mode / overlay badge).
    readonly property string batteryGlyph: {
        if (plasmoidItem._batteryPercent < 0)
            return ""
        const lvl = Math.max(0, Math.min(100,
                          Math.round(plasmoidItem._batteryPercent / 10) * 10))
        return "battery-" + ("00" + lvl).slice(-3)
             + (plasmoidItem._charging ? "-charging-symbolic" : "-symbolic")
    }
    readonly property int glyphWidth: Math.round(iconSize * 0.85)
    // Width the battery occupies inline (0 when it rides on the icon).
    readonly property int batteryInlineWidth: {
        const text = batteryMetric.implicitWidth
        if (batteryBoth)
            return glyphWidth + 2 + text
        return batteryAsIcon ? glyphWidth : text
    }

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
        // Noise mode as a short badge: Off / ANC / Ambient Sound.
        bits.push(["OFF", "ANC", "AS"][plasmoidItem._noiseMode] || "OFF")
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
                 + row.spacing + batteryInlineWidth + Kirigami.Units.smallSpacing
        default: // compact
            return iconSize + row.spacing + batteryInlineWidth
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
                 + batteryInlineWidth + gap
        default:
            return icon + gap + batteryInlineWidth
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

        Repeater {
            model: root.trayTokens

            delegate: Loader {
                id: piece
                required property var modelData

                Layout.alignment: Qt.AlignVCenter
                // The Loader is the layout child: fill/max-width must live
                // here, not on the loaded item (whose Layout properties the
                // RowLayout never sees).
                Layout.fillWidth: piece.modelData === "spacer"
                Layout.maximumWidth: piece.modelData === "info"
                                     ? root.nameWidth : Number.MAX_VALUE
                active: piece.modelData === "icon" ? true
                        : piece.modelData === "info" ? root.isWide
                        : piece.modelData === "battery"
                          ? root.resolvedMode !== "icon" && !root.batteryOverlay
                          : root.isWide   // spacer
                sourceComponent: piece.modelData === "icon" ? iconCell
                             : piece.modelData === "info" ? infoCell
                             : piece.modelData === "battery" ? batteryCell
                             : spacerCell
            }
        }
    }

    // Headset icon / product render, with the optional battery badge.
    // Sized through implicitWidth/Height: inside a Loader those, not
    // Layout.preferred*, are what the RowLayout ends up seeing.
    Component {
        id: iconCell
        Item {
            implicitWidth: root.isWide ? root.imageWidth : root.iconSize
            implicitHeight: root.iconSize

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
            // Overlay badge: the battery rides on the icon's corner, so it
            // costs no extra panel width (works in every layout).
            Kirigami.Icon {
                visible: root.batteryOverlay && root.batteryGlyph !== ""
                source: root.batteryGlyph
                width: Math.round(root.iconSize * 0.55)
                height: width
                anchors.right: parent.right
                anchors.bottom: parent.bottom
            }
        }
    }

    // Device name + codec/mode/DSEE status (wide layout only).
    Component {
        id: infoCell
        ColumnLayout {
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
    }

    Component {
        id: spacerCell
        Item {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
        }
    }

    // Battery readout: percentage text, battery glyph, or both — the
    // layoutDirection flips the glyph to the other side of the text.
    Component {
        id: batteryCell
        RowLayout {
            spacing: 2
            layoutDirection: root.batteryGlyphRight ? Qt.RightToLeft
                                                    : Qt.LeftToRight

            Kirigami.Icon {
                visible: root.batteryAsIcon || root.batteryBoth
                source: root.batteryGlyph
                Layout.preferredWidth: root.glyphWidth
                Layout.preferredHeight: root.glyphWidth
                Layout.alignment: Qt.AlignVCenter
            }
            PlasmaComponents3.Label {
                id: batteryText
                visible: !root.batteryAsIcon
                text: root.showPercent ? plasmoidItem._batteryPercent + "%"
                                       : (root.isWide ? "—" : "")
                font.bold: true
                font.family: root.batteryFontFamily
                font.pixelSize: root.batteryPixelSize
                color: plasmoidItem._batteryPercent <= 20 && root.showPercent
                       ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
            }
        }
    }

    // Hidden metrics used to reserve a stable width (widest readouts).
    PlasmaComponents3.Label {
        id: batteryMetric
        visible: false
        font.bold: true
        font.family: root.batteryFontFamily
        font.pixelSize: root.batteryPixelSize
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
        text: "LDAC · ANC · DSEE"
    }
}
