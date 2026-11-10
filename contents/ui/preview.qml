import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

// Live design preview: renders the real FullRepresentation against a mock
// applet state. The real main.qml cannot be instantiated outside plasmashell
// (the Plasmoid attached object is unavailable there), so the mock mirrors
// its state API and answers _request() locally for interactive tweaking.
//
// SONY_PREVIEW_STATE: connected | list | dual | disconnected

Window {
    id: win
    visible: true
    width: previewWidth > 0 ? previewWidth : 340
    height: 560
    title: "Antiphase preview"

    PlasmoidItem {
        id: mock
        width: 0
        height: 0

        readonly property bool dual: previewState === "dual"

        property bool _connected: previewState !== "disconnected"
        property bool _connecting: false
        property var _devices: [
            {path: "/org/bluez/hci0/dev_58", name: dual ? "WF-1000XM6" : "WH-1000XM6",
             address: "AA:BB:CC:DD:EE:FF", paired: 1, connected: 1},
            {path: "/org/bluez/hci0/dev_99", name: "WH-1000XM4",
             address: "99:11:22:33:44:55", paired: 1, connected: 1}
        ]
        property string _selectedDevice: "AA:BB:CC:DD:EE:FF"
        property string _deviceName: dual ? "WF-1000XM6" : "WH-1000XM6"
        property string _modelName: dual ? "WF-1000XM6" : "WH-1000XM6"
        property int _batteryPercent: 80
        property bool _charging: false
        property int _noiseMode: previewState === "ambient" ? 2 : 1
        property int _ambientLevel: 10
        property bool _focusOnVoice: false
        property int _eqPreset: 0xA2
        property bool _hasEq: true
        property var _eqBands: [7, 7, 6, 7, 8, 11, 5, 10, 7, 8]
        property string _firmware: "3.1.5"
        property string _codec: "AAC"
        property int _batteryLeft: dual ? 100 : -1
        property int _batteryRight: dual ? 100 : -1
        property int _batteryCase: dual ? 100 : -1
        property bool _dsee: true
        property var _profile: ({dualBattery: dual, eq: true, dsee: true, eqSteps: 13,
                                 asc: true, ascScenes: [0x08, 0x10, 0x20],
                                 eqPresets: [0x00, 0x20, 0x30, 0x31, 0x32, 0x33,
                                             0xA0, 0xA1, 0xA2]})
        property var _scenes: [
            {id: 0x08, name: "Focus",  mode: 1, ambientLevel: 0,  focusOnVoice: false},
            {id: 0x10, name: "Office", mode: 2, ambientLevel: 10, focusOnVoice: false},
            {id: 0x20, name: "Aware",  mode: 2, ambientLevel: 20, focusOnVoice: false}
        ]
        property var _sceneDefaults: []
        property string _view: previewState === "list" ? "list" : "detail"

        function _selectDevice(address, path, name) {
            mock._selectedDevice = address
            mock._deviceName = name
            mock._view = "detail"
        }
        function _disconnect() {
            mock._connected = false
            mock._view = "list"
        }

        function _request(method, params) {
            console.log("mock request:", method, JSON.stringify(params))
            if (method === "set_noise_mode") {
                mock._noiseMode = params.mode
                if (params.ambientLevel !== undefined) mock._ambientLevel = params.ambientLevel
                if (params.focusOnVoice !== undefined) mock._focusOnVoice = params.focusOnVoice
            } else if (method === "set_equalizer_preset") {
                mock._eqPreset = params.preset
                if (params.preset >= 0xA0 && mock._eqBands.length < 10)
                    mock._eqBands = [6, 6, 6, 6, 6, 6, 6, 6, 6, 6]
            } else if (method === "set_equalizer_custom") {
                mock._eqBands = params.bands
            } else if (method === "set_asc_scene") {
                var s = mock._scenes.filter(function (x) { return x.id === params.scene })[0]
                if (s) {
                    mock._noiseMode = s.mode
                    if (s.mode === 2)
                        mock._ambientLevel = s.ambientLevel
                    mock._focusOnVoice = s.focusOnVoice
                }
            } else if (method === "set_scenes") {
                mock._scenes = params.scenes
            } else if (method === "set_dsee") {
                mock._dsee = params.enabled
            } else if (method === "power_off") {
                mock._connected = false
            }
        }
    }

    // Kirigami picks up the user's KDE color scheme (dark) from kdeglobals.
    Item {
        anchors.fill: parent

        Rectangle {
            anchors.fill: parent
            color: Kirigami.Theme.backgroundColor
        }

        FullRepresentation {
            anchors.fill: parent
            plasmoidItem: mock
            detailLayoutOverride: previewDetail
        }
    }

    // Self-capture mode: SONY_PREVIEW_OUT style — scripts/preview.py passes
    // the destination path via the previewOut context property.
    Timer {
        interval: 1500
        running: previewOut !== ""
        onTriggered: {
            win.contentItem.grabToImage(function (result) {
                if (result.saveToFile(previewOut))
                    console.log("captured -> " + previewOut)
                Qt.quit()
            })
        }
    }
}
