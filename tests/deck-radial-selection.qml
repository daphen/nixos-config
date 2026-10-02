import QtQuick
import Quickshell
import Quickshell.Io
import "modules" as Modules

ShellRoot {
    Modules.DeckRadialPalette { id: radial }
    Process {
        running: radial.visible
        command: [Quickshell.env("RADIAL_TEST_PRODUCER")]
    }
    property int phase: 0
    function check(value, message) { if (!value) throw new Error(message) }
    function open(value) {
        Quickshell.execDetached([Quickshell.env("QS_BIN"), "-p", Quickshell.env("RADIAL_TEST_CONFIG"),
            "ipc", "call", "--", "palette", "radial", "open", String(value), ""])
    }
    function visualEntries(node = radial.contentItem) {
        let entries = typeof node.selected === "boolean" && node.entry !== undefined ? [node] : []
        for (const child of node.children || []) entries = entries.concat(visualEntries(child))
        return entries
    }
    function checkMagnetism(width) {
        const entries = visualEntries()
        const selected = entries.filter(item => item.selected && item.width === width)
        check(selected.length === 1, "active ring must have one visual selection")
        const item = selected[0]
        check(item.scale > 1.005 && item.scale <= 1.065, "selected item did not gently spring forward: " + item.scale)
        const resting = width === 140 ? item.radialDistance : item.parent.width / 2 - (width === 48 ? 104 : 36)
        const distance = Math.hypot(item.x + item.width / 2 - item.parent.width / 2,
                                   item.y + item.height / 2 - item.parent.height / 2)
        check(distance < resting - 0.5 && distance >= resting - 6.5, "selected item pull exceeded its six-pixel bound")
    }
    function directions() {
        const entries = radial.middleActive ? radial.middleItems : radial.outerRingActive ? radial.outerItems : radial.innerItems
        const visited = new Set()
        for (let sample = 0; sample < 128; sample++) {
            radial.updateStick("direction " + (sample / 16))
            if (radial.selectedEntry) visited.add(radial.selectedEntry.title)
        }
        check(visited.size === entries.length, "dense full circle reached " + visited.size + "/" + entries.length)
        console.log("DENSE360 reached " + visited.size + "/" + entries.length + " entries")
        if (Quickshell.env("RADIAL_DENSE_ONLY") === "1") return
        for (const value of [2, 4, 6, 0, 1, 3, 5, 7]) {
            const before = radial.direction
            const changes = radial.ringIndex(entries) >= 0 && radial.ringIndex(entries, value) !== radial.ringIndex(entries)
            radial.updateStick("direction " + value)
            if (changes) check(radial.direction === before, "unconfirmed candidate changed selection")
            radial.updateStick("direction " + value)
            check(radial.direction === value, "confirmed direction was discarded: " + value)
            check((radial.selectedEntry !== null) === (entries.length > 0), "direction lost its selected entry")
        }
        radial.updateStick("direction 2.100")
        radial.updateStick("direction 2.125")
        check(radial.direction === 2.125, "fractional analog direction was quantized")
        for (const data of ["invalid 4", "direction NaN", "direction Infinity", "direction 2 extra"])
            radial.updateStick(data)
        check(radial.direction === 2.125, "invalid packet changed selection")
    }
    Timer {
        interval: 300; running: true; repeat: true
        onTriggered: {
            try {
                if (phase === 0) {
                    Modules.PaletteState.tabs = Array.from({length: 8}, (_, i) => ({id: i, title: "Tab " + i, windowId: 1}))
                    open(16)
                } else if (phase === 1) {
                    check(radial.visible && radial.appsMode && radial.outerRingActive && radial.outerItems.length === 8, "app menu must open on its eight launchers")
                    check(radial.direction === 2, "real reader stdout did not reach selection through SplitParser")
                    directions()
                    radial.updateStick("direction 2")
                    radial.updateStick("direction 2")
                    radial.updateStick("direction 2.51")
                    check(radial.direction === 2, "angular hysteresis was lost")
                    Modules.PaletteState.radialRequested("cycle", 0)
                    check(radial.appLayer === 0 && radial.innerItems.length === Number(Quickshell.env("RADIAL_TEST_CLIENT_COUNT")), "cycle must retain open windows")
                    directions()
                    Modules.PaletteState.radialRequested("cycle", 0)
                    check(radial.middleActive, "cycle must retain actions")
                    directions()
                    Modules.PaletteState.radialRequested("cycle", 0)
                    check(radial.outerRingActive, "cycle must return to launchers")
                    Modules.PaletteState.radialRequested("direction", 4)
                    Modules.PaletteState.radialRequested("direction", 4)
                    check(radial.direction === 4, "confirmed IPC direction was discarded")
                    Modules.PaletteState.radialRequested("activate", 0)
                    check(!Modules.PaletteState.open, "activation did not close menu")
                    radial.updateStick("direction 6")
                    check(radial.direction === 4, "hidden menu accepted late input")
                    open(0)
                } else if (phase === 2) {
                    check(radial.visible && !radial.appsMode, "browser menu did not open")
                    check(radial.direction === 2, "real reader stdout did not reach browser selection")
                    directions()
                    Modules.PaletteState.radialRequested("cancel", 0)
                    check(!Modules.PaletteState.open, "cancel did not close menu")
                    open(0)
                } else if (phase === 3) {
                    Modules.PaletteState.radialRequested("finish", 0)
                    check(!Modules.PaletteState.open, "release/finish did not close menu")
                    open(16)
                } else if (phase === 4) {
                    checkMagnetism(64)
                    radial.updateStick("direction 7.90")
                    radial.updateStick("direction 7.95")
                    check(radial.selectedEntry.title === "Slack", "wraparound activation must not wait for visual motion")
                } else if (phase === 5) {
                    checkMagnetism(64)
                    Modules.PaletteState.radialRequested("cycle", 0)
                } else if (phase === 6) {
                    if (radial.innerItems.length) checkMagnetism(140)
                    Modules.PaletteState.radialRequested("cycle", 0)
                } else if (phase === 7) {
                    checkMagnetism(48)
                    Modules.PaletteState.radialRequested("cancel", 0)
                    check(!Modules.PaletteState.open, "spring motion must not delay cancel")
                    console.log("PASS radial public IPC and analog packets: debounced directions, fractional angles, rings, activation, cancel, release, invalid/late guards, bounded spring attraction and wraparound")
                    Qt.quit()
                }
                phase++
            } catch (error) { console.error("FAIL " + error); Qt.quit() }
        }
    }
}
