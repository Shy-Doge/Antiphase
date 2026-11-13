import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.iconthemes as KIconThemes
import org.kde.kirigami as Kirigami

// The config framework binds the cfg_* properties on this root object.
// Kirigami.FormLayout exposes no margins of its own, so padding is applied
// by anchoring it inside this Item with margins.
Item {
    id: page

    readonly property int pad: Kirigami.Units.largeSpacing
    implicitWidth: form.implicitWidth + pad * 2
    implicitHeight: form.implicitHeight + pad * 2

    // Provided by the Plasma config framework (bound to the KConfigXT keys).
    property string cfg_trayLayout: "auto"
    property string cfg_detailLayout: "auto"
    property string cfg_icon: "auto"
    property string cfg_batteryDisplay: "text"
    property string cfg_batteryPosition: "right"
    property string cfg_batteryFont: ""
    property int cfg_batteryFontSize: 0

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
            wrapMode: Text.WordWrap
            text: "Automatic picks the widest tray layout that fits the free panel "
                  + "space when the widget loads. The panel reserves the tray cell "
                  + "width at load, so an explicit choice changes the content at "
                  + "once but the cell width on the next panel reload."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
        }

        QQC2.ComboBox {
            id: detailCombo
            Kirigami.FormData.label: "Detail header:"
            model: [
                { key: "auto", label: "Automatic (side by side when wide)" },
                { key: "stacked", label: "Stacked — image on top, info below" },
                { key: "side", label: "Side by side — image left, info right" }
            ]
            textRole: "label"
            valueRole: "key"
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_detailLayout))
            onActivated: page.cfg_detailLayout = currentValue
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Layout of the product image, name and battery at the top of the "
                  + "popup. Automatic widens the popup on large screens; the other "
                  + "two force it. Applies the next time the popup opens."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
        }

        // ── Tray icon: presets, custom chooser, automatic ───────────────────
        // Buttons use the built-in text/icon properties (not a custom
        // contentItem) so AbstractButton sizes them to their label and the
        // text never overflows the button.
        RowLayout {
            Kirigami.FormData.label: "Tray icon:"
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
            model: [
                { key: "text", label: "Percentage text (78%)" },
                { key: "icon", label: "Battery icon" }
            ]
            textRole: "label"
            valueRole: "key"
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_batteryDisplay))
            onActivated: page.cfg_batteryDisplay = currentValue
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Battery position:"
            model: [
                { key: "right", label: "Right of the icon" },
                { key: "left", label: "Left of the icon" },
                { key: "overlay", label: "Overlay badge on the icon" }
            ]
            textRole: "label"
            valueRole: "key"
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_batteryPosition))
            onActivated: page.cfg_batteryPosition = currentValue
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "The overlay badge rides on the headset icon's bottom-right corner, "
                  + "so it costs no extra panel width and also works in the "
                  + "icon-only layout. The panel reserves the tray cell width at "
                  + "load, so display and position changes resize the cell on the "
                  + "next panel reload."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
        }

        QQC2.TextField {
            id: fontField
            Kirigami.FormData.label: "Battery font:"
            Layout.fillWidth: true
            placeholderText: "System default"
            text: page.cfg_batteryFont
            onEditingFinished: page.cfg_batteryFont = text.trim()
        }

        QQC2.SpinBox {
            Kirigami.FormData.label: "Battery font size:"
            from: 0
            to: 32
            value: page.cfg_batteryFontSize
            onValueModified: page.cfg_batteryFontSize = value
            QQC2.ToolTip {
                text: "Pixel size for the battery text; 0 keeps the panel default"
                visible: parent.hovered
                delay: Kirigami.Units.toolTipDelay
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Font family and size apply to the battery text (any font "
                  + "installed on the system; leave the family empty for the "
                  + "panel default). Applies live to the tray cell."
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
}
