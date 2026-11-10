/**
 * Antiphase — Full (expanded) representation
 *
 * Two views modeled on the official Sony Headphones Connect Windows flyout:
 *  - "list":   device cards (product render, name, status, battery badges)
 *  - "detail": back arrow, product render, battery, noise-control tiles
 *              (icon in tile, label below), ambient slider, EQ / DSEE rows
 *              and a pinned action bar.
 *
 * Note: no "pragma ComponentBehavior: Bound" — the JS-array models used by
 * the device list and the noise-mode repeater need the unbound delegate
 * context ("modelData" injection).
 */

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

import "modelImages.js" as ModelImages

PlasmaExtras.Representation {
    id: representation

    required property PlasmoidItem plasmoidItem

    // Popup size (Plasma sizes the popup from the representation's implicit size)
    readonly property int compactWidth: 340
    readonly property int wideWidth: 460

    // Detail header arrangement (config "detailLayout"):
    //   auto    — widen the popup on large screens; header flips at 400px
    //   stacked — always vertical (image on top), compact popup
    //   side    — always horizontal (image left), wide popup
    // The offline preview (scripts/preview.py) has no Plasmoid.configuration
    // and forces an arrangement through detailLayoutOverride; inside
    // plasmashell the real config always wins.
    property string detailLayoutOverride: ""
    readonly property string cfgDetail: {
        // Plasmoid.configuration is absent in the offline preview.
        const c = Plasmoid.configuration
        if (c && c.detailLayout)
            return c.detailLayout
        return detailLayoutOverride !== "" ? detailLayoutOverride : "auto"
    }
    implicitWidth: cfgDetail === "side" ? wideWidth
                     : cfgDetail === "stacked" ? compactWidth
                     : (Screen.width >= wideWidth + 100 ? wideWidth : compactWidth)
    implicitHeight: 540
    readonly property bool wideHeader: cfgDetail === "side" ? true
                                         : cfgDetail === "stacked" ? false
                                         : width >= 400

    // ── Presentation helpers ─────────────────────────────────────────────────
    readonly property var _noiseModes: [
        { mode: 0, icon: "dialog-cancel-symbolic", label: "Off" },
        { mode: 1, icon: "player-volume-symbolic", label: "ANC" },
        { mode: 2, icon: "noisereduction-symbolic", label: "Ambient" }
    ]

    // Band sliders are display-only until "Edit" is pressed, so scrolling
    // the popup can never nudge the EQ curve (PC3 sliders eat the wheel).
    property bool _eqEditing: false

    // EQ preset id -> display name. Classic ids (0x10-0x17) plus the MDR
    // (XM6) id table; the XM6 names are inferred from the band shapes the
    // firmware reports for each id. Unknown ids fall back to a raw label.
    readonly property var _eqNameMap: ({
        0x00: "Off",
        0x10: "Bright", 0x11: "Excited", 0x12: "Mellow", 0x13: "Relaxed",
        0x14: "Vocal", 0x15: "Treble Boost", 0x16: "Bass Boost", 0x17: "Speech",
        0x20: "Vocal", 0x30: "Bass Boost", 0x31: "Treble Boost",
        0x32: "Excited", 0x33: "Mellow",
        0xA0: "Custom 1", 0xA1: "Custom 2", 0xA2: "Custom 3"
    })

    // The preset ids the connected device accepts (from its capability
    // reply); classic table as fallback for models that don't report one.
    function eqPresets() {
        var p = plasmoidItem._profile
        if (p && Array.isArray(p.eqPresets) && p.eqPresets.length > 0)
            return p.eqPresets
        return [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0]
    }

    function eqNames() {
        return eqPresets().map(function (v) {
            return representation._eqNameMap[v] || ("Preset 0x" + v.toString(16))
        })
    }

    function eqIndexForValue(value) {
        // -1 for ids the device does not offer: the combo then shows the
        // raw id instead of lying with "Off".
        return eqPresets().indexOf(value)
    }

    // ISO octave band centers reported by the XM6 (GET 5A 04).
    readonly property var _eqFreqs: ["31", "63", "125", "250", "500",
                                     "1k", "2k", "4k", "8k", "16k"]

    // Level steps for the band range (XM6 caps report 13 -> raw 0..12,
    // center 6 shown as +/- dB around 0).
    function eqSteps() {
        var p = plasmoidItem._profile
        return (p && p.eqSteps) ? p.eqSteps : 13
    }

    function eqCenter() { return Math.floor(eqSteps() / 2) }

    // Custom / user presets (A0+) expose an editable band curve.
    function isCustomPreset() { return plasmoidItem._eqPreset >= 0xA0 }

    function eqBandAt(index) {
        var b = plasmoidItem._eqBands
        return (b && b[index] !== undefined) ? b[index] : eqCenter()
    }

    // ── Adaptive Sound Control scenes (Focus / Office / Aware) ─────
    // The device only stores the selection; the audible effect is the
    // scene's NC combination. Scenes are user-editable and persisted
    // by the daemon; _sceneDraft holds the copy while editing.
    property bool _scenesEditing: false
    property var _sceneDraft: []

    readonly property var _sceneModes: ["Off", "Noise cancelling",
                                        "Ambient sound"]
    readonly property var _sceneModeIcons: ["dialog-cancel-symbolic",
                                            "player-volume-symbolic",
                                            "noisereduction-symbolic"]

    function stockScenes() {
        var d = plasmoidItem._sceneDefaults
        if (d && d.length > 0)
            return representation.copyScenes(d)
        return [
            {id: 0x08, name: "Focus",  mode: 1, ambientLevel: 0,  focusOnVoice: false},
            {id: 0x10, name: "Office", mode: 2, ambientLevel: 10, focusOnVoice: false},
            {id: 0x20, name: "Aware",  mode: 2, ambientLevel: 20, focusOnVoice: false}
        ]
    }

    function sceneList() {
        var s = plasmoidItem._scenes
        return (s && s.length > 0) ? s : representation.stockScenes()
    }

    function copyScenes(list) {
        var out = []
        for (var i = 0; i < list.length; i++) {
            var s = list[i]
            out.push({id: s.id, name: s.name, mode: s.mode,
                      ambientLevel: s.ambientLevel,
                      focusOnVoice: s.focusOnVoice === true})
        }
        return out
    }

    function updateSceneField(index, key, value) {
        // Mutate in place and bump the revision. Reassigning the model
        // array would make the Repeater destroy and rebuild every
        // delegate — killing the slider under the pointer mid-drag and
        // the TextField's focus mid-keystroke.
        representation._sceneDraft[index][key] = value
        representation.sceneRev++
    }

    // Bumped on every draft field edit. sceneField() reads it so leaf
    // bindings re-evaluate even though the model identity is stable.
    property int sceneRev: 0

    function sceneField(index, key) {
        representation.sceneRev   // dependency: every edit re-reads
        return representation._sceneDraft[index][key]
    }

    // Active chip: current device state matches the scene's combination.
    function isSceneActive(s) {
        if (!s || plasmoidItem._noiseMode !== s.mode)
            return false
        if (s.mode === 2 && plasmoidItem._ambientLevel !== s.ambientLevel)
            return false
        if ((s.focusOnVoice === true) !== plasmoidItem._focusOnVoice)
            return false
        return true
    }

    function applyScene(s) {
        // A pending debounced ambient write would clobber the scene.
        ambientSendTimer.stop()
        // Optimistic: tiles + slider follow immediately.
        plasmoidItem._noiseMode = s.mode
        if (s.mode === 2)
            plasmoidItem._ambientLevel = s.ambientLevel
        plasmoidItem._focusOnVoice = s.focusOnVoice === true
        plasmoidItem._request("set_asc_scene", {
            address: plasmoidItem._selectedDevice,
            scene: s.id
        })
    }

    function toggleSceneEdit() {
        if (representation._scenesEditing) {
            representation._scenesEditing = false   // Cancel: drop the draft
            return
        }
        representation._sceneDraft = representation.copyScenes(
            representation.sceneList())
        representation._scenesEditing = true
    }

    function saveScenes() {
        plasmoidItem._scenes = representation.copyScenes(
            representation._sceneDraft)
        plasmoidItem._request("set_scenes", {
            scenes: plasmoidItem._scenes
        })
        representation._scenesEditing = false
    }

    function resetScenes() {
        representation._sceneDraft = representation.stockScenes()
    }

    // Custom scenes live entirely in our config; ids from 0x40 up keep
    // them clear of the device's stock SENSE ids (08/10/20). The chip
    // row stays readable, so additions are capped.
    readonly property int maxScenes: 6

    function addScene() {
        var d = representation.copyScenes(representation._sceneDraft)
        if (d.length >= representation.maxScenes)
            return
        var used = {}
        for (var i = 0; i < d.length; i++)
            used[d[i].id] = true
        var id = 0x40
        while (used[id] && id < 0xF0)
            id++
        d.push({id: id, name: "Scene " + (d.length + 1), mode: 1,
                ambientLevel: 0, focusOnVoice: false})
        representation._sceneDraft = d
    }

    function removeScene(index) {
        var d = representation.copyScenes(representation._sceneDraft)
        if (d.length <= 1)
            return
        d.splice(index, 1)
        representation._sceneDraft = d
    }

    // Models with a bundled product render in images/ (shared table in
    // modelImages.js, imported at the top of this file).
    readonly property string _imageSource:
        ModelImages.imageSourceFor(plasmoidItem._modelName || plasmoidItem._deviceName)

    function _sendNoise(mode, level, focus) {
        plasmoidItem._request("set_noise_mode", {
            address: plasmoidItem._selectedDevice,
            mode: mode, ambientLevel: level, focusOnVoice: focus
        })
    }

    // Dragging the ambient slider fires onMoved for every step; each SET
    // blocks the daemon for seconds waiting on the device. Collapse a drag
    // burst into one request.
    Timer {
        id: ambientSendTimer
        interval: 400
        onTriggered: representation._sendNoise(2, plasmoidItem._ambientLevel,
                                               plasmoidItem._focusOnVoice)
    }

    // Dragging a custom EQ band fires per step; collapse a burst into one
    // write of the full 10-band curve.
    Timer {
        id: customEqSendTimer
        interval: 500
        onTriggered: {
            plasmoidItem._request("set_equalizer_custom", {
                address: plasmoidItem._selectedDevice,
                preset: plasmoidItem._eqPreset,
                bands: plasmoidItem._eqBands
            })
        }
    }

    // Leaving edit modes: a preset switch or closing the detail view
    // drops back to display-only sliders and chips.
    Connections {
        target: plasmoidItem
        function on_eqPresetChanged() {
            representation._eqEditing = false
            // A pending band write belongs to the previous preset; sending
            // it after a preset switch would corrupt the newly selected one.
            customEqSendTimer.stop()
        }
        function on_viewChanged() {
            if (plasmoidItem._view !== "detail") {
                representation._eqEditing = false
                representation._scenesEditing = false
            }
        }
    }

    function batteryIcon(pct, charging) {
        var lvl = Math.max(0, Math.min(100, Math.round(pct / 10) * 10))
        var n = ("00" + lvl).slice(-3)
        return "battery-" + n + (charging ? "-charging-symbolic" : "-symbolic")
    }

    // Capability flags from the daemon's device profile. When the profile is
    // not (yet) known we assume the common case: EQ/DSEE present, dual
    // battery absent.
    function hasFeature(name, dflt) {
        var p = plasmoidItem._profile
        return (p && p[name] !== undefined) ? p[name] === true : dflt
    }

    // ── Device list view ─────────────────────────────────────────────────────
    // A bare ListView: it is a Flickable and scrolls natively; wrapping it in
    // a ScrollView collapses its width to zero (contentWidth cycle).
    ListView {
        id: deviceList
        anchors.fill: parent
        visible: plasmoidItem._view !== "detail"
        model: plasmoidItem._devices
        clip: true
        spacing: 10
        topMargin: 12
        bottomMargin: 12
        leftMargin: 12
        rightMargin: 12

            delegate: Rectangle {
                id: card
                required property var modelData
                readonly property bool isSession: modelData.address === plasmoidItem._selectedDevice
                                                  && plasmoidItem._connected
                // availableWidth is undefined on ListView in this Qt build
                width: deviceList.width - 24
                height: 80
                radius: 12
                color: cardMa.pressed ? Qt.alpha(Kirigami.Theme.textColor, 0.14)
                     : cardMa.containsMouse ? Qt.alpha(Kirigami.Theme.textColor, 0.10)
                     : Qt.alpha(Kirigami.Theme.textColor, 0.05)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 12
                    spacing: 10

                    Item {
                        Layout.preferredWidth: 62
                        Layout.preferredHeight: 58
                        Image {
                            id: cardImage
                            anchors.centerIn: parent
                            height: 52
                            width: sourceSize.width > 0 && sourceSize.height > 0
                                   ? Math.min(62, height * sourceSize.width / sourceSize.height)
                                   : 62
                            source: ModelImages.imageSourceFor(modelData.name)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            visible: status === Image.Ready
                        }
                        Kirigami.Icon {
                            anchors.centerIn: parent
                            width: 38; height: 38
                            source: "audio-headphones"
                            visible: cardImage.status !== Image.Ready
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: modelData.name
                            font.pixelSize: 14
                            font.bold: true
                            elide: Text.ElideMiddle
                        }

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: (modelData.connected || card.isSession)
                                  ? "Connected" + (plasmoidItem._codec !== "" && card.isSession
                                                   ? " · " + plasmoidItem._codec : "")
                                  : "Not connected"
                            font.pixelSize: 11
                            color: Kirigami.Theme.disabledTextColor
                            elide: Text.ElideMiddle
                        }

                        // Battery badges — only for the device with a live
                        // Sony session (battery needs the control channel).
                        BatteryBadges {
                            visible: card.isSession
                            plasmoidItem: representation.plasmoidItem
                            dual: representation.hasFeature("dualBattery", false)
                            singleIcon: representation.batteryIcon(
                                representation.plasmoidItem._batteryPercent,
                                representation.plasmoidItem._charging)
                            showCharging: false
                            badgeSize: 19
                            iconSize: 16
                            fontPixelSize: 12
                            spacing: 12
                        }
                    }
                }

                MouseArea {
                    id: cardMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: plasmoidItem._selectDevice(modelData.address,
                                                          modelData.path,
                                                          modelData.name)
                }
            }
    }

    PlasmaComponents3.Label {
        anchors.centerIn: parent
        visible: plasmoidItem._view !== "detail" && plasmoidItem._devices.length === 0
        text: "No paired Bluetooth devices found"
        color: Kirigami.Theme.disabledTextColor
        font.pixelSize: 12
    }

    // ── Device detail view ───────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        visible: plasmoidItem._view === "detail"
        spacing: 0

        // Top bar with back arrow
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            Layout.topMargin: 4
            Layout.preferredHeight: 36

            PlasmaComponents3.ToolButton {
                icon.name: "arrow-left-symbolic"
                flat: true
                onClicked: plasmoidItem._view = "list"
            }
            Item { Layout.fillWidth: true }
        }

        PlasmaComponents3.ScrollView {
            id: detailScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            contentItem: Flickable {
                id: detailFlick
                contentWidth: width
                contentHeight: detailColumn.implicitHeight + 20
                clip: true

                ColumnLayout {
                    id: detailColumn
                    width: detailFlick.width
                    spacing: 12

                    // ── Header: vertical stack, or taskbar-style row when wide ──
                    Item {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        implicitHeight: representation.wideHeader
                                        ? headerRow.implicitHeight
                                        : headerColumn.implicitHeight

                        // Narrow: product render on top, info centered below.
                        ColumnLayout {
                            id: headerColumn
                            anchors.fill: parent
                            visible: !representation.wideHeader
                            spacing: 4

                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 120

                                Image {
                                    id: productImage
                                    anchors.centerIn: parent
                                    height: 118
                                    width: sourceSize.width > 0 && sourceSize.height > 0
                                           ? Math.min(parent.width - 16, height * sourceSize.width / sourceSize.height)
                                           : parent.width - 16
                                    source: representation._imageSource
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    visible: status === Image.Ready
                                }
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    width: 84; height: 84
                                    source: "audio-headphones"
                                    visible: productImage.status !== Image.Ready
                                }
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: plasmoidItem._modelName || plasmoidItem._deviceName || "Sony Headphones"
                                font.pixelSize: 18
                                font.bold: true
                                elide: Text.ElideMiddle
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                visible: !plasmoidItem._connected
                                text: plasmoidItem._connecting ? "Connecting…" : "Not connected"
                                color: Kirigami.Theme.disabledTextColor
                                font.pixelSize: 11
                            }

                            BatteryBadges {
                                Layout.alignment: Qt.AlignHCenter
                                plasmoidItem: representation.plasmoidItem
                                dual: representation.hasFeature("dualBattery", false)
                                singleIcon: representation.batteryIcon(
                                    plasmoidItem._batteryPercent, plasmoidItem._charging)
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                visible: plasmoidItem._codec !== "" || plasmoidItem._dsee
                                text: [plasmoidItem._codec,
                                       plasmoidItem._dsee ? "DSEE Extreme" : ""]
                                      .filter(function (s) { return s !== "" }).join(" · ")
                                color: Kirigami.Theme.disabledTextColor
                                font.pixelSize: 11
                            }
                        }

                        // Wide: product render left, info right — the same
                        // arrangement as the wide taskbar layout.
                        RowLayout {
                            id: headerRow
                            anchors.fill: parent
                            visible: representation.wideHeader
                            spacing: 18

                            Item {
                                Layout.preferredWidth: 140
                                Layout.preferredHeight: 104
                                Layout.alignment: Qt.AlignVCenter

                                Image {
                                    id: productImageWide
                                    anchors.centerIn: parent
                                    height: 102
                                    width: sourceSize.width > 0 && sourceSize.height > 0
                                           ? Math.min(140, height * sourceSize.width / sourceSize.height)
                                           : 140
                                    source: representation._imageSource
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    visible: status === Image.Ready
                                }
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    width: 64; height: 64
                                    source: "audio-headphones"
                                    visible: productImageWide.status !== Image.Ready
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 3

                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    text: plasmoidItem._modelName || plasmoidItem._deviceName || "Sony Headphones"
                                    font.pixelSize: 17
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    visible: !plasmoidItem._connected
                                    text: plasmoidItem._connecting ? "Connecting…" : "Not connected"
                                    color: Kirigami.Theme.disabledTextColor
                                    font.pixelSize: 11
                                }

                                BatteryBadges {
                                    plasmoidItem: representation.plasmoidItem
                                    dual: representation.hasFeature("dualBattery", false)
                                    singleIcon: representation.batteryIcon(
                                        plasmoidItem._batteryPercent, plasmoidItem._charging)
                                    badgeSize: 19
                                    iconSize: 16
                                    fontPixelSize: 12
                                }

                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    visible: plasmoidItem._codec !== "" || plasmoidItem._dsee
                                    text: [plasmoidItem._codec,
                                           plasmoidItem._dsee ? "DSEE Extreme" : ""]
                                          .filter(function (s) { return s !== "" }).join(" · ")
                                    color: Kirigami.Theme.disabledTextColor
                                    font.pixelSize: 11
                                }
                            }
                        }
                    }

                    // ── Noise control ───────────────────────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        spacing: 8

                        Kirigami.Separator { Layout.fillWidth: true }

                        PlasmaComponents3.Label {
                            text: "Noise control"
                            font.pixelSize: 13
                            font.bold: true
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Repeater {
                                model: representation._noiseModes

                                delegate: Item {
                                    id: noiseTile
                                    required property var modelData
                                    readonly property bool selected: plasmoidItem._noiseMode === modelData.mode

                                    Layout.fillWidth: true
                                    implicitHeight: tileRect.height + 6 + tileLabel.implicitHeight

                                    ColumnLayout {
                                        anchors.fill: parent
                                        spacing: 6

                                        Rectangle {
                                            id: tileRect
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 54
                                            radius: 10
                                            color: noiseTile.selected
                                                   ? Kirigami.Theme.highlightColor
                                                   : ma.pressed ? Qt.alpha(Kirigami.Theme.textColor, 0.18)
                                                   : ma.containsMouse ? Qt.alpha(Kirigami.Theme.textColor, 0.12)
                                                   : Qt.alpha(Kirigami.Theme.textColor, 0.06)

                                            Kirigami.Icon {
                                                anchors.centerIn: parent
                                                width: 24; height: 24
                                                source: noiseTile.modelData.icon
                                                color: noiseTile.selected
                                                       ? Kirigami.Theme.highlightedTextColor
                                                       : Kirigami.Theme.textColor
                                            }
                                        }

                                        PlasmaComponents3.Label {
                                            id: tileLabel
                                            Layout.alignment: Qt.AlignHCenter
                                            text: noiseTile.modelData.label
                                            font.pixelSize: 12
                                            color: Kirigami.Theme.textColor
                                        }
                                    }

                                    MouseArea {
                                        id: ma
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            // Optimistic: reflect the choice
                                            // immediately; the device confirms
                                            // asynchronously. A pending
                                            // debounced ambient write would
                                            // race this mode change.
                                            ambientSendTimer.stop()
                                            // The device may hold level 0 from
                                            // a non-ambient mode; the slider
                                            // starts at 1, so send 1 too and
                                            // keep the model in step.
                                            if (noiseTile.modelData.mode === 2
                                                    && plasmoidItem._ambientLevel < 1)
                                                plasmoidItem._ambientLevel = 1
                                            plasmoidItem._noiseMode = noiseTile.modelData.mode
                                            representation._sendNoise(
                                                noiseTile.modelData.mode,
                                                noiseTile.modelData.mode === 2
                                                    ? plasmoidItem._ambientLevel : 0,
                                                plasmoidItem._focusOnVoice)
                                        }
                                    }
                                }
                            }
                        }

                        // Ambient sound extras
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            visible: plasmoidItem._noiseMode === 2

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                PlasmaComponents3.Label {
                                    text: "Ambient level"
                                    font.pixelSize: 12
                                    color: Kirigami.Theme.disabledTextColor
                                }
                                Item { Layout.fillWidth: true }
                                PlasmaComponents3.Label {
                                    text: plasmoidItem._ambientLevel
                                    font.pixelSize: 12
                                    color: Kirigami.Theme.disabledTextColor
                                }
                            }

                            PlasmaComponents3.Slider {
                                id: ambientSlider
                                Layout.fillWidth: true
                                from: 1
                                to: 20
                                stepSize: 1
                                value: plasmoidItem._ambientLevel
                                // Dragging breaks the inline binding; restore
                                // it after release so refreshes propagate again.
                                Binding {
                                    target: ambientSlider
                                    property: "value"
                                    value: plasmoidItem._ambientLevel
                                    when: !ambientSlider.pressed
                                    restoreMode: Binding.RestoreBindingOrValue
                                }
                                onMoved: {
                                    plasmoidItem._ambientLevel = Math.round(value)
                                    ambientSendTimer.restart()
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents3.Label {
                                    text: "Focus on voice"
                                    Layout.fillWidth: true
                                }
                                PlasmaComponents3.Switch {
                                    id: focusVoiceSwitch
                                    checked: plasmoidItem._focusOnVoice
                                    Binding {
                                        target: focusVoiceSwitch
                                        property: "checked"
                                        value: plasmoidItem._focusOnVoice
                                        when: !focusVoiceSwitch.down
                                        restoreMode: Binding.RestoreBindingOrValue
                                    }
                                    onToggled: {
                                        ambientSendTimer.stop()
                                        plasmoidItem._focusOnVoice = checked
                                        plasmoidItem._request("set_noise_mode", {
                                            address: plasmoidItem._selectedDevice,
                                            mode: 2,
                                            ambientLevel: plasmoidItem._ambientLevel,
                                            focusOnVoice: checked
                                        })
                                    }
                                }
                            }
                        }
                    }

                    // ── Scenes (Adaptive Sound Control) ─────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        spacing: 8
                        visible: representation.hasFeature("asc", false)
                                 && representation.sceneList().length > 0

                        Kirigami.Separator { Layout.fillWidth: true }

                        RowLayout {
                            Layout.fillWidth: true
                            PlasmaComponents3.Label {
                                text: "Scenes"
                                font.pixelSize: 13
                                font.bold: true
                            }
                            Item { Layout.fillWidth: true }
                            PlasmaComponents3.Button {
                                text: representation._scenesEditing ? "Cancel" : "Edit"
                                flat: true
                                font.pixelSize: 11
                                Layout.preferredHeight: 26
                                onClicked: representation.toggleSceneEdit()
                            }
                        }

                        // Quick scene chips (hidden while editing)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            visible: !representation._scenesEditing

                            Repeater {
                                model: representation.sceneList()

                                delegate: PlasmaComponents3.Button {
                                    id: sceneChip
                                    required property var modelData

                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 30
                                    checkable: true
                                    checked: representation.isSceneActive(modelData)
                                    // Clicking toggles `checked` imperatively
                                    // and destroys the binding; re-tie it so
                                    // device-state refreshes move the chips.
                                    Binding {
                                        target: sceneChip
                                        property: "checked"
                                        value: representation.isSceneActive(sceneChip.modelData)
                                        when: !sceneChip.down
                                        restoreMode: Binding.RestoreBindingOrValue
                                    }
                                    text: modelData.name
                                    font.pixelSize: 12
                                    onClicked: representation.applyScene(modelData)
                                }
                            }
                        }

                        // Scene editor
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            visible: representation._scenesEditing

                            Repeater {
                                model: representation._sceneDraft

                                delegate: ColumnLayout {
                                    required property int index
                                    // Leaf reads go through sceneField() so
                                    // they follow sceneRev without the model
                                    // (and thus the delegates) changing.
                                    readonly property int mode:
                                        representation.sceneField(index, "mode")
                                    readonly property string name:
                                        representation.sceneField(index, "name")
                                    readonly property bool focusVoice:
                                        representation.sceneField(index, "focusOnVoice")
                                    readonly property int level:
                                        representation.sceneField(index, "ambientLevel")

                                    Layout.fillWidth: true
                                    spacing: 4

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: sceneCard.implicitHeight + 16
                                        radius: 10
                                        color: Qt.alpha(Kirigami.Theme.textColor, 0.06)

                                        ColumnLayout {
                                            id: sceneCard
                                            anchors.fill: parent
                                            anchors.margins: 10
                                            spacing: 6

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 8

                                                Kirigami.Icon {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    width: 20; height: 20
                                                    source: representation._sceneModeIcons[mode]
                                                }

                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 2
                                                    PlasmaComponents3.Label {
                                                        text: "Name"
                                                        font.pixelSize: 10
                                                        color: Kirigami.Theme.disabledTextColor
                                                    }
                                                    PlasmaComponents3.TextField {
                                                        id: sceneNameField
                                                        Layout.fillWidth: true
                                                        text: name
                                                        font.pixelSize: 11
                                                        // Re-sync from the draft
                                                        // only while unfocused, so
                                                        // unrelated edits cannot
                                                        // clobber mid-typing text.
                                                        Binding {
                                                            target: sceneNameField
                                                            property: "text"
                                                            value: name
                                                            when: !sceneNameField.activeFocus
                                                            restoreMode: Binding.RestoreBindingOrValue
                                                        }
                                                        onEditingFinished: representation.updateSceneField(
                                                            index, "name", text)
                                                    }
                                                }

                                                ColumnLayout {
                                                    spacing: 2
                                                    PlasmaComponents3.Label {
                                                        text: "Focus on voice"
                                                        font.pixelSize: 10
                                                        color: Kirigami.Theme.disabledTextColor
                                                    }
                                                    PlasmaComponents3.Switch {
                                                        Layout.alignment: Qt.AlignHCenter
                                                        checked: focusVoice
                                                        onToggled: representation.updateSceneField(
                                                            index, "focusOnVoice", checked)
                                                    }
                                                }

                                                // Remove this scene (draft
                                                // only until Save)
                                                PlasmaComponents3.Button {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    flat: true
                                                    icon.name: "list-remove-symbolic"
                                                    Layout.preferredWidth: 28
                                                    Layout.preferredHeight: 28
                                                    enabled: representation._sceneDraft.length > 1
                                                    PlasmaComponents3.ToolTip {
                                                        text: "Remove scene"
                                                    }
                                                    onClicked: representation.removeScene(index)
                                                }
                                            }

                                            RowLayout {
                                                Layout.fillWidth: true
                                                PlasmaComponents3.Label {
                                                    text: "Noise control"
                                                    font.pixelSize: 10
                                                    color: Kirigami.Theme.disabledTextColor
                                                }
                                                PlasmaComponents3.ComboBox {
                                                    id: sceneModeCombo
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: 28
                                                    model: representation._sceneModes
                                                    currentIndex: mode
                                                    Binding {
                                                        target: sceneModeCombo
                                                        property: "currentIndex"
                                                        value: mode
                                                        when: !sceneModeCombo.down
                                                        restoreMode: Binding.RestoreBindingOrValue
                                                    }
                                                    wheelEnabled: false
                                                    onActivated: function(idx) {
                                                        representation.updateSceneField(index, "mode", idx)
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Ambient level lives under the card, like
                                    // the official editor.
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: 4
                                        Layout.rightMargin: 4
                                        spacing: 0
                                        visible: mode === 2

                                        RowLayout {
                                            Layout.fillWidth: true
                                            PlasmaComponents3.Label {
                                                text: "Ambient sound level"
                                                font.pixelSize: 11
                                            }
                                            Item { Layout.fillWidth: true }
                                            PlasmaComponents3.Label {
                                                text: level
                                                font.pixelSize: 11
                                            }
                                        }
                                        PlasmaComponents3.Slider {
                                            id: sceneLevelSlider
                                            Layout.fillWidth: true
                                            from: 1
                                            to: 20
                                            stepSize: 1
                                            value: level
                                            Binding {
                                                target: sceneLevelSlider
                                                property: "value"
                                                value: level
                                                when: !sceneLevelSlider.pressed
                                                restoreMode: Binding.RestoreBindingOrValue
                                            }
                                            onMoved: representation.updateSceneField(
                                                index, "ambientLevel", Math.round(value))
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents3.Button {
                                    text: "Add scene"
                                    font.pixelSize: 11
                                    enabled: representation._sceneDraft.length
                                             < representation.maxScenes
                                    onClicked: representation.addScene()
                                }
                                Item { Layout.fillWidth: true }
                                PlasmaComponents3.Button {
                                    text: "Reset to defaults"
                                    font.pixelSize: 11
                                    onClicked: representation.resetScenes()
                                }
                                PlasmaComponents3.Button {
                                    text: "Save scenes"
                                    font.pixelSize: 11
                                    highlighted: true
                                    onClicked: representation.saveScenes()
                                }
                            }
                        }
                    }

                    // ── Sound section ───────────────────────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        spacing: 10

                        Kirigami.Separator { Layout.fillWidth: true }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            visible: representation.hasFeature("eq", true)

                            PlasmaComponents3.Label {
                                text: "Equalizer"
                                Layout.fillWidth: true
                            }
                            PlasmaComponents3.ComboBox {
                                id: eqCombo
                                Layout.preferredWidth: 160
                                wheelEnabled: false
                                model: representation.eqNames()
                                currentIndex: representation.eqIndexForValue(plasmoidItem._eqPreset)
                                // Unknown id: show it raw rather than the
                                // blank a -1 index would render as.
                                displayText: currentIndex >= 0
                                             ? currentText
                                             : "Preset 0x" + plasmoidItem._eqPreset.toString(16)
                                Binding {
                                    target: eqCombo
                                    property: "currentIndex"
                                    value: representation.eqIndexForValue(plasmoidItem._eqPreset)
                                    when: !eqCombo.down
                                    restoreMode: Binding.RestoreBindingOrValue
                                }
                                onActivated: function(index) {
                                    // Bands dragged on the old preset must not
                                    // be written onto the newly chosen one.
                                    customEqSendTimer.stop()
                                    var preset = representation.eqPresets()[index]
                                    plasmoidItem._eqPreset = preset
                                    plasmoidItem._request("set_equalizer_preset", {
                                        address: plasmoidItem._selectedDevice,
                                        preset: preset
                                    })
                                }
                            }
                        }

                        // DSEE upscaling toggle
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            visible: representation.hasFeature("dsee", true)

                            PlasmaComponents3.Label {
                                text: "DSEE Extreme"
                                Layout.fillWidth: true
                            }
                            PlasmaComponents3.Switch {
                                id: dseeSwitch
                                checked: plasmoidItem._dsee
                                Binding {
                                    target: dseeSwitch
                                    property: "checked"
                                    value: plasmoidItem._dsee
                                    when: !dseeSwitch.down
                                    restoreMode: Binding.RestoreBindingOrValue
                                }
                                onToggled: {
                                    plasmoidItem._dsee = checked
                                    plasmoidItem._request("set_dsee", {
                                        address: plasmoidItem._selectedDevice,
                                        enabled: checked
                                    })
                                }
                            }
                        }

                        // Editable curve for custom presets (A0+)
                        ColumnLayout {
                            id: bandEditor
                            Layout.fillWidth: true
                            spacing: 4
                            visible: representation.hasFeature("eq", true)
                                     && representation.isCustomPreset()
                                     && plasmoidItem._eqBands.length >= 10

                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents3.Label {
                                    text: "Bands"
                                    font.pixelSize: 12
                                    color: Kirigami.Theme.disabledTextColor
                                }
                                Item { Layout.fillWidth: true }
                                PlasmaComponents3.Label {
                                    text: (plasmoidItem._eqPreset >= 0xA0 && plasmoidItem._eqPreset <= 0xA9)
                                          ? "Custom " + (plasmoidItem._eqPreset - 0xA0 + 1) : ""
                                    font.pixelSize: 11
                                    color: Kirigami.Theme.disabledTextColor
                                }
                                PlasmaComponents3.Button {
                                    text: representation._eqEditing ? "Done" : "Edit"
                                    font.pixelSize: 11
                                    Layout.preferredHeight: 26
                                    onClicked: representation._eqEditing = !representation._eqEditing
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 128
                                spacing: 2

                                Repeater {
                                    model: 10

                                    delegate: ColumnLayout {
                                        id: bandColumn
                                        required property int index

                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        spacing: 3

                                        PlasmaComponents3.Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: {
                                                var d = representation.eqBandAt(bandColumn.index)
                                                        - representation.eqCenter()
                                                return (d > 0 ? "+" : "") + d
                                            }
                                            font.pixelSize: 8
                                            color: Kirigami.Theme.disabledTextColor
                                        }

                                        PlasmaComponents3.Slider {
                                            id: bandSlider
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            orientation: Qt.Vertical
                                            from: 0
                                            to: representation.eqSteps() - 1
                                            stepSize: 1
                                            enabled: representation._eqEditing
                                            value: representation.eqBandAt(bandColumn.index)
                                            Binding {
                                                target: bandSlider
                                                property: "value"
                                                value: representation.eqBandAt(bandColumn.index)
                                                when: !bandSlider.pressed
                                                restoreMode: Binding.RestoreBindingOrValue
                                            }
                                            onMoved: {
                                                var b = plasmoidItem._eqBands.slice()
                                                b[bandColumn.index] = Math.round(value)
                                                plasmoidItem._eqBands = b
                                                customEqSendTimer.restart()
                                            }
                                        }

                                        PlasmaComponents3.Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: representation._eqFreqs[bandColumn.index]
                                            font.pixelSize: 8
                                            color: Kirigami.Theme.disabledTextColor
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Item { Layout.preferredHeight: 6 }
                }
            }
        }

        // ── Pinned action bar ────────────────────────────────────────────────
        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            Layout.topMargin: 2
            Layout.bottomMargin: 2

            PlasmaComponents3.ToolButton {
                icon.name: "system-shutdown-symbolic"
                text: "Turn off"
                flat: true
                onClicked: {
                    // The response handler leaves the detail view when
                    // the device actually powers off; a declined command
                    // (unsupported model) keeps the session and the view.
                    plasmoidItem._request("power_off", {address: plasmoidItem._selectedDevice})
                }
            }

            Item { Layout.fillWidth: true }

            PlasmaComponents3.ToolButton {
                icon.name: "view-refresh-symbolic"
                flat: true
                PlasmaComponents3.ToolTip {
                    text: "Re-read battery, noise control, EQ and codec"
                }
                onClicked: {
                    if (plasmoidItem._connected) {
                        var addr = plasmoidItem._selectedDevice
                        plasmoidItem._request("refresh_battery", {address: addr})
                        plasmoidItem._request("refresh_noise", {address: addr})
                        plasmoidItem._request("refresh_equalizer", {address: addr})
                        plasmoidItem._request("refresh_info", {address: addr})
                        plasmoidItem._request("get_dsee", {address: addr})
                    }
                }
            }

            PlasmaComponents3.ToolButton {
                icon.name: "network-bluetooth-inactive-symbolic"
                flat: true
                PlasmaComponents3.ToolTip {
                    text: "Close the Sony control session (audio keeps working)"
                }
                onClicked: plasmoidItem._disconnect()
            }
        }
    }
}
