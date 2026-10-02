import QtQuick
import Quickshell
import "modules" as Modules

ShellRoot {
    Modules.DeckRadialPalette {}
    Connections {
        target: Quickshell
        function onReloadCompleted() { Quickshell.inhibitReloadPopup() }
        function onReloadFailed() { Quickshell.inhibitReloadPopup() }
    }
}
