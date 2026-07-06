import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

// Live mesh-gradient editor over generate-wallpaper.sh. Anchors are
// draggable handles on the preview; select one to resize it or paint it
// with a theme color. Save renders 4K with the same spec.
FloatingWindow {
    id: win
    title: "wallpaper-studio"
    implicitWidth: 1340
    implicitHeight: 720
    color: "#181818"

    property string mode: "dark"
    property string style: "mesh"
    property int angle: 25
    property int streak: 220
    property int seed: 42
    property int waveAmp: 50
    property int waveLen: 1600
    property int swirl: 30
    property int blurV: 80
    property real grain: 0.12
    property bool rendering: false
    property string status: ""
    property int selected: 0

    ListModel { id: anchorsModel }
    Component.onCompleted: {
        resetAnchors()
        render()
    }
    function resetAnchors() {
        anchorsModel.clear()
        if (style === "streaks") {
            const hot = mode === "dark"
                ? ["#FFFFFF", "#FF570D", "#7DD3FC", "#CCD5E4", "#FFFFFF", "#FF570D"]
                : ["#e16511", "#0284C7", "#396171", "#e16511", "#0284C7", "#243560"]
            const pos = [[0.2, 0.25], [0.55, 0.15], [0.8, 0.35], [0.35, 0.6], [0.65, 0.75], [0.15, 0.8]]
            for (let i = 0; i < 6; i++)
                anchorsModel.append({ ax: pos[i][0], ay: pos[i][1], hex: hot[i], size: 0.5 + (i % 3) * 0.15 })
        } else {
            const base = mode === "dark" ? "#181818" : "#FFFFFF"
            const a1 = mode === "dark" ? "#FF570D" : "#df9001"
            const a2 = mode === "dark" ? "#97B5A6" : "#5E7270"
            anchorsModel.append({ ax: 0.25, ay: 0.3, hex: base, size: 1.4 })
            anchorsModel.append({ ax: 0.75, ay: 0.7, hex: base, size: 1.2 })
            anchorsModel.append({ ax: 0.7, ay: 0.2, hex: a1, size: 0.8 })
            anchorsModel.append({ ax: 0.3, ay: 0.8, hex: a2, size: 0.9 })
        }
        selected = 0
    }

    // Theme palette swatches, read live from colors.json.
    FileView {
        id: colorsFile
        path: Quickshell.env("HOME") + "/.config/themes/colors.json"
        watchChanges: true
    }
    readonly property var palette: {
        try {
            const t = JSON.parse(colorsFile.text())["themes"][mode]
            const out = []
            for (const k of ["primary", "secondary", "tertiary", "selection", "overlay", "prompt"])
                if (t.background[k]) out.push(t.background[k])
            for (const k in t.accent) out.push(t.accent[k])
            return out
        } catch (e) { return ["#181818", "#FFFFFF", "#FF570D"] }
    }

    readonly property string script: Quickshell.env("HOME") + "/.config/themes/generate-wallpaper.sh"
    readonly property string previewPath: "/tmp/wallpaper-studio-preview.png"

    function anchorSpec() {
        const parts = []
        for (let i = 0; i < anchorsModel.count; i++) {
            const a = anchorsModel.get(i)
            parts.push(a.ax.toFixed(3) + "," + a.ay.toFixed(3) + "," + a.hex + "," + a.size.toFixed(2))
        }
        return parts.join(";")
    }
    function args(size, out, extra) {
        return [script, mode, "--seed", String(seed),
                "--wave-amp", String(waveAmp), "--wave-len", String(waveLen),
                "--swirl", String(swirl), "--blur", String(blurV),
                "--grain", grain.toFixed(2),
                "--anchor-spec", anchorSpec(),
                "--style", style, "--angle", String(angle), "--streak", String(streak),
                "--size", size]
               .concat(out ? ["--out", out] : [])
               .concat(extra || [])
    }

    // React-state feel: every change kills the in-flight render and starts a
    // fast draft (work-res 480, ~0.4-1s) so the preview chases the latest
    // state; a full-quality pass settles in once you stop touching things.
    property bool settlePass: false
    // Generation-keyed renders: each render writes its own slot and only the
    // newest generation is allowed to reach the screen — a straggler from an
    // aborted render can never overwrite a newer preview.
    property int rgen: 0
    property int shownGen: -1
    function slotPath(g) { return win.previewPath + "." + (g % 8) + ".png" }
    function launch(fast) {
        if (proc.running) proc.running = false
        win.rgen++
        win.rendering = true
        proc.command = win.args("960x600", win.slotPath(win.rgen),
                                fast ? ["--work-res", "480"] : [])
        proc.running = true
    }
    function render() { debounce.restart() }
    Timer {
        id: debounce
        interval: 60
        onTriggered: {
            win.settlePass = false
            win.launch(true)
        }
    }
    Process {
        id: proc
        onExited: (code, status) => {
            win.rendering = false
            if (code !== 0) return              // aborted by a newer change
            if (debounce.running) return        // a newer change is queued
            win.shownGen = win.rgen
            previewImg.source = ""
            previewImg.source = "file://" + win.slotPath(win.rgen)
            if (!win.settlePass) settle.restart()
        }
    }
    Timer {
        id: settle
        interval: 500
        onTriggered: {
            if (debounce.running || proc.running) { settle.restart(); return }
            win.settlePass = true
            win.launch(false)
        }
    }
    Process { id: saveProc; onExited: { win.status = "saved ✓"; statusClear.restart() } }
    Timer { id: statusClear; interval: 2500; onTriggered: win.status = "" }

    component Knob: Column {
        property string label
        property alias value: sl.value
        property alias from: sl.from
        property alias to: sl.to
        property alias step: sl.stepSize
        signal moved(real v)
        width: 284
        spacing: 2
        Text { text: label + "  " + Math.round(sl.value * 100) / 100; color: "#EDEDED"; font.pixelSize: 12; font.family: "Geist" }
        Slider {
            id: sl; width: parent.width
            onMoved: parent.moved(value)
        }
    }
    component Chip: Rectangle {
        property string label
        signal clicked()
        width: chipText.implicitWidth + 20; height: 26; radius: 13; color: "#2E2E2E"
        Text { id: chipText; anchors.centerIn: parent; text: parent.label; color: "#EDEDED"; font.pixelSize: 12; font.family: "Geist" }
        TapHandler { onTapped: parent.clicked() }
    }

    Row {
        anchors.fill: parent

        // ── preview + draggable anchors ─────────────────────────────
        Rectangle {
            id: stage
            width: parent.width - panel.width; height: parent.height
            color: "#101010"

            // fitted 16:10 rect the preview occupies (source is 960x600)
            readonly property real fitW: Math.min(width - 28, (height - 28) * 1.6)
            readonly property real fitH: fitW / 1.6
            readonly property real ox: (width - fitW) / 2
            readonly property real oy: (height - fitH) / 2

            Image {
                id: previewImg
                x: stage.ox; y: stage.oy
                width: stage.fitW; height: stage.fitH
                fillMode: Image.Stretch
                cache: false
                Rectangle {
                    visible: win.rendering
                    anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                    width: 10; height: 10; radius: 5; color: "#FF570D"
                }
            }

            // double-click empty canvas: add an anchor there
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onDoubleTapped: e => {
                    const u = (e.position.x - stage.ox) / stage.fitW
                    const v = (e.position.y - stage.oy) / stage.fitH
                    if (u < 0 || u > 1 || v < 0 || v > 1) return
                    anchorsModel.append({ ax: u, ay: v, hex: win.palette[0] || "#888888", size: 1.0 })
                    win.selected = anchorsModel.count - 1
                    win.render()
                }
            }

            Repeater {
                model: anchorsModel
                Rectangle {
                    id: handle
                    required property int index
                    required property real ax
                    required property real ay
                    required property string hex
                    required property real size
                    readonly property bool isSel: win.selected === index
                    width: 16 + size * 14; height: width; radius: width / 2
                    x: stage.ox + ax * stage.fitW - width / 2
                    y: stage.oy + ay * stage.fitH - height / 2
                    color: hex
                    border.width: isSel ? 3 : 1
                    border.color: isSel ? "#FF570D" : "#EDEDED"

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.SizeAllCursor
                        onPressed: win.selected = handle.index
                        onPositionChanged: mouse => {
                            if (!pressed) return
                            const p = mapToItem(stage, mouse.x, mouse.y)
                            const u = Math.max(0, Math.min(1, (p.x - stage.ox) / stage.fitW))
                            const v = Math.max(0, Math.min(1, (p.y - stage.oy) / stage.fitH))
                            anchorsModel.setProperty(handle.index, "ax", u)
                            anchorsModel.setProperty(handle.index, "ay", v)
                            win.render()
                        }
                        onWheel: wheel => {
                            win.selected = handle.index
                            const d = wheel.angleDelta.y > 0 ? 0.1 : -0.1
                            const ns = Math.max(0.2, Math.min(3, handle.size + d))
                            anchorsModel.setProperty(handle.index, "size", ns)
                            win.render()
                        }
                    }
                }
            }
        }

        // ── controls ────────────────────────────────────────────────
        Column {
            id: panel
            width: 320
            padding: 18
            spacing: 10

            Row {
                spacing: 8
                Repeater {
                    model: ["dark", "light"]
                    Rectangle {
                        required property string modelData
                        width: 70; height: 26; radius: 13
                        color: win.mode === modelData ? "#EDEDED" : "#2E2E2E"
                        Text { anchors.centerIn: parent; text: parent.modelData
                               color: win.mode === parent.modelData ? "#181818" : "#EDEDED"; font.pixelSize: 12; font.family: "Geist" }
                        TapHandler { onTapped: { win.mode = parent.modelData; win.resetAnchors(); win.render() } }
                    }
                }
            }

            Row {
                spacing: 8
                Repeater {
                    model: ["mesh", "streaks"]
                    Rectangle {
                        required property string modelData
                        width: 74; height: 26; radius: 13
                        color: win.style === modelData ? "#EDEDED" : "#2E2E2E"
                        Text { anchors.centerIn: parent; text: parent.modelData
                               color: win.style === parent.modelData ? "#181818" : "#EDEDED"; font.pixelSize: 12; font.family: "Geist" }
                        TapHandler { onTapped: { win.style = parent.modelData; win.resetAnchors(); win.render() } }
                    }
                }
            }

            Text { text: "anchor " + (win.selected + 1) + " / " + anchorsModel.count + " — drag to move, scroll to resize, double-click canvas to add"
                   width: 284; wrapMode: Text.WordWrap; color: "#707B84"; font.pixelSize: 11; font.family: "Geist" }

            // theme swatches paint the selected anchor
            Flow {
                width: 284; spacing: 6
                Repeater {
                    model: win.palette
                    Rectangle {
                        required property string modelData
                        width: 30; height: 30; radius: 8
                        color: modelData
                        border.width: anchorsModel.count > win.selected && anchorsModel.get(win.selected).hex === modelData ? 3 : 1
                        border.color: border.width === 3 ? "#FF570D" : "#3A3A3A"
                        TapHandler { onTapped: {
                            anchorsModel.setProperty(win.selected, "hex", parent.modelData)
                            win.render()
                        } }
                    }
                }
            }

            Knob {
                label: "anchor size"
                from: 0.2; to: 3; step: 0.05
                value: anchorsModel.count > win.selected ? anchorsModel.get(win.selected).size : 1
                onMoved: v => { anchorsModel.setProperty(win.selected, "size", v); win.render() }
            }

            Row {
                spacing: 8
                Chip { label: "remove anchor"; onClicked: {
                    if (anchorsModel.count <= 2) return
                    anchorsModel.remove(win.selected)
                    win.selected = Math.max(0, win.selected - 1)
                    win.render()
                } }
                Chip { label: "reset"; onClicked: { win.resetAnchors(); win.render() } }
            }

            Rectangle { width: 284; height: 1; color: "#2E2E2E" }

            Knob { visible: win.style === "streaks"; label: "streak length"; from: 40; to: 400; step: 5; value: win.streak; onMoved: v => { win.streak = v; win.render() } }
            Knob { visible: win.style === "streaks"; label: "angle"; from: -60; to: 60; step: 1; value: win.angle; onMoved: v => { win.angle = v; win.render() } }
            Knob { label: "wave amplitude"; from: 0; to: 160; step: 1; value: win.waveAmp; onMoved: v => { win.waveAmp = v; win.render() } }
            Knob { label: "wave length"; from: 300; to: 3000; step: 10; value: win.waveLen; onMoved: v => { win.waveLen = v; win.render() } }
            Knob { label: "swirl"; from: -180; to: 180; step: 1; value: win.swirl; onMoved: v => { win.swirl = v; win.render() } }
            Knob { label: "blur"; from: 10; to: 220; step: 1; value: win.blurV; onMoved: v => { win.blurV = v; win.render() } }
            Knob { label: "grain"; from: 0; to: 0.5; step: 0.01; value: win.grain; onMoved: v => { win.grain = v; win.render() } }

            Item { width: 1; height: 6 }

            Row {
                spacing: 8
                Rectangle {
                    width: 120; height: 30; radius: 15; color: "#EDEDED"
                    Text { anchors.centerIn: parent; text: "Save 4K"; color: "#181818"; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                    TapHandler { onTapped: {
                        win.status = "rendering 4K…"
                        saveProc.command = win.args("3840x2400", "")
                        saveProc.running = true
                    } }
                }
                Rectangle {
                    width: 120; height: 30; radius: 15; color: "#2E2E2E"
                    Text { anchors.centerIn: parent; text: "Save + Set"; color: "#EDEDED"; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                    TapHandler { onTapped: {
                        win.status = "rendering 4K…"
                        saveProc.command = win.args("3840x2400", "", ["--set"])
                        saveProc.running = true
                    } }
                }
            }
            Text { text: win.status; color: "#97B5A6"; font.pixelSize: 12; font.family: "Geist" }
        }
    }
}
