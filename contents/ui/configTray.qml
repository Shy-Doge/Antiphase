import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Dialogs
import QtQuick.Layouts

import org.kde.iconthemes as KIconThemes
import org.kde.kirigami as Kirigami

// Tray page: everything about the panel cell. The popup side lives in
// configPopup.qml; contents/config/config.qml wires both into the dialog.
// The config framework binds the cfg_* properties on this root object.
// Kirigami.FormLayout exposes no margins of its own, so padding is applied
// by anchoring it inside this Item with margins.
Item {
    id: page

    readonly property int pad: Kirigami.Units.largeSpacing
    // The Plasma config dialog caps its width; a wider page would clip its
    // controls off-screen, so cap the request and let the controls fill.
    implicitWidth: Math.min(form.implicitWidth + pad * 2, 460)
    implicitHeight: form.implicitHeight + pad * 2

    // Provided by the Plasma config framework (bound to the KConfigXT keys).
    property string cfg_trayLayout: "auto"
    property string cfg_icon: "auto"
    property string cfg_batteryDisplay: "text"
    property string cfg_batteryGlyphSide: "left"
    property bool cfg_batteryOverlay: false
    property string cfg_trayOrder: "icon,info,battery"
    property string cfg_batteryFont: ""
    property int cfg_batteryFontSize: 0
    property string cfg_nameFont: ""
    property int cfg_nameFontSize: 0
    property string cfg_statusFont: ""
    property int cfg_statusFontSize: 0
    property string cfg_batteryColor: ""
    property string cfg_nameColor: ""
    property string cfg_statusColor: ""
    property bool cfg_infoStatusTop: false

    // ── Per-role font pickers (native font dialog) ───────────────────────────
    function fontFamily(role) {
        if (role === "battery") return cfg_batteryFont
        return role === "name" ? cfg_nameFont : cfg_statusFont
    }
    function fontSize(role) {
        if (role === "battery") return cfg_batteryFontSize
        return role === "name" ? cfg_nameFontSize : cfg_statusFontSize
    }
    function fontSummary(role) {
        const f = fontFamily(role)
        const s = fontSize(role)
        if (f === "" && s <= 0)
            return "System default"
        return (f === "" ? "Panel font" : f) + (s > 0 ? "  " + s : "")
    }
    function fontColor(role) {
        if (role === "battery") return cfg_batteryColor
        return role === "name" ? cfg_nameColor : cfg_statusColor
    }
    function fontCustomised(role) {
        return fontFamily(role) !== "" || fontSize(role) > 0
               || fontColor(role) !== ""
    }
    function openFontDialog(role) {
        fontDialog.role = role
        // Qt6 FontDialog: the writable initial font is "selectedFont"
        // (assigning "font" fails and aborts before open()).
        fontDialog.selectedFont = Qt.font({
            family: fontFamily(role) === ""
                    ? Kirigami.Theme.defaultFont.family : fontFamily(role),
            pointSize: fontSize(role) > 0
                       ? fontSize(role) : Kirigami.Theme.defaultFont.pointSize
        })
        fontDialog.open()
    }
    function resetFont(role) {
        if (role === "battery") {
            cfg_batteryFont = ""; cfg_batteryFontSize = 0; cfg_batteryColor = ""
        } else if (role === "name") {
            cfg_nameFont = ""; cfg_nameFontSize = 0; cfg_nameColor = ""
        } else {
            cfg_statusFont = ""; cfg_statusFontSize = 0; cfg_statusColor = ""
        }
    }
    function openColorDialog(role) {
        colorDialog.role = role
        colorDialog.selectedColor = fontColor(role) !== ""
                                    ? fontColor(role)
                                    : Kirigami.Theme.textColor
        colorDialog.open()
    }

    // ── Tray pieces: drag-to-reorder model ───────────────────────────────────
    readonly property var pieceLabels: ({
        icon: "Device icon", info: "Name & status", battery: "Battery"
    })
    ListModel { id: orderModel }

    function loadOrder() {
        orderModel.clear()
        const raw = String(cfg_trayOrder || "").split(",")
        for (const t of raw) {
            const k = t.trim()
            if (pieceLabels[k])
                orderModel.append({ key: k, label: pieceLabels[k] })
        }
        // Every piece must exist exactly once.
        for (const k of ["icon", "info", "battery"]) {
            var found = false
            for (var i = 0; i < orderModel.count; ++i)
                if (orderModel.get(i).key === k)
                    found = true
            if (!found)
                orderModel.append({ key: k, label: pieceLabels[k] })
        }
    }

    function publishOrder() {
        var parts = []
        for (var i = 0; i < orderModel.count; ++i)
            parts.push(orderModel.get(i).key)
        cfg_trayOrder = parts.join(",")
    }

    Component.onCompleted: loadOrder()

    // Curated headset glyphs from the icon theme; anything else the user
    // picks through the icon dialog counts as "custom".
    readonly property var presetIcons: [
        "audio-headset-symbolic", "audio-headphones-symbolic",
        "audio-headset-bluetooth", "audio-headphones-bluetooth",
        "audio-headset", "audio-headphones"
    ]
    readonly property bool customIcon: cfg_icon !== "auto" && cfg_icon !== "product"
                                       && presetIcons.indexOf(cfg_icon) === -1

    // Scrollable so a short dialog never clips the form.
    QQC2.ScrollView {
        id: scroller
        anchors.fill: parent
        anchors.margins: pad
        anchors.topMargin: pad * 2   // extra air below the dialog title bar
        clip: true
        contentWidth: availableWidth
        contentHeight: form.implicitHeight

    Kirigami.FormLayout {
        id: form
        width: scroller.availableWidth

        QQC2.ComboBox {
            id: layoutCombo
            Kirigami.FormData.label: "Tray layout:"
            Layout.fillWidth: true
            model: [
                { key: "auto", label: "Automatic (fit available space)" },
                { key: "icon", label: "Icon only" },
                { key: "compact", label: "Icon + battery percentage" },
                { key: "wide", label: "Wide — product image, name and battery" }
            ]
            textRole: "label"
            valueRole: "key"
            // Math.max: an unknown persisted value must not leave a blank combo.
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_trayLayout))
            onActivated: page.cfg_trayLayout = currentValue
        }

        QQC2.Label {
            Layout.fillWidth: true
            // Without a clamped preferred width the label reports its
            // unwrapped text width as the layout hint, overflows the form
            // and gets clipped by the dialog (the page is not stretched to
            // the dialog width).
            Layout.preferredWidth: 1
            Layout.maximumWidth: form.width
            wrapMode: Text.WordWrap
            text: "Automatic picks the widest tray layout that fits the free panel "
                  + "space when the widget loads. The panel reserves the tray cell "
                  + "width at load, so an explicit choice changes the content at "
                  + "once but the cell width on the next panel reload."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
        }

        // ── Tray icon: presets, custom chooser, automatic ───────────────────
        // Buttons use the built-in text/icon properties (not a custom
        // contentItem) so AbstractButton sizes them to their label and the
        // text never overflows the button. Flow wraps them onto a second
        // line when the dialog is narrow.
        Flow {
            Kirigami.FormData.label: "Tray icon:"
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: page.presetIcons
                delegate: QQC2.ToolButton {
                    checkable: true
                    checked: page.cfg_icon === modelData
                    onClicked: page.cfg_icon = modelData
                    display: QQC2.AbstractButton.IconOnly
                    icon.name: modelData
                    icon.width: Kirigami.Units.iconSizes.medium
                    icon.height: Kirigami.Units.iconSizes.medium
                    QQC2.ToolTip {
                        text: modelData
                        visible: parent.hovered
                        delay: Kirigami.Units.toolTipDelay
                    }
                }
            }

            // The connected device's product render (whichever headphones are
            // paired); previewed here with the XM6 render.
            QQC2.ToolButton {
                checkable: true
                checked: page.cfg_icon === "product"
                onClicked: page.cfg_icon = "product"
                display: QQC2.AbstractButton.IconOnly
                icon.source: Qt.resolvedUrl("images/wh-1000xm6.webp")
                icon.width: Kirigami.Units.iconSizes.medium
                icon.height: Kirigami.Units.iconSizes.medium
                QQC2.ToolTip {
                    text: "Product image of the connected headphones"
                    visible: parent.hovered
                    delay: Kirigami.Units.toolTipDelay
                }
            }

            QQC2.ToolButton {
                id: customButton
                checkable: true
                checked: page.customIcon
                onClicked: iconDialog.open()
                text: "Custom…"
                display: page.customIcon
                         ? QQC2.AbstractButton.TextBesideIcon
                         : QQC2.AbstractButton.TextOnly
                icon.name: page.customIcon ? page.cfg_icon : "none"
                icon.width: Kirigami.Units.iconSizes.small
                icon.height: Kirigami.Units.iconSizes.small
                QQC2.ToolTip {
                    text: "Pick any icon from the system theme"
                    visible: parent.hovered
                    delay: Kirigami.Units.toolTipDelay
                }
            }

            QQC2.ToolButton {
                checkable: true
                checked: page.cfg_icon === "auto"
                onClicked: page.cfg_icon = "auto"
                text: "Automatic"
                QQC2.ToolTip {
                    text: "Headset glyph (symbolic in the panel)"
                    visible: parent.hovered
                    delay: Kirigami.Units.toolTipDelay
                }
            }
        }

        // ── Battery readout ──────────────────────────────────────────────────
        QQC2.ComboBox {
            Kirigami.FormData.label: "Battery display:"
            Layout.fillWidth: true
            id: displayCombo
            model: [
                { key: "text", label: "Percentage text (78%)" },
                { key: "icon", label: "Battery icon" },
                { key: "both", label: "Icon + percentage" }
            ]
            textRole: "label"
            valueRole: "key"
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_batteryDisplay))
            onActivated: page.cfg_batteryDisplay = currentValue
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Battery icon side:"
            Layout.fillWidth: true
            enabled: displayCombo.currentValue === "both"
            model: [
                { key: "left", label: "Icon left of the percentage" },
                { key: "right", label: "Icon right of the percentage" }
            ]
            textRole: "label"
            valueRole: "key"
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_batteryGlyphSide))
            onActivated: page.cfg_batteryGlyphSide = currentValue
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: "Battery placement:"
            text: "Badge the battery on the headset icon"
            checked: page.cfg_batteryOverlay
            onToggled: page.cfg_batteryOverlay = checked
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: "Info lines:"
            text: "Status line above the device name"
            checked: page.cfg_infoStatusTop
            onToggled: page.cfg_infoStatusTop = checked
        }

        // Drag the chips to arrange the tray pieces left to right.
        RowLayout {
            Kirigami.FormData.label: "Tray pieces:"
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            ListView {
                id: orderList
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                orientation: ListView.Horizontal
                spacing: Kirigami.Units.smallSpacing
                boundsBehavior: Flickable.StopAtBounds
                interactive: false
                model: orderModel
                enabled: !page.cfg_batteryOverlay
                opacity: enabled ? 1.0 : 0.4

                delegate: Rectangle {
                    id: chip
                    required property int index
                    required property string label

                    width: chipLabel.implicitWidth + Kirigami.Units.largeSpacing * 2
                    height: 34
                    radius: 8
                    border.width: 1
                    border.color: Kirigami.Theme.disabledTextColor
                    color: chipMa.pressed
                           ? Qt.alpha(Kirigami.Theme.highlightColor, 0.35)
                           : Qt.alpha(Kirigami.Theme.textColor, 0.08)
                    z: chipMa.pressed ? 2 : 1
                    // No Behavior on x here: it would also animate the
                    // ListView's own layout moves and make fast drags
                    // overlap chips. Release snaps instantly.

                    QQC2.Label {
                        id: chipLabel
                        anchors.centerIn: parent
                        text: chip.label
                        font.pixelSize: 11
                    }

                    MouseArea {
                        id: chipMa
                        anchors.fill: parent
                        drag.target: parent
                        drag.axis: Drag.XAxis
                        drag.threshold: 4
                        cursorShape: Qt.PointingHandCursor
                        // No model changes mid-drag (that is what makes
                        // list-view reordering janky): the chip lifts over
                        // its neighbours, and on release it moves to the
                        // slot its centre landed in and snaps into place.
                        onReleased: {
                            const centre = parent.x + parent.width / 2
                            let target = orderModel.count - 1
                            for (let i = 0; i < orderList.count; ++i) {
                                const it = orderList.itemAtIndex(i)
                                if (it && it !== parent
                                        && centre < it.x + it.width / 2) {
                                    target = i
                                    break
                                }
                            }
                            if (target !== parent.index)
                                orderModel.move(parent.index, target, 1)
                            parent.x = 0
                            page.publishOrder()
                        }
                        onCanceled: parent.x = 0
                    }
                }
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            // Without a clamped preferred width the label reports its
            // unwrapped text width as the layout hint, overflows the form
            // and gets clipped by the dialog (the page is not stretched to
            // the dialog width).
            Layout.preferredWidth: 1
            Layout.maximumWidth: form.width
            wrapMode: Text.WordWrap
            text: "Drag the chips to arrange the tray pieces left to right "
                  + "(Name & status only shows in the wide layout). The "
                  + "battery badge rides on the headset icon's corner, so it "
                  + "costs no extra panel width and also works in the "
                  + "icon-only layout. The panel reserves the tray cell "
                  + "width at load, so changes resize the cell on the next "
                  + "panel reload."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
        }

        // ── Text fonts: native font dialog per tray text role ────────────────
        Repeater {
            model: [
                { role: "battery", label: "Battery font:" },
                { role: "name", label: "Name font:" },
                { role: "status", label: "Status font:" }
            ]

            delegate: RowLayout {
                required property var modelData
                Kirigami.FormData.label: modelData.label
                spacing: Kirigami.Units.smallSpacing

                // Colour swatch opening the native colour dialog.
                QQC2.Button {
                    Layout.preferredWidth: 34
                    Layout.preferredHeight: 30
                    onClicked: page.openColorDialog(modelData.role)
                    contentItem: Rectangle {
                        radius: 4
                        border.width: 1
                        border.color: Kirigami.Theme.disabledTextColor
                        // No custom colour: show the theme text colour with
                        // a diagonal slash to mark "default".
                        color: page.fontColor(modelData.role) !== ""
                               ? page.fontColor(modelData.role)
                               : Kirigami.Theme.textColor
                        Canvas {
                            anchors.fill: parent
                            visible: page.fontColor(modelData.role) === ""
                            // Repaint whenever the custom colour toggles.
                            property bool custom: page.fontColor(modelData.role) !== ""
                            onCustomChanged: requestPaint()
                            onPaint: {
                                const c = getContext("2d")
                                c.clearRect(0, 0, width, height)
                                c.strokeStyle = Kirigami.Theme.disabledTextColor
                                c.lineWidth = 1
                                c.moveTo(2, height - 3)
                                c.lineTo(width - 3, 2)
                                c.stroke()
                            }
                        }
                    }
                    QQC2.ToolTip {
                        text: "Text colour"
                        visible: parent.hovered
                        delay: Kirigami.Units.toolTipDelay
                    }
                }
                QQC2.Button {
                    text: page.fontSummary(modelData.role)
                    onClicked: page.openFontDialog(modelData.role)
                }
                QQC2.ToolButton {
                    icon.name: "edit-undo-symbolic"
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 30
                    visible: page.fontCustomised(modelData.role)
                    QQC2.ToolTip {
                        text: "Reset to the panel default"
                        visible: parent.hovered
                        delay: Kirigami.Units.toolTipDelay
                    }
                    onClicked: page.resetFont(modelData.role)
                }
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            // Without a clamped preferred width the label reports its
            // unwrapped text width as the layout hint, overflows the form
            // and gets clipped by the dialog (the page is not stretched to
            // the dialog width).
            Layout.preferredWidth: 1
            Layout.maximumWidth: form.width
            wrapMode: Text.WordWrap
            text: "Pick colour, font and size for each piece of tray text "
                  + "using the native dialogs; the reset arrow restores the "
                  + "panel defaults. Applies live to the tray cell."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
        }
    }   // Kirigami.FormLayout
    }   // ScrollView

    KIconThemes.IconDialog {
        id: iconDialog
        onIconNameChanged: {
            if (iconName)
                page.cfg_icon = iconName
        }
    }

    FontDialog {
        id: fontDialog
        title: "Choose Font"
        property string role: ""
        onAccepted: {
            if (role === "battery") {
                page.cfg_batteryFont = selectedFont.family
                page.cfg_batteryFontSize = Math.round(selectedFont.pointSize)
            } else if (role === "name") {
                page.cfg_nameFont = selectedFont.family
                page.cfg_nameFontSize = Math.round(selectedFont.pointSize)
            } else {
                page.cfg_statusFont = selectedFont.family
                page.cfg_statusFontSize = Math.round(selectedFont.pointSize)
            }
        }
    }

    ColorDialog {
        id: colorDialog
        title: "Choose Text Colour"
        options: ColorDialog.NoAlpha
        property string role: ""
        onAccepted: {
            // Store plain hex so the KConfig value stays portable.
            const hex = selectedColor.toString()
            if (role === "battery")
                page.cfg_batteryColor = hex
            else if (role === "name")
                page.cfg_nameColor = hex
            else
                page.cfg_statusColor = hex
        }
    }
}
