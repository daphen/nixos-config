import QtQuick
import QtQuick.Effects
import Quickshell
import "."
import "../QsLib" as Lib

PanelWindow {
    id: bar

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight
    color: "transparent"

    // Outer = hairline-colored backdrop. Inner = notch fill, flush on top
    // (no top border) but inset 1px on left/right/bottom so those 3 edges
    // show as borders, including following the bottom rounded corners.
    Rectangle {
        id: notch
        anchors {
            top: parent.top
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
        }
        width: Math.max(
            leftGroup.implicitWidth + rightGroup.implicitWidth
                + centerGroup.implicitWidth + Theme.notchInnerGap * 2 + Theme.notchPadH * 2,
            Theme.notchMinWidth
        )

        color: Theme.hairline
        topLeftRadius:     0
        topRightRadius:    0
        bottomLeftRadius:  Theme.notchRadius
        bottomRightRadius: Theme.notchRadius

        Rectangle {
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                leftMargin: 1
                rightMargin: 1
                bottomMargin: 1
            }
            color: Theme.notch
            topLeftRadius:     0
            topRightRadius:    0
            bottomLeftRadius:  Theme.notchRadius - 1
            bottomRightRadius: Theme.notchRadius - 1
        }

        Row {
            id: leftGroup
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
                leftMargin: Theme.notchPadH
            }
            spacing: 8

            DateText {}
            Weather {}
            Cpu {}
            Memory {}
        }

        Row {
            id: centerGroup
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: parent.top
                bottom: parent.bottom
            }
            spacing: 0

            Minimap { output: bar.screen ? bar.screen.name : "" }
        }

        Row {
            id: rightGroup
            anchors {
                right: parent.right
                top: parent.top
                bottom: parent.bottom
                rightMargin: Theme.notchPadH
            }
            spacing: 8

            CockpitChips {}
            Inbox {}
            Dnd {}
            Network {}
            Audio {}
            Battery {}
            Clock {}
        }
    }

    readonly property string worktreeStack: {
        const _ = NiriState.version
        // per-output: THIS screen's visible workspace, not the global focus —
        // the badge must not mirror onto the other monitor's bar
        const name = NiriState.activeWorkspaceName(bar.screen ? bar.screen.name : "")
        if (name.startsWith("lovable-")) return name.substring("lovable-".length)
        return name
    }

    // WPM pill — top-left corner, transparent, inverted (bg-colored) content.
    Rectangle {
        id: wpmPill
        anchors {
            top: parent.top
            left: parent.left
        }
        width: wpmPillRow.implicitWidth + Theme.notchPadH * 2
        height: Theme.barHeight
        color: "transparent"

        Row {
            id: wpmPillRow
            anchors.centerIn: parent
            // Matches the notch's effective inter-module gap:
            // modulePadH + group spacing + modulePadH.
            spacing: Theme.modulePadH * 2 + 8

            Row {
                spacing: 8
                anchors.verticalCenter: parent.verticalCenter

                Lib.Icon {
                    name: "keyboard"
                    color: Theme.bg
                    width: 15; height: 15
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    visible: WpmState.value === 0
                    text: "∞"
                    color: Theme.bg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 7
                    font.weight: Theme.fontWeight
                    font.hintingPreference: Font.PreferFullHinting
                    anchors.verticalCenter: parent.verticalCenter
                    // The glyph sits in the x-height band; its box's empty
                    // descender space makes true-center look high.
                    anchors.verticalCenterOffset: 1
                }

                Text {
                    text: (WpmState.value > 0 ? WpmState.value + " " : "") + "wpm"
                    color: Theme.bg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.weight: Theme.fontWeight
                    font.hintingPreference: Font.PreferFullHinting
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Item {
                visible: SpendState.current >= 0
                width: spendRow.implicitWidth
                height: spendRow.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                Row {
                    id: spendRow
                    spacing: 8

                    // the Claude spark — same brand asset as its notifications
                    Item {
                        width: 15; height: 15
                        anchors.verticalCenter: parent.verticalCenter
                        Image {
                            id: claudeGlyph
                            anchors.fill: parent
                            source: Qt.resolvedUrl("../assets/claude.svg")
                            sourceSize.width: 15; sourceSize.height: 15
                            visible: false
                            asynchronous: true
                        }
                        MultiEffect {
                            anchors.fill: claudeGlyph
                            source: claudeGlyph
                            colorization: 1
                            colorizationColor: Theme.bg
                        }
                    }

                    Text {
                        text: {
                            const v = SpendState.current
                            const amount = v >= 1000
                                ? (v / 1000).toFixed(1) + "k"
                                : v >= 100 ? Math.round(v)
                                : v >= 10 ? v.toFixed(1)
                                : v.toFixed(2)
                            const tag = SpendState.mode === "day" ? "d"
                                : SpendState.mode === "month" ? "m" : "∀"
                            return "$" + amount + " " + tag
                        }
                        color: Theme.bg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.weight: Theme.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: SpendState.cycle()
                }
            }

            Item {
                visible: TodoListPickerState.openCount > 0
                width: todoRow.implicitWidth
                height: todoRow.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                Row {
                    id: todoRow
                    spacing: 8

                    Lib.Icon {
                        name: "clipboard-check"
                        color: Theme.bg
                        width: 15; height: 15
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: TodoListPickerState.openCount
                        color: Theme.bg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.weight: Theme.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: TodoListPickerState.toggle()
                }
            }

            Item {
                visible: TimerState.items.length > 0
                width: timerRow.implicitWidth
                height: timerRow.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                // Rung state: red pulsing chip behind the entry — a silent
                // vanish + notification alone is missable. Click dismisses.
                Rectangle {
                    visible: TimerState.ringing
                    anchors.verticalCenter: parent.verticalCenter
                    x: -7
                    width: timerRow.implicitWidth + 14
                    height: 24
                    radius: 8
                    color: Theme.red
                    SequentialAnimation on opacity {
                        running: TimerState.ringing
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.45; duration: 450; easing.type: Easing.InOutQuad }
                        NumberAnimation { to: 1.0;  duration: 450; easing.type: Easing.InOutQuad }
                    }
                }

                Row {
                    id: timerRow
                    spacing: 8

                    Lib.Icon {
                        name: "timer-2"
                        color: TimerState.ringing ? Theme.fg : Theme.bg
                        width: 15; height: 15
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: {
                            if (TimerState.items.length === 0) return ""
                            if (TimerState.ringing) {
                                const r = TimerState.items.find(t => t.rang)
                                return (r && r.label ? r.label + " " : "") + "0:00"
                            }
                            return TimerState.fmt(TimerState.items[0].end - TimerState.now)
                                + (TimerState.items.length > 1 ? " +" + (TimerState.items.length - 1) : "")
                        }
                        color: TimerState.ringing ? Theme.fg : Theme.bg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.weight: Theme.fontWeight
                        font.hintingPreference: Font.PreferFullHinting
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: TimerState.ringing ? TimerState.dismissRung() : TimerState.toggle()
                }
            }
        }
    }

    // Worktree pill — top-right corner, transparent, inverted (bg-colored) content.
    Rectangle {
        id: worktreePill
        anchors {
            top: parent.top
            right: parent.right
        }
        visible: bar.worktreeStack.length > 0
        width: pillRow.implicitWidth + Theme.notchPadH * 2
        height: Theme.barHeight
        color: "transparent"

        Row {
            id: pillRow
            anchors.centerIn: parent
            // Matches the notch's effective inter-module gap:
            // modulePadH + group spacing + modulePadH.
            spacing: Theme.modulePadH * 2 + 8

            Row {
                spacing: 8
                anchors.verticalCenter: parent.verticalCenter

                Image {
                    source: "file://" + Quickshell.env("HOME") + "/.local/share/icons/hicolor/512x512/apps/lovable.png"
                    sourceSize.width: 16
                    sourceSize.height: 16
                    width: 16
                    height: 16
                    smooth: true
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: bar.worktreeStack
                    color: Theme.bg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.weight: Theme.fontWeight
                    font.hintingPreference: Font.PreferFullHinting
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // plan-ticket state for this worktree: phase icon + steps done
            Row {
                spacing: 8
                visible: PlanState.available
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    text: PlanState.icon
                    color: Theme.bg
                    font.family: Theme.iconFontFamily
                    font.pixelSize: Theme.fontSize + 2
                    font.weight: Theme.fontWeight
                    font.hintingPreference: Font.PreferFullHinting
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    visible: PlanState.total > 0
                    text: PlanState.done + "/" + PlanState.total
                    color: Theme.bg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.weight: Theme.fontWeight
                    font.hintingPreference: Font.PreferFullHinting
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
