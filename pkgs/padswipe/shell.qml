import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    property var words: []
    property string typed: ""
    property bool drawing: false
    property var trail: []
    property real trailOpacity: 1
        property var dots: ({ L: null, R: null })
    readonly property var rows: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    readonly property var off: [0, 0.25, 0.75]
    readonly property var region: ({ L: [0, 5.75], R: [5, 10] })
    readonly property string leftKeys: "qwertasdfgzxcvb"
    readonly property var symbols: ["1234567890", "@#$%&*-+=/", "!?.,:;'\"()"]
    property bool sym: false
    property string shift: "off"

    Process {
        running: true
        command: ["python3", Quickshell.env("PADSWIPE_DIR") + "/padswipe.py",
            Quickshell.env("PADSWIPE_DECODER"), Quickshell.env("PADSWIPE_ASSETS"), Quickshell.env("XDG_RUNTIME_DIR") + "/padswipe.log"]
        stdout: SplitParser {
            onRead: line => {
                const e = JSON.parse(line)
                if (e.type === "pt" || e.type === "up") {
                    const d = Object.assign({}, root.dots)
                    d[e.side] = e.type === "pt" ? e : null
                    root.dots = d
                } else if (e.type === "trail") {
                    root.trail.push([e.x, e.y, e.new, e.side]); root.trailChanged()
                } else if (e.type === "draw") {
                    root.drawing = e.on
                    if (e.on) { trailFade.stop(); root.trail = []; root.trailOpacity = 1 } else trailFade.start()
                } else if (e.type === "text") {
                    root.typed = e.text
                } else if (e.type === "mode") {
                    root.sym = e.sym; root.shift = e.shift
                } else if (e.type === "word") {
                    root.words = e.words
                }
            }
        }
        stderr: SplitParser { onRead: line => console.error(line) }
        onExited: Qt.quit()
    }

    NumberAnimation { id: trailFade; target: root; property: "trailOpacity"; to: 0; duration: 220; easing.type: Easing.OutCubic }

    PanelWindow {
        anchors { left: true; right: true; bottom: true }
        implicitHeight: 540
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "padswipe"
        mask: Region {}

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 0
            width: parent.width - 40; height: 60; radius: 14
            color: "#ee111111"; border.color: "#44ffffff"
            Text {
                anchors { fill: parent; leftMargin: 18; rightMargin: 18 }
                verticalAlignment: Text.AlignVCenter
                color: root.typed ? "white" : "#77ffffff"; font.pixelSize: 24
                elide: Text.ElideLeft
                text: root.typed ? root.typed + "▏" : "your message appears here"
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 68
            width: resultText.implicitWidth + 40; height: 70; radius: 14
            color: root.drawing ? "#dde8592a" : "#dd111111"; border.color: "#e8592a"
            Text {
                id: resultText
                anchors.centerIn: parent
                color: "white"; font.pixelSize: 30; font.family: "monospace"
                text: root.drawing ? "drawing…" : root.words.length ? root.words[0] + "   " + root.words.slice(1).join(" · ") : "–"
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter; y: 142
            width: help.implicitWidth + 24; height: help.implicitHeight + 10; radius: 8; color: "#ee111111"
        }
        Text {
            id: help
            anchors.horizontalCenter: parent.horizontalCenter; y: 147
            color: "#ddffffff"; font.pixelSize: 15; font.family: "monospace"
            style: Text.Outline; styleColor: "black"
            text: "LT = left pen, RT = right pen · tap a trigger = that letter · hold + slide = swipe a word\nA send   X delete   B space   LB shift (twice = caps lock)   RB symbols   D-pad ◀ ▶ pick word   ☰ close"
            horizontalAlignment: Text.AlignHCenter
        }

        Repeater {
            model: ["L", "R"]
            delegate: Rectangle {
                id: pad
                required property string modelData
                readonly property real span: root.region[modelData][1] - root.region[modelData][0]
                readonly property real unit: width / span
                width: 470; height: 3 * unit
                x: modelData === "L" ? 20 : parent.width - width - 20
                y: parent.height - height - 12
                radius: 16; color: "#f0151515"; border.color: root.drawing ? "#e8592a" : "#44ffffff"; border.width: root.drawing ? 3 : 1

                Repeater {
                    model: 3
                    delegate: Repeater {
                        id: rowRep
                        required property int index
                        readonly property int r: index
                        model: root.sym ? 10 : root.rows[r].length
                        delegate: Rectangle {
                            required property int index
                            readonly property string ch: root.sym ? root.symbols[rowRep.r][index] : root.rows[rowRep.r][index]
                            readonly property bool mine: root.sym ? (index < 5) === (pad.modelData === "L")
                                : (root.leftKeys.indexOf(ch) >= 0) === (pad.modelData === "L")
                            visible: mine
                            x: ((root.sym ? 0 : root.off[rowRep.r]) + index - root.region[pad.modelData][0]) * pad.unit + 3
                            y: rowRep.r * pad.unit + 3
                            width: pad.unit - 6; height: pad.unit - 6; radius: 8
                            color: "#30ffffff"
                            Text { anchors.centerIn: parent; text: root.sym || root.shift !== "off" ? parent.ch.toUpperCase() : parent.ch; color: root.shift === "lock" && !root.sym ? "#e8592a" : "#ddffffff"; font.pixelSize: 26 }
                        }
                    }
                }
                clip: true
                Canvas {
                    id: trailCanvas
                    anchors.fill: parent
                    z: 5
                    opacity: root.trailOpacity
                    Connections { target: root; function onTrailChanged() { trailCanvas.requestPaint() } }
                    onPaint: {
                        const g = getContext("2d"); g.reset()
                        if (!root.trail.length) return
                        g.strokeStyle = "#e8592a"; g.lineWidth = 6; g.lineCap = "round"; g.lineJoin = "round"
                        const a = root.region[pad.modelData][0]
                        const lines = []
                        root.trail.forEach(p => {
                            if (p[3] !== pad.modelData) return
                            if (p[2] || !lines.length) lines.push([])
                            lines[lines.length - 1].push([(p[0] - a) * pad.unit, p[1] * pad.unit])
                        })
                        g.beginPath()
                        lines.forEach(l => {
                            g.moveTo(l[0][0], l[0][1])
                            for (let i = 1; i < l.length - 1; i++)
                                g.quadraticCurveTo(l[i][0], l[i][1], (l[i][0] + l[i + 1][0]) / 2, (l[i][1] + l[i + 1][1]) / 2)
                            const z = l[l.length - 1]; g.lineTo(z[0], z[1])
                        })
                        g.stroke()
                    }
                }
                Rectangle {
                    z: 6
                    readonly property var d: root.dots[pad.modelData]
                    visible: !!d
                    width: 22; height: 22; radius: 11
                    color: d && d.owner ? "#e8592a" : "#88e8592a"
                    x: d ? (d.x - root.region[pad.modelData][0]) * pad.unit - 11 : 0
                    y: d ? d.y * pad.unit - 11 : 0
                }
            }
        }
    }
}
