import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

// Live tuning UI for generate-wallpaper.sh. Sliders re-render a small
// preview (debounced); Save renders the full 4K with the same knobs.
FloatingWindow {
    id: win
    title: "wallpaper-studio"
    implicitWidth: 1280
    implicitHeight: 660
    color: "#181818"

    property string mode: "dark"
    property int seed: 42
    property int waveAmp: 50
    property int waveLen: 1600
    property int swirl: 30
    property int blurV: 80
    property real grain: 0.12
    property bool rendering: false
    property int gen: 0
    property string status: ""

    readonly property string script: Quickshell.env("HOME") + "/.config/themes/generate-wallpaper.sh"
    readonly property string previewPath: "/tmp/wallpaper-studio-preview.png"

    function args(size, out, extra) {
        return [script, mode, "--seed", String(seed),
                "--wave-amp", String(waveAmp), "--wave-len", String(waveLen),
                "--swirl", String(swirl), "--blur", String(blurV),
                "--grain", grain.toFixed(2), "--size", size]
               .concat(out ? ["--out", out] : [])
               .concat(extra || [])
    }

    function render() { debounce.restart() }
    Timer {
        id: debounce
        interval: 160
        onTriggered: {
            if (win.rendering) { debounce.restart(); return }
            win.rendering = true
            proc.command = win.args("960x600", win.previewPath)
            proc.running = true
        }
    }
    Process {
        id: proc
        onExited: {
            win.rendering = false
            // force a reload: file:// URLs ignore query-string cache busters
            previewImg.source = ""
            previewImg.source = "file://" + win.previewPath
        }
    }
    Process { id: saveProc; onExited: { win.status = "saved ✓"; statusClear.restart() } }
    Timer { id: statusClear; interval: 2500; onTriggered: win.status = "" }

    Component.onCompleted: render()

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

    Row {
        anchors.fill: parent

        Rectangle {
            width: parent.width - panel.width; height: parent.height
            color: "#101010"
            Image {
                id: previewImg
                anchors.fill: parent
                anchors.margins: 14
                fillMode: Image.PreserveAspectFit
                cache: false
                Rectangle {
                    visible: win.rendering
                    anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                    width: 10; height: 10; radius: 5; color: "#FF570D"
                }
            }
        }

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
                        TapHandler { onTapped: { win.mode = parent.modelData; win.render() } }
                    }
                }
            }

            Row {
                spacing: 8
                Rectangle {
                    width: 110; height: 26; radius: 13; color: "#2E2E2E"
                    Text { anchors.centerIn: parent; text: "seed " + win.seed; color: "#EDEDED"; font.pixelSize: 12; font.family: "Geist" }
                    TapHandler { onTapped: { win.seed = Math.floor(Math.random() * 32768); win.render() } }
                }
                Text { text: "click to reroll"; color: "#707B84"; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter; font.family: "Geist" }
            }

            Knob { label: "wave amplitude"; from: 0; to: 160; step: 1; value: win.waveAmp; onMoved: v => { win.waveAmp = v; win.render() } }
            Knob { label: "wave length"; from: 300; to: 3000; step: 10; value: win.waveLen; onMoved: v => { win.waveLen = v; win.render() } }
            Knob { label: "swirl"; from: -180; to: 180; step: 1; value: win.swirl; onMoved: v => { win.swirl = v; win.render() } }
            Knob { label: "blur"; from: 10; to: 220; step: 1; value: win.blurV; onMoved: v => { win.blurV = v; win.render() } }
            Knob { label: "grain"; from: 0; to: 0.5; step: 0.01; value: win.grain; onMoved: v => { win.grain = v; win.render() } }

            Item { width: 1; height: 8 }

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
            Text {
                width: 284; wrapMode: Text.WordWrap
                text: "Saves to ~/Pictures/Wallpapers/generated/ as mesh-" + win.mode + "-" + win.seed + ".png. Save+Set also points the theme symlink at it."
                color: "#707B84"; font.pixelSize: 11; font.family: "Geist"
            }
        }
    }
}
