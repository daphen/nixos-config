import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes

Item {
    id: root

    readonly property string home: Quickshell.env("HOME")
    property string targetPath: ""

    FileView {
        path: root.home + "/.config/theme_mode"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const mode = (text() || "").trim()
            if (mode === "light" || mode === "dark") {
                resolveProc.command = ["readlink", "-f", root.home + "/.config/themes/wallpaper-" + mode]
                if (!resolveProc.running) resolveProc.running = true
            }
        }
    }

    Process {
        id: resolveProc
        stdout: StdioCollector {
            onStreamFinished: {
                const path = (text || "").trim()
                if (path) root.targetPath = path
            }
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: panel
            required property var modelData
            screen: modelData

            property string displayedPath: ""; property string incomingPath: ""
            property real revealProgress: 1
            property bool finishing: false

            function show(path) {
                if (!path || path === displayedPath && !incomingPath) return
                reveal.stop()
                finishing = false
                if (!displayedPath) {
                    displayedPath = path
                    incomingPath = ""
                    revealProgress = 1
                    return
                }
                incomingPath = path
                revealProgress = 0
            }

            function startReveal() {
                if (!incomingPath || incoming.status !== Image.Ready || reveal.running) return
                reveal.restart()
            }

            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"; exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "wallpaper"
            WlrLayershell.layer: WlrLayer.Background

            Image {
                id: base
                anchors.fill: parent
                source: panel.displayedPath ? "file://" + panel.displayedPath : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true; mipmap: true
                onStatusChanged: {
                    if (status === Image.Ready && panel.finishing) {
                        panel.incomingPath = ""
                        panel.finishing = false
                    }
                }
            }

            Item {
                id: incomingLayer
                anchors.fill: parent
                visible: panel.incomingPath !== "" && incoming.status === Image.Ready
                layer.enabled: panel.incomingPath !== "" && panel.revealProgress < 1
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: revealMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 0.02
                }

                Image {
                    id: incoming
                    anchors.fill: parent
                    source: panel.incomingPath ? "file://" + panel.incomingPath : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true; cache: false
                    smooth: true; mipmap: true
                    onStatusChanged: panel.startReveal()
                }
            }

            Item {
                id: revealMask
                anchors.fill: parent
                visible: false; layer.enabled: true

                readonly property real slant: -0.18
                readonly property real centerTop: width / 2 - slant * height / 2
                readonly property real centerBottom: width / 2 + slant * height / 2
                readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
                readonly property real spread: reach * panel.revealProgress

                Shape {
                    anchors.fill: parent
                    ShapePath {
                        fillColor: "white"
                        strokeColor: "transparent"
                        startX: revealMask.centerTop - revealMask.spread
                        startY: 0
                        PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
                        PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
                        PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
                        PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
                    }
                }
            }

            NumberAnimation {
                id: reveal
                target: panel
                property: "revealProgress"
                from: 0; to: 1
                duration: 420
                easing.type: Easing.InOutCubic
                onFinished: {
                    panel.displayedPath = panel.incomingPath
                    panel.finishing = true
                    panel.revealProgress = 1
                }
            }

            Connections {
                target: root
                function onTargetPathChanged() { panel.show(root.targetPath) }
            }

            Component.onCompleted: show(root.targetPath)
        }
    }
}
