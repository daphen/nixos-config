import QtQuick
import Quickshell
import QsLib

ShellRoot {
    id: test
    property int phase: 0
    readonly property color darkIdle: Qt.tint(Theme.surface, Qt.alpha("#FAFAFA", 0.045))
    function check(ok, message) {
        if (!ok) { console.error("FAIL: " + message); Qt.quit(); throw new Error(message) }
    }
    function colorIs(expected) { return face.color.toString() === expected.toString() }
    function darkFill(alpha) { return Qt.tint(face.base, Qt.rgba(1, 1, 1, alpha)) }
    FloatingWindow {
        visible: true; width: 240; height: 80
        TabFace { id: face; anchors.fill: parent }
    }
    FrameAnimation {
        running: test.phase >= 2 && test.phase <= 5
        onTriggered: test.check(test.colorIs(Theme.surface), "light navigation exposes a non-neutral backing")
    }
    Timer {
        interval: 220; running: true; repeat: true
        onTriggered: {
            switch (test.phase) {
            case 0: Theme.mode = "light"; break
            case 1: face.cursor = true; break
            case 2:
                face.cursor = false
                test.check(test.colorIs(Theme.surface), "cursor departure flashes gray")
                break
            case 3: face.selected = true; break
            case 4:
                face.selected = false
                test.check(test.colorIs(Theme.surface), "selection departure flashes gray")
                break
            case 5: face.hovered = true; break
            case 6:
                test.check(test.colorIs(Theme.itemHover), "light hover fill changes")
                face.hovered = false
                test.check(test.colorIs(Theme.itemHover), "light hover exit loses its fade")
                break
            case 7:
                test.check(test.colorIs(Theme.surface), "light hover does not settle")
                Theme.mode = "dark"
                break
            case 8:
                test.check(test.colorIs(test.darkIdle), "dark idle fill changes")
                face.cursor = true
                test.check(test.colorIs(test.darkIdle), "dark cursor entry loses its fade")
                break
            case 9:
                test.check(test.colorIs(test.darkFill(0.14)), "dark cursor fill changes")
                face.cursor = false
                test.check(test.colorIs(test.darkFill(0.14)), "dark cursor exit loses its fade")
                break
            case 10: face.selected = true; break
            case 11:
                test.check(test.colorIs(test.darkFill(0.10)), "dark selected fill changes")
                face.selected = false
                break
            case 12:
                test.check(test.colorIs(test.darkIdle), "dark selection does not settle")
                console.log("PASS: light cursor/selection departure stays neutral; hover and dark fills retain their fades")
                Qt.quit()
            }
            test.phase++
        }
    }
}
