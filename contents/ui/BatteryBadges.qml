/**
 * Antiphase — battery badge row
 *
 * L/R/case badges for dual-battery models, a single battery icon +
 * percentage otherwise. Used by the detail header in both its vertical
 * (narrow) and horizontal (wide) arrangements.
 */

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid

RowLayout {
    id: root
    required property PlasmoidItem plasmoidItem
    required property bool dual
    required property string singleIcon   // battery icon name for single-cell

    // The wide header packs the badges into a narrower column.
    property int badgeSize: 21
    property int iconSize: 18
    property int fontPixelSize: 13
    // The device list shows a bare percentage; the detail header spells
    // out "Charging ·".
    property bool showCharging: true
    spacing: 16

    RowLayout {
        spacing: 5
        visible: root.dual && root.plasmoidItem._batteryLeft >= 0
        Rectangle {
            width: root.badgeSize; height: root.badgeSize
            radius: root.badgeSize / 2
            color: Kirigami.Theme.textColor
            PlasmaComponents3.Label {
                anchors.centerIn: parent
                text: "L"; font.pixelSize: Math.max(9, root.badgeSize - 10)
                font.bold: true
                color: Kirigami.Theme.backgroundColor
            }
        }
        PlasmaComponents3.Label {
            text: root.plasmoidItem._batteryLeft + "%"
            font.pixelSize: root.fontPixelSize
        }
    }
    RowLayout {
        spacing: 5
        visible: root.dual && root.plasmoidItem._batteryRight >= 0
        Rectangle {
            width: root.badgeSize; height: root.badgeSize
            radius: root.badgeSize / 2
            color: Kirigami.Theme.negativeTextColor
            PlasmaComponents3.Label {
                anchors.centerIn: parent
                text: "R"; font.pixelSize: Math.max(9, root.badgeSize - 10)
                font.bold: true
                color: "white"
            }
        }
        PlasmaComponents3.Label {
            text: root.plasmoidItem._batteryRight + "%"
            font.pixelSize: root.fontPixelSize
        }
    }
    RowLayout {
        spacing: 5
        visible: root.dual && root.plasmoidItem._batteryCase >= 0
        Kirigami.Icon {
            width: root.iconSize; height: root.iconSize
            source: "battery-100-symbolic"
        }
        PlasmaComponents3.Label {
            text: root.plasmoidItem._batteryCase + "%"
            font.pixelSize: root.fontPixelSize
        }
    }
    RowLayout {
        spacing: 6
        visible: !root.dual
        Kirigami.Icon {
            width: root.iconSize; height: root.iconSize
            source: root.singleIcon
        }
        PlasmaComponents3.Label {
            text: root.plasmoidItem._batteryPercent < 0 ? "—"
                  : root.showCharging && root.plasmoidItem._charging
                  ? "Charging · " + root.plasmoidItem._batteryPercent + "%"
                  : root.plasmoidItem._batteryPercent + "%"
            font.pixelSize: root.fontPixelSize
        }
    }
}
