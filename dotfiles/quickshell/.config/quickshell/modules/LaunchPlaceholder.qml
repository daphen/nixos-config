import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QsLib as Q

// A tiled stand-in window from launch until the app's first window takes its slot (see is_launch_placeholder in hyprland.lua).
Scope {
    id: root

    // Display names where the command name reads badly; everything else uses its desktop entry or command name.
    readonly property var names: ({
        "slqs-client": "Slack", "launch-discord-client": "Discord", "dsqrd-client": "Discord",
        "launch-mail-client": "Mail", "mlqs-client": "Mail", "opqs-client": "Passwords",
        "browser-personal": "Helium", "browser-work": "Helium", "browser-work-new": "Helium", "chromium-launch": "Helium",
        "deck-cockpit": "Cockpit", "cockpit-qs": "Cockpit", "cockpit-new": "Cockpit", "cockpit-boot": "Cockpit",
        "spawn-terminal-with-yazi": "Files", "spawn-claude-session-picker": "Sessions",
        "kitty": "Terminal", "spotify_player": "Spotify", "spotify-player": "Spotify"
    })

    function nameFor(command) {
        const words = command.split(/\s+/).filter(w => w !== "" && !/^[A-Z_][A-Z0-9_]*=/.test(w))
        while (words.length && words[0].split("/").pop() === "desktop-launch") words.shift()
        if (!words.length) return ""
        let bin = words[0].split("/").pop()
        const cls = words.indexOf("--class")
        if (bin === "kitty" && cls > 0 && words[cls + 1]) bin = words[cls + 1]
        if (names[bin]) return names[bin]
        const entry = DesktopEntries.applications.values.find(e => e.command && e.command.length
            && e.command[0].split("/").pop() === bin)
        if (entry && entry.name) return entry.name
        const plain = bin.replace(/\.[a-z]+$/, "").replace(/[-_]+/g, " ").trim()
        return plain.charAt(0).toUpperCase() + plain.slice(1)
    }
    property var launches: []

    function drop(key) { launches = launches.filter(l => l.key !== key) }
    signal finished(string key)

    IpcHandler {
        target: "launch"
        function show(key: string, command: string) {
            const name = root.nameFor(command)
            if (!name || root.launches.some(l => l.title === name)) return
            root.launches = root.launches.concat([{ key: key, title: name }])
        }
        function done(key: string) { root.finished(key) }
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
                    win.finish()
                }
            }
            // Apps that open within a blink never show a placeholder.
            function finish() {
                win.done = true
                if (win.shown) fade.start(); else root.drop(win.modelData.key)
            }
            Connections {
                target: root
                function onFinished(key) { if (key === win.modelData.key && !win.done) win.finish() }
            }
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
