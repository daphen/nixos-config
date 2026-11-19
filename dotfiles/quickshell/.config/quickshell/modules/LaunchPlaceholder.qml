import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QsLib as Q

// A tiled stand-in window from launch until the app's first window takes its slot (see is_launch_placeholder in hyprland.lua).
Scope {
    id: root

    readonly property var names: ({
        "slack": "Slack", "slqs-client": "Slack",
        "launch-discord-client": "Discord", "dsqrd-client": "Discord",
        "launch-mail-client": "Mail", "mlqs-client": "Mail",
        "opqs-client": "Passwords",
        "browser-work-new": "Helium",
        "chromium-launch": "Chromium", "helium": "Helium",
        "deck-cockpit": "Cockpit", "cockpit-qs": "Cockpit", "cockpit-new": "Cockpit",
        "spotify": "Spotify", "obsidian": "Obsidian", "libreoffice": "LibreOffice"
    })
    property var launches: []
    property int serial: 0

    function nameFor(command) {
        const words = command.split(/\s+/).filter(w => w !== "")
        while (words.length && words[0].split("/").pop() === "desktop-launch") words.shift()
        return words.length ? names[words[0].split("/").pop()] || "" : ""
    }
    function drop(key) { launches = launches.filter(l => l.key !== key) }

    IpcHandler {
        target: "launch"
        function show(command: string) {
            const name = root.nameFor(command)
            if (!name || root.launches.some(l => l.title === name)) return
            root.launches = root.launches.concat([{ key: ++root.serial, title: name }])
        }
    }

    Instantiator {
        model: root.launches
        delegate: FloatingWindow {
            id: win
            required property var modelData
            property bool shown: false
            property bool done: false

            title: "qs-launch · " + modelData.title
            implicitWidth: 960; implicitHeight: 640
            color: "transparent"
            visible: shown

            Connections {
                target: Hyprland
                function onRawEvent(event) {
                    if (!event || event.name !== "openwindow" || win.done) return
                    if (String(event.data).split(",").slice(3).join(",").startsWith("qs-launch")) return
                    if (root.launches[0] && root.launches[0].key !== win.modelData.key) return
                    win.done = true
                    if (win.shown) fade.start(); else root.drop(win.modelData.key)
                }
            }
            // Apps that open within a blink never show a placeholder.
            Timer { interval: 120; running: true; onTriggered: if (!win.done) win.shown = true }
            Timer { interval: 15000; running: true; onTriggered: root.drop(win.modelData.key) }
            NumberAnimation { id: fade; target: surface; property: "opacity"; to: 0; duration: 220; easing.type: Easing.OutCubic
                onFinished: root.drop(win.modelData.key) }

            Rectangle {
                id: surface
                anchors.fill: parent
                color: Q.Theme.bg
                Q.LaunchCard {
                    anchors.centerIn: parent
                    title: win.modelData.title
                    running: win.shown && !win.done
                    color: "transparent"
                    border.width: 0
                }
            }
        }
    }
}
