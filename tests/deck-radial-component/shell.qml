import QtQuick
import Quickshell
import "."

ShellRoot {
    id: testRoot
    DeckRadialPalette { id: radial }

    function check(condition, message) {
        if (!condition) throw new Error(message)
    }

    Timer {
        interval: 1
        running: true
        onTriggered: {
            const tabs = []
            for (let index = 0; index < 8; index++)
                tabs.push({ id: "tab-" + index, windowId: "window", title: "Tab " + index })
            PaletteState.tabs = tabs
            PaletteState.currentTabId = "tab-1"
            PaletteState.open = true
            radial.radial("open", 0)
            testRoot.check(radial.direction === -1 && radial.selectedEntry === null,
                           "browser open selected packed digital direction before analog data")
            testRoot.check(PaletteState.lastActivated === "",
                           "browser open previewed a tab before analog data")

            radial.radial("direction", 1.2)
            radial.radial("direction", 1.21)
            radial.radial("direction", 1.3)
            radial.radial("direction", 3.2)
            radial.radial("direction", 1.2)
            testRoot.check(PaletteState.activationHistory.join(",") === "tab-1,tab-3,tab-1",
                           "stale currentTabId broke transition-only A-B-A preview")

            radial.radial("direction", 1.7)
            testRoot.check(radial.selectedEntry.id === "tab-2", "fractional direction did not select tab 2")

            radial.radial("direction", 1.5)
            testRoot.check(radial.selectedEntry.id === "tab-1", "selection ignored the displayed 8-card angles")
            testRoot.check(PaletteState.lastActivated === "tab-1", "latest fractional tab was not previewed")
            PaletteState.radialRequested("direction", 4)
            testRoot.check(radial.direction === 1.5, "late digital direction overwrote analog selection")
            radial.updateStick("")
            testRoot.check(radial.direction === 1.5 && radial.selectedEntry.id === "tab-1",
                           "center input cleared the last valid selection")
            radial.radial("finish", 0)
            testRoot.check(!PaletteState.open && PaletteState.lastActivated === "tab-1",
                           "center then LT finish lost the chosen item")
            let settledHistory = PaletteState.activationHistory.length
            PaletteState.radialRequested("direction", 4)
            radial.updateStick("direction 6.25")
            testRoot.check(PaletteState.activationHistory.length === settledHistory
                           && PaletteState.lastActivated === "tab-1",
                           "late direction changed the tab after finish")

            PaletteState.currentTabId = "tab-1"
            PaletteState.open = true
            radial.radial("open", 0)
            radial.updateStick("direction 2.2")
            radial.radial("cancel", 0)
            testRoot.check(!PaletteState.open && PaletteState.lastActivated === "tab-1",
                           "cancel did not restore its original tab")
            settledHistory = PaletteState.activationHistory.length
            PaletteState.radialRequested("direction", 7)
            radial.updateStick("direction 5.5")
            testRoot.check(PaletteState.activationHistory.length === settledHistory
                           && PaletteState.lastActivated === "tab-1",
                           "late direction changed the tab after cancel")

            const quickmarks = []
            for (let index = 0; index < 13; index++) quickmarks.push({ name: "Q" + index, url: "about:blank" })
            PaletteState.quickmarks = quickmarks
            PaletteState.open = true
            radial.radial("open", 8)
            for (let index = 0; index < 13; index++) {
                radial.radial("direction", index * 8 / 13)
                testRoot.check(radial.selectedOuterIndex === index, "outer index " + index + " unreachable")
            }
            radial.radial("direction", -1)
            testRoot.check(radial.selectedOuterIndex === -1 && radial.selectedEntry === null,
                           "observer disconnect left a stale selection")

            radial.radial("open", 16)
            PaletteState.radialRequested("direction", 3)
            testRoot.check(radial.appsMode && radial.direction === 3,
                         "apps left-stick direction was suppressed")
            radial.radial("cancel", 0)
            testRoot.check(!PaletteState.open, "cancel did not close")

            console.log("deck radial component entry tests passed")
            Qt.quit()
        }
    }
}
