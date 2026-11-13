/**
 * Antiphase — Plasma 6 Applet (root)
 */

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

import "modelImages.js" as ModelImages

PlasmoidItem {
    id: root

    readonly property bool inPanel: [
        PlasmaCore.Types.TopEdge,
        PlasmaCore.Types.RightEdge,
        PlasmaCore.Types.BottomEdge,
        PlasmaCore.Types.LeftEdge,
    ].includes(Plasmoid.location)

    // ── State ────────────────────────────────────────────────────────────────
    property bool _connected: false
    property bool _connecting: false
    property var _devices: []
    property string _selectedDevice: ""
    property string _selectedPath: ""
    property string _deviceName: ""
    property string _modelName: ""
    property int _batteryPercent: -1   // -1 = unknown
    property bool _charging: false
    property int _noiseMode: 0       // 0=Off, 1=ANC, 2=Ambient
    property int _ambientLevel: 10
    property bool _focusOnVoice: false
    property int _eqPreset: 0
    property bool _hasEq: false
    property var _eqBands: []         // raw band values (0..steps-1) for custom presets
    property var _scenes: []          // editable ASC scene configs from the daemon
    property var _sceneDefaults: []   // stock definitions for "Reset to defaults"
    property string _firmware: ""
    property string _codec: ""
    property int _batteryLeft: -1     // -1 = not applicable / unknown
    property int _batteryRight: -1
    property int _batteryCase: -1
    property bool _dsee: false
    property bool _speakToChat: false
    property bool _adaptiveVolume: false
    property int _autoPowerOff: 0     // index into the AUTO_POWER_OFF table
    property var _profile: ({})       // capability flags from the daemon
    property var _allStates: []       // per-session snapshots (tooltip feed)
    property string _view: "list"     // "list" | "detail"
    // Auto-establish the control session when a Bluetooth-connected Sony
    // device appears, so the tray battery shows up without opening the
    // popup. Attempts are tracked per address (a failed attempt is not
    // retried until the device drops and reconnects), and an explicit
    // user disconnect is never undone.
    property var _autoConnectTried: ({})
    property bool _userDismissed: false

    // ── Tray tooltip ─────────────────────────────────────────────────────────
    // Hovering the tray cell lists every connected headset with its
    // noise-control mode and battery. Detailed lines come from the
    // daemon's per-session snapshots (get_all_states); Bluetooth-only
    // devices — no Sony session, nothing to read — are named plainly.
    readonly property var _modeNames: ["Off", "ANC", "Ambient"]
    readonly property int _btOnlyCount: root._devices.filter(function (d) {
        return d.connected && !root._allStates.some(function (s) {
            return s.address === d.address
        })
    }).length
    toolTipMainText: {
        const n = root._allStates.length + root._btOnlyCount
        if (n === 0)
            return "Antiphase"
        if (n === 1 && root._connected)
            return root._modelName || root._deviceName || "Sony Headphones"
        return "Antiphase — " + n + (n === 1 ? " device" : " devices")
    }
    toolTipSubText: {
        const lines = []
        for (const s of root._allStates) {
            const label = (s.model && s.model !== "Unknown")
                          ? s.model : (s.name || "Sony headphones")
            const bits = []
            if (s.address === root._selectedDevice && root._connected) {
                // Local state is polled faster than the daemon cache.
                if (root._codec !== "")
                    bits.push(root._codec)
                bits.push(root._modeNames[root._noiseMode] || "Off")
                if (root._batteryPercent >= 0)
                    bits.push(root._batteryPercent + "%"
                              + (root._charging ? " (charging)" : ""))
            } else {
                if (s.codec)
                    bits.push(s.codec)
                bits.push(root._modeNames[s.mode] || "Off")
                if (s.battery >= 0)
                    bits.push(s.battery + "%"
                              + (s.charging ? " (charging)" : ""))
            }
            lines.push(label + " · " + bits.join(" · "))
        }
        for (const d of root._devices) {
            if (d.connected && !root._allStates.some(function (s) {
                    return s.address === d.address
                }))
                lines.push(d.name + " · connected")
        }
        return lines.length === 0 ? "No headphones connected"
                                  : lines.join("<br/>")
    }

    // Exactly one Bluetooth-connected Sony device: open the daemon session
    // silently (the popup stays on the device list).
    function _maybeAutoConnect(devices) {
        if (root._userDismissed || root._connecting)
            return
        var live = devices.filter(function (d) { return d.connected })
        // Forget devices that dropped: their next connection may auto-connect.
        for (var addr in root._autoConnectTried) {
            if (!live.some(function (d) { return d.address === addr }))
                delete root._autoConnectTried[addr]
        }
        if (root._selectedDevice !== "") {
            // A dead session on the selected device: re-open it once the
            // device is Bluetooth-connected again (the per-address attempt
            // map keeps this from retry-storming).
            if (!root._connected
                    && !root._autoConnectTried[root._selectedDevice]
                    && live.some(function (d) { return d.address === root._selectedDevice })) {
                root._autoConnectTried[root._selectedDevice] = true
                root._reconnect()
            }
            return
        }
        if (live.length !== 1)
            return
        if (root._autoConnectTried[live[0].address])
            return
        root._autoConnectTried[live[0].address] = true
        root._selectedDevice = live[0].address
        root._selectedPath = live[0].path
        root._deviceName = live[0].name
        root._connecting = true
        root._request("connect_device", {
            address: live[0].address, device_path: live[0].path,
            device_name: live[0].name
        })
    }

    // (Re)open the Sony control session for the selected device. The
    // daemon also brings the Bluetooth link up when it is down.
    function _reconnect() {
        if (root._selectedDevice === "" || root._connecting)
            return
        root._connecting = true
        root._request("connect_device", {
            address: root._selectedDevice,
            device_path: root._selectedPath,
            device_name: root._deviceName
        })
    }

    // Pick a device from the list: open its detail page and (re)establish
    // the Sony control session. The daemon reuses a live session as-is.
    function _selectDevice(address, path, name) {
        // Re-entering the device whose session is already live (or still
        // connecting): just show the detail page. Clearing state and
        // re-connecting would flash "not connected / no battery" for the
        // duration of the round-trip; the state poll keeps the page fresh.
        if (address === root._selectedDevice && (root._connected || root._connecting)) {
            root._view = "detail"
            return
        }
        // Drop stale state from any previously selected device so the
        // detail page never shows another headset's battery/EQ while the
        // new session is still connecting.
        root._connected = false
        root._batteryPercent = -1
        root._batteryLeft = -1
        root._batteryRight = -1
        root._batteryCase = -1
        root._charging = false
        root._firmware = ""
        root._codec = ""
        root._eqBands = []
        root._selectedDevice = address
        root._selectedPath = path
        root._deviceName = name
        root._view = "detail"
        root._connecting = true
        root._request("connect_device", {
            address: address, device_path: path, device_name: name
        })
    }

    // Read the device-side settings shown on the settings page. Gated by
    // the profile so unsupported reads (which time out) never run.
    function _refreshSettings() {
        if (!root._connected || !root._selectedDevice)
            return
        var p = root._profile || {}
        var addr = root._selectedDevice
        if (p.speakToChat)
            root._request("get_speak_to_chat", {address: addr})
        if (p.adaptiveVolume)
            root._request("get_adaptive_volume", {address: addr})
        if (p.autoPowerOff)
            root._request("get_auto_power_off", {address: addr})
    }

    function _disconnect() {
        root._request("disconnect_device", {address: root._selectedDevice})
        root._userDismissed = true
        root._connected = false
        root._connecting = false
        root._batteryPercent = -1
        root._batteryLeft = -1
        root._batteryRight = -1
        root._batteryCase = -1
        root._codec = ""
        root._modelName = ""
        root._profile = ({})
        root._view = "list"
    }

    // ── Daemon client (JSON-RPC over loopback HTTP) ──────────────────────────
    // The QtNetwork QML module exposes no usable types on this system (the
    // built-in module registration is incomplete), so the plasmoid talks to
    // the daemon's HTTP endpoint with XMLHttpRequest, which is part of the
    // core QML JS runtime.
    readonly property string _daemonHost: "127.0.0.1"
    readonly property int _daemonPort: 48322
    readonly property string _rpcUrl: "http://" + _daemonHost + ":" + _daemonPort + "/rpc"

    // Debug log via console — plasmashell routes QML console output to the
    // user journal, so this is the reliable diagnostics channel.
    function _log(msg) {
        console.log("Antiphase: " + msg)
    }

    property int _requestId: 0
    // Request id -> {method, address, isProbe}. JSON-RPC replies carry only
    // the id back, so this map correlates a response with the call that
    // produced it and lets stale replies be dropped.
    property var _pending: ({})
    // True while the periodic get_state poll is outstanding, so slow
    // daemon responses never pile up.
    property bool _stateInFlight: false

    // plasmashell's QML engine has no setTimeout/setInterval, so deferred
    // retries use a Timer element. Only the bootstrap probe auto-retries;
    // control requests surface errors and wait for the next user action.
    function _connectToDaemon() {
        _log("probing daemon at " + _rpcUrl)
        _request("list_devices", {}, true)
    }

    function _request(method, params, isProbe) {
        _requestId++
        var id = _requestId
        _pending[id] = {
            method: method,
            address: (params && params.address) || "",
            isProbe: !!isProbe
        }
        var xhr = new XMLHttpRequest()
        xhr.open("POST", _rpcUrl, true)
        // Client-side deadline: a wedged connection must not hold the
        // in-flight slot forever. (Ignored by XHR implementations
        // without timeout support; the repeating timers still recover.)
        xhr.timeout = 10000
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            if (xhr.status === 200) {
                try {
                    _handleResponse(JSON.parse(xhr.responseText))
                } catch (e) {
                    _log("response parse error: " + e)
                    _handleTransportFailure(id)
                }
            } else {
                _log("rpc failed with status " + xhr.status)
                _handleTransportFailure(id)
            }
        }
        xhr.onerror = function() {
            _log("rpc network error (daemon down?)")
            _handleTransportFailure(id)
        }
        xhr.send(JSON.stringify({jsonrpc: "2.0", method: method, params: params || {}, id: id}))
    }

    // The request died before producing a usable result. The probe timer
    // repeats on its own while disconnected, so failures only need to fix
    // stuck UI state — and a dead get_state means the daemon itself is
    // gone: fall back to disconnected, which re-arms the probe loop and
    // rediscovers everything once the daemon is back.
    function _handleTransportFailure(id) {
        var req = _pending[id]
        delete _pending[id]
        if (!req)
            return
        if (req.method === "get_state") {
            root._stateInFlight = false
            root._connected = false
            root._connecting = false
            // The daemon may have restarted: release the device and forget
            // the attempt so the probe re-establishes the session (a merely
            // transient blip costs one idempotent connect_device, which the
            // daemon answers from the still-live session).
            delete root._autoConnectTried[root._selectedDevice]
            root._selectedDevice = ""
            root._deviceName = ""
            if (root._view === "detail")
                root._view = "list"
        } else if (req.method === "connect_device") {
            root._connecting = false
            // Stay where we are: the detail page shows "Not connected"
            // with a Connect button, and the probe retries automatically
            // once the device re-appears as Bluetooth-connected.
        }
    }

    // Bootstrap + recovery probe: keeps re-listing devices until a Sony
    // session is up, so a daemon started (or restarted) after login is
    // picked up without reloading the shell.
    Timer {
        id: probeTimer
        interval: 5000
        repeat: true
        running: !root._connected
        onTriggered: root._connectToDaemon()
    }

    // Follow on-device changes (NC button, power, battery, codec) via
    // the daemon's state monitor: a cheap cached read whose fields are
    // applied as a diff. Also notices a dead session ("Not connected")
    // within seconds of the headphones powering off. One request at a
    // time: connect_device can legitimately hold the daemon for tens
    // of seconds and the polls must not pile up behind it.
    Timer {
        id: stateSyncTimer
        interval: 2500
        repeat: true
        running: root._connected && !root._connecting
        onTriggered: {
            if (root._stateInFlight)
                return
            root._stateInFlight = true
            root._request("get_state", {address: root._selectedDevice})
        }
    }

    // While connected, keep the device list fresh: a headset paired
    // after login should show up without user action.
    Timer {
        id: deviceScanTimer
        interval: 30000
        repeat: true
        running: root._connected
        onTriggered: root._request("list_devices", {})
    }

    // Tray tooltip feed: snapshots of every open Sony session, served
    // from the daemon's monitor cache. Always on — with no sessions the
    // reply is simply empty and the tooltip falls back to the device
    // list; connect/disconnect transitions land within one cycle.
    Timer {
        interval: 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root._request("get_all_states", {})
    }

    // ── Response handler ─────────────────────────────────────────────────────
    function _handleResponse(data) {
        if (!data) return
        var req = _pending[data.id]
        delete _pending[data.id]
        var method = req ? req.method : ""
        var address = req ? req.address : ""
        if (method === "get_state")
            root._stateInFlight = false
        // A reply for a device the user has navigated away from is stale.
        if (address && address !== root._selectedDevice)
            return

        if (data.error) {
            // JSON-RPC level failure (e.g. connect_device raised).
            _log("rpc error: " + JSON.stringify(data.error))
            if (method === "connect_device") {
                root._connecting = false
                // Keep the selection: Connect button + probe can retry.
            }
            return
        }
        var result = data.result
        try {
            // The sync poll fires every few seconds; keep the journal quiet.
            if (method !== "get_state")
                _log("response id=" + data.id + " (" + method + "): " + JSON.stringify(result).substring(0, 140))
        } catch (e) {}

        if (method === "power_off" && result && result.error === undefined) {
            // The device is off (or dropped the link): the session is gone.
            // A declined command falls through to the error branch below.
            root._connected = false
            root._connecting = false
            root._selectedDevice = ""
            root._deviceName = ""
            root._view = "list"
            return
        }
        if (method === "get_all_states") {
            root._allStates = Array.isArray(result) ? result : []
            return
        }
        if (Array.isArray(result)) {
            root._devices = result
            root._maybeAutoConnect(result)
            return
        }
        if (result === null || result === undefined) return
        // Settings reads answer with bare booleans/numbers — route them by
        // method before the generic boolean (DSEE) fallback below.
        if (method === "get_speak_to_chat") { root._speakToChat = result === true; return }
        if (method === "get_adaptive_volume") { root._adaptiveVolume = result === true; return }
        if (method === "get_auto_power_off") {
            if (typeof result === "number")
                root._autoPowerOff = result
            return
        }
        if (typeof result === "boolean") { root._dsee = result; return }

        if (result.state === true) {            // Snapshot from the daemon's monitor: only the fields the
            // device can change on its own. Apply as a diff so absent
            // fields (unsupported reads) never clobber known state.
            if (result.battery !== undefined)
                root._batteryPercent = result.battery
            if (result.charging !== undefined)
                root._charging = result.charging
            if (result.mode !== undefined)
                root._noiseMode = result.mode
            if (result.ambientLevel !== undefined)
                root._ambientLevel = result.ambientLevel
            if (result.focusOnVoice !== undefined)
                root._focusOnVoice = result.focusOnVoice
            if (result.codec !== undefined)
                root._codec = result.codec
            if (result.dsee !== undefined)
                root._dsee = result.dsee
            return
        }

        if (result.error !== undefined) {
            // A control method failed (typically "Not connected" after the
            // Sony session died) — reflect that in the UI state.
            _log("method " + method + " failed: " + result.error)
            if (result.error === "Not connected") {
                root._connected = false
                root._connecting = false
                // Keep the page open: its Connect button (and the probe,
                // once the device re-appears as Bluetooth-connected) can
                // re-establish the session.
                delete root._autoConnectTried[root._selectedDevice]
            }
            // The UI optimistically assumed the write succeeded; re-read
            // the affected section so it shows the device's real state.
            var resync = {
                set_noise_mode: "refresh_noise",
                set_asc_scene: "refresh_noise",
                set_equalizer_preset: "refresh_equalizer",
                set_equalizer_custom: "refresh_equalizer",
                set_dsee: "get_dsee",
                set_speak_to_chat: "get_speak_to_chat",
                set_adaptive_volume: "get_adaptive_volume",
                set_auto_power_off: "get_auto_power_off"
            }
            if (resync[method] && address)
                root._request(resync[method], {address: address})
            return
        }
        if (result.scenes !== undefined) {
            root._scenes = result.scenes
            if (result.defaults !== undefined)
                root._sceneDefaults = result.defaults
            return
        }
        if (result.success === true && result.model !== undefined) {
            root._connected = true
            root._connecting = false
            root._modelName = result.model
            root._profile = result.profile || {}
            // Pull the full device state once the Sony session is up.
            var addr = address || root._selectedDevice
            root._request("refresh_battery", {address: addr})
            root._request("refresh_noise", {address: addr})
            root._request("refresh_equalizer", {address: addr})
            root._request("refresh_info", {address: addr})
            root._request("get_dsee", {address: addr})
            root._request("get_scenes", {})
            root._refreshSettings()
            return
        }
        if (result.main !== undefined) {
            root._batteryPercent = result.main
            root._charging = result.charging || false
            root._batteryLeft = (result.left === null || result.left === undefined) ? -1 : result.left
            root._batteryRight = (result.right === null || result.right === undefined) ? -1 : result.right
            root._batteryCase = (result.case === null || result.case === undefined) ? -1 : result.case
            return
        }
        if (result.mode !== undefined) {
            root._noiseMode = result.mode
            // "|| 10" would turn a legitimate level 0 into 10.
            root._ambientLevel = (result.ambientLevel === undefined || result.ambientLevel === null)
                ? 10 : result.ambientLevel
            root._focusOnVoice = result.focusOnVoice || false
            return
        }
        if (result.preset !== undefined) {
            root._eqPreset = result.preset
            root._hasEq = true
            if (Array.isArray(result.bands))
                root._eqBands = result.bands
            return
        }
        if (typeof result === "object"
            && (result.firmware !== undefined || result.codec !== undefined)) {
            if (result.firmware !== undefined)
                root._firmware = result.firmware || ""
            if (result.codec !== undefined)
                root._codec = result.codec || ""
            return
        }
    }

    // ── Plasmoid config ──────────────────────────────────────────────────────
    // Tray icon: a preset or custom icon name from the config page, "product"
    // for the connected device's render, or "auto" for the built-in glyph.
    readonly property string _iconConfig: {
        const c = Plasmoid.configuration
        c && c.icon ? c.icon : "auto"
    }
    // Product render of the connected device as an icon URL; empty when the
    // model is unknown.
    readonly property string _productIconSource: {
        const key = ModelImages.imageKeyFor(_modelName || _deviceName)
        key === "" ? "" : Qt.resolvedUrl("images/" + key + ".webp")
    }
    readonly property string _defaultIcon:
        inPanel ? "audio-headset-symbolic" : "audio-headset-bluetooth"
    Plasmoid.icon: _iconConfig === "product"
                   ? (_productIconSource || _defaultIcon)
                   : _iconConfig !== "auto" ? _iconConfig : _defaultIcon
    // Stay visible in the tray once Sony headphones are known: a passive
    // plasmoid hides in the collapsed overflow and the user cannot find
    // it to connect in the first place.
    Plasmoid.status: (_connected || _devices.length > 0)
        ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus

    // ── Context menu actions (right-click) ───────────────────────────────────
    PlasmaCore.Action {
        id: refreshAction
        text: "Refresh Devices"
        icon.name: "view-refresh"
        onTriggered: root._request("list_devices", {})
    }

    Component.onCompleted: {
        _log("plasmoid loaded")
        Plasmoid.contextualActions.push(refreshAction)
        _connectToDaemon()
    }

    Component.onDestruction: {
        probeTimer.stop()
    }

    // ── Representations ──────────────────────────────────────────────────────
    fullRepresentation: FullRepresentation {
        plasmoidItem: root
        Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground
    }

    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
    }
}
