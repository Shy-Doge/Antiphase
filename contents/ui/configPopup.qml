import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

// Widget page: the popup itself (the panel cell lives in configTray.qml;
// contents/config/config.qml wires both into the dialog).
// The config framework binds the cfg_* properties on this root object.
Item {
    id: page

    readonly property int pad: Kirigami.Units.largeSpacing
    // The Plasma config dialog caps its width; a wider page would clip its
    // controls off-screen, so cap the request and let the controls fill.
    implicitWidth: Math.min(form.implicitWidth + pad * 2, 460)
    implicitHeight: form.implicitHeight + pad * 2

    // Provided by the Plasma config framework (bound to the KConfigXT keys).
    property string cfg_detailLayout: "auto"

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
            id: detailCombo
            Kirigami.FormData.label: "Detail header:"
            Layout.fillWidth: true
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
            // Without a clamped preferred width the label reports its
            // unwrapped text width as the layout hint, overflows the form
            // and gets clipped by the dialog (the page is not stretched to
            // the dialog width).
            Layout.preferredWidth: 1
            Layout.maximumWidth: form.width
            wrapMode: Text.WordWrap
            text: "Layout of the product image, name and battery at the top of "
                  + "the popup. Automatic widens the popup on large screens; "
                  + "the other two force it. Applies the next time the popup "
                  + "opens."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.disabledTextColor
        }
    }   // Kirigami.FormLayout
    }   // ScrollView
}
