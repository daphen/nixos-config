import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

// GPU mesh/streak wallpaper editor. The preview IS the renderer — a
// fragment shader with every knob bound as a uniform, so it updates at
// display refresh rate and Save grabs the identical shader at 4K.
FloatingWindow {
    id: win
    title: "wallpaper-studio"
    implicitWidth: 1340
    implicitHeight: 720
    color: "#181818"

    property string mode: "dark"
    property string style: "mesh"
    property int seed: 42
    property int waveAmp: 50
    property int waveLen: 1600
    property int swirl: 30
    property int blurV: 80
    property real grain: 0.12
    property int angle: 25
    property int streak: 220
    property real chrome: 0.5
    property int aberration: 6
    property string status: ""
    property int selected: 0
    property int anchorsRev: 0

    ListModel { id: anchorsModel }
    function touchAnchors() { anchorsRev++; saveState() }

    // ── persistence ─────────────────────────────────────────────────
    FileView {
        id: stateFile
        path: Quickshell.env("HOME") + "/.local/state/wallpaper-studio.json"
    }
    function saveState() {
        const a = []
        for (let i = 0; i < anchorsModel.count; i++) {
            const x = anchorsModel.get(i)
            a.push({ ax: x.ax, ay: x.ay, hex: x.hex, size: x.size })
        }
        const st = { mode: mode, style: style, seed: seed, waveAmp: waveAmp,
                     waveLen: waveLen, swirl: swirl, blurV: blurV, grain: grain,
                     angle: angle, streak: streak, chrome: chrome,
                     aberration: aberration, anchors: a }
        try { stateFile.setText(JSON.stringify(st)) } catch (e) {}
    }
    function restoreState() {
        try {
            const st = JSON.parse(stateFile.text())
            mode = st.mode; style = st.style; seed = st.seed
            waveAmp = st.waveAmp; waveLen = st.waveLen; swirl = st.swirl
            blurV = st.blurV; grain = st.grain; angle = st.angle; streak = st.streak
            if (st.chrome !== undefined) chrome = st.chrome
            if (st.aberration !== undefined) aberration = st.aberration
            anchorsModel.clear()
            for (const x of st.anchors) anchorsModel.append(x)
            return anchorsModel.count >= 2
        } catch (e) { return false }
    }
    Component.onCompleted: {
        if (!restoreState()) resetAnchors()
        anchorsRev++
    }
    function resetAnchors() {
        anchorsModel.clear()
        if (style === "flow") {
            const cols = mode === "dark"
                ? ["#181818", "#CCD5E4", "#396171", "#181818", "#FF570D"]
                : ["#FFFFFF", "#396171", "#0284C7", "#F4F5F2", "#e16511"]
            const pos = [[0.15, 0.2], [0.6, 0.1], [0.85, 0.5], [0.35, 0.75], [0.75, 0.9]]
            for (let i = 0; i < 5; i++)
                anchorsModel.append({ ax: pos[i][0], ay: pos[i][1], hex: cols[i], size: 0.9 + (i % 2) * 0.4 })
            selected = 0
            touchAnchors()
            return
        }
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
        touchAnchors()
    }

    // ── theme palette swatches ──────────────────────────────────────
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

    // ── uniforms ────────────────────────────────────────────────────
    function anchorVec(i) {
        anchorsRev
        if (i >= anchorsModel.count) return Qt.vector4d(0, 0, 0, 0)
        const a = anchorsModel.get(i)
        const sz = a.size * (style === "streaks" ? 0.45 : 1.0)   // flow keeps full fields
        return Qt.vector4d(a.ax, a.ay, sz, 1)
    }
    function colorVec(i) {
        anchorsRev
        if (i >= anchorsModel.count) return Qt.vector4d(0, 0, 0, 1)
        const c = Qt.color(anchorsModel.get(i).hex)
        return Qt.vector4d(c.r, c.g, c.b, 1)
    }
    readonly property vector4d stageColor: {
        const c = Qt.color(mode === "dark" ? "#181818" : "#FFFFFF")
        const f = (style === "streaks" && mode === "dark") ? 0.25 : 1.0
        return Qt.vector4d(c.r * f, c.g * f, c.b * f, 1)
    }

    function setPath() {
        return Quickshell.env("HOME") + "/Pictures/Wallpapers/generated/gl-" + mode + "-" +
               seed + "-" + Math.floor(Math.random() * 100000) + ".png"
    }
    Process { id: applyProc }
    function save4k(andSet) {
        const out = setPath()
        win.status = "rendering 4K…"
        fx.grabToImage(function (res) {
            if (!res.saveToFile(out)) { win.status = "save failed"; return }
            win.status = "saved ✓"
            statusClear.restart()
            if (andSet) {
                // setsid: waypaper/swaybg must survive this Process's exit —
                // plain & left them in our process group and they died with
                // it (both monitors went bare-backdrop gray).
                applyProc.command = ["bash", "-c",
                    "ln -sf '" + out + "' \"$HOME/.config/themes/wallpaper-" + win.mode + "\"; " +
                    "if [ \"$(cat \"$HOME/.config/theme_mode\")\" = '" + win.mode + "' ]; then " +
                    "pkill -x swaybg; setsid waypaper --wallpaper '" + out + "' >/dev/null 2>&1 </dev/null & fi"]
                applyProc.running = true
            }
        }, Qt.size(3840, 2400))
    }
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

        // ── live shader preview + draggable anchors ─────────────────
        Rectangle {
            id: stage
            width: parent.width - panel.width; height: parent.height
            color: "#101010"

            readonly property real fitW: Math.min(width - 28, (height - 28) * 1.6)
            readonly property real fitH: fitW / 1.6
            readonly property real ox: (width - fitW) / 2
            readonly property real oy: (height - fitH) / 2

            ShaderEffect {
                id: fx
                x: stage.ox; y: stage.oy
                width: stage.fitW; height: stage.fitH
                fragmentShader: "file://" + Quickshell.env("HOME") + "/.config/themes/wallpaper.frag.qsb"

                property vector4d a0: win.anchorVec(0)
                property vector4d a1: win.anchorVec(1)
                property vector4d a2: win.anchorVec(2)
                property vector4d a3: win.anchorVec(3)
                property vector4d a4: win.anchorVec(4)
                property vector4d a5: win.anchorVec(5)
                property vector4d a6: win.anchorVec(6)
                property vector4d a7: win.anchorVec(7)
                property vector4d c0: win.colorVec(0)
                property vector4d c1: win.colorVec(1)
                property vector4d c2: win.colorVec(2)
                property vector4d c3: win.colorVec(3)
                property vector4d c4: win.colorVec(4)
                property vector4d c5: win.colorVec(5)
                property vector4d c6: win.colorVec(6)
                property vector4d c7: win.colorVec(7)
                property vector4d baseColor: win.stageColor
                property real styleMode: win.style === "streaks" ? 1 : win.style === "flow" ? 2 : 0
                property real modeLight: win.mode === "light" ? 1 : 0
                property real waveAmp: win.waveAmp
                property real waveLen: win.waveLen
                property real swirlDeg: win.swirl
                property real blurK: win.blurV
                property real grainAmt: win.grain
                property real angleDeg: win.angle
                property real streakLen: win.streak
                property real aberr: win.aberration
                property real seedF: win.seed
                property real chromeAmt: win.chrome
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onDoubleTapped: e => {
                    const u = (e.position.x - stage.ox) / stage.fitW
                    const v = (e.position.y - stage.oy) / stage.fitH
                    if (u < 0 || u > 1 || v < 0 || v > 1) return
                    if (anchorsModel.count >= 8) return
                    anchorsModel.append({ ax: u, ay: v, hex: win.palette[0] || "#888888", size: 1.0 })
                    win.selected = anchorsModel.count - 1
                    win.touchAnchors()
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
                            win.touchAnchors()
                        }
                        onWheel: wheel => {
                            win.selected = handle.index
                            const d = wheel.angleDelta.y > 0 ? 0.1 : -0.1
                            const ns = Math.max(0.2, Math.min(3, handle.size + d))
                            anchorsModel.setProperty(handle.index, "size", ns)
                            win.touchAnchors()
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
                        TapHandler { onTapped: { win.mode = parent.modelData; win.resetAnchors() } }
                    }
                }
            }
            Row {
                spacing: 8
                Repeater {
                    model: ["mesh", "streaks", "flow"]
                    Rectangle {
                        required property string modelData
                        width: 74; height: 26; radius: 13
                        color: win.style === modelData ? "#EDEDED" : "#2E2E2E"
                        Text { anchors.centerIn: parent; text: parent.modelData
                               color: win.style === parent.modelData ? "#181818" : "#EDEDED"; font.pixelSize: 12; font.family: "Geist" }
                        TapHandler { onTapped: { win.style = parent.modelData; win.resetAnchors() } }
                    }
                }
            }

            Text { text: "anchor " + (win.selected + 1) + " / " + anchorsModel.count + " — drag to move, scroll to resize, double-click canvas to add (max 8)"
                   width: 284; wrapMode: Text.WordWrap; color: "#707B84"; font.pixelSize: 11; font.family: "Geist" }

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
                            win.touchAnchors()
                        } }
                    }
                }
            }

            Knob {
                label: "anchor size"
                from: 0.2; to: 3; step: 0.05
                value: anchorsModel.count > win.selected ? anchorsModel.get(win.selected).size : 1
                onMoved: v => { anchorsModel.setProperty(win.selected, "size", v); win.touchAnchors() }
            }

            Row {
                spacing: 8
                Chip { label: "remove anchor"; onClicked: {
                    if (anchorsModel.count <= 2) return
                    anchorsModel.remove(win.selected)
                    win.selected = Math.max(0, win.selected - 1)
                    win.touchAnchors()
                } }
                Chip { label: "reset"; onClicked: win.resetAnchors() }
            }

            Rectangle { width: 284; height: 1; color: "#2E2E2E" }

            Knob { visible: win.style !== "mesh"; label: "chrome"; from: 0; to: 1; step: 0.02; value: win.chrome; onMoved: v => { win.chrome = v; win.saveState() } }
            Knob { visible: win.style !== "mesh"; label: "chromatic shift"; from: 0; to: 20; step: 1; value: win.aberration; onMoved: v => { win.aberration = v; win.saveState() } }
            Knob { visible: win.style !== "mesh"; label: "streak length"; from: 40; to: 400; step: 5; value: win.streak; onMoved: v => { win.streak = v; win.saveState() } }
            Knob { visible: win.style !== "mesh"; label: "angle"; from: -60; to: 60; step: 1; value: win.angle; onMoved: v => { win.angle = v; win.saveState() } }
            Knob { label: "wave amplitude"; from: 0; to: 160; step: 1; value: win.waveAmp; onMoved: v => { win.waveAmp = v; win.saveState() } }
            Knob { label: "wave length"; from: 300; to: 3000; step: 10; value: win.waveLen; onMoved: v => { win.waveLen = v; win.saveState() } }
            Knob { label: "swirl"; from: -180; to: 180; step: 1; value: win.swirl; onMoved: v => { win.swirl = v; win.saveState() } }
            Knob { visible: win.style === "mesh"; label: "softness"; from: 10; to: 220; step: 1; value: win.blurV; onMoved: v => { win.blurV = v; win.saveState() } }
            Knob { label: "grain"; from: 0; to: 0.5; step: 0.01; value: win.grain; onMoved: v => { win.grain = v; win.saveState() } }

            Item { width: 1; height: 6 }

            Row {
                spacing: 8
                Rectangle {
                    width: 120; height: 30; radius: 15; color: "#EDEDED"
                    Text { anchors.centerIn: parent; text: "Save 4K"; color: "#181818"; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                    TapHandler { onTapped: win.save4k(false) }
                }
                Rectangle {
                    width: 120; height: 30; radius: 15; color: "#2E2E2E"
                    Text { anchors.centerIn: parent; text: "Save + Set"; color: "#EDEDED"; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                    TapHandler { onTapped: win.save4k(true) }
                }
            }
            Text { text: win.status; color: "#97B5A6"; font.pixelSize: 12; font.family: "Geist" }
        }
    }
}
