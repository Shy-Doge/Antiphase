import QtQuick
import org.kde.plasma.configuration

// Settings sidebar pages. "Keyboard Shortcuts" and "About" are appended
// by the Plasma shell itself.
ConfigModel {
    ConfigCategory {
        name: "Tray"
        icon: "preferences-desktop-panel"
        source: "configTray.qml"
    }
    ConfigCategory {
        name: "Widget"
        icon: "preferences-desktop-plasma"
        source: "configPopup.qml"
    }
}
