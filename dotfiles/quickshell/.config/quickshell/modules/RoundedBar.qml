import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import "." as Modules
import "../QsLib" as Lib

PanelWindow {
    id: bar

    readonly property bool pickerActive: Modules.ReviewCreatePickerState.open
        || Modules.LovboxPickerState.open
        || Modules.BluetoothPickerState.open
        || Modules.TimerState.open
        || Modules.NetworkPickerState.open
        || Modules.AsusProfilePickerState.open
        || Modules.EmojiPickerState.open
        || Modules.ClaudeRenamePickerState.open
        || Modules.ColorFormatPickerState.open
        || Modules.ClipboardPickerState.open
        || Modules.NotesPickerState.open
        || Modules.TodoListPickerState.open
        || Modules.NotificationJumpPickerState.open
        || Modules.AgentAskState.inputOpen
        || Modules.CockpitState.open
    readonly property var workingRoots: Modules.AgentAskState.workingRoots
    readonly property var workingActivities: {
        const activities = []
        for (const root of workingRoots)
            activities.push(...(root.activities || []))
        return activities
    }
    readonly property real activePickerHeight: Math.max(
        reviewCreatePicker.open ? reviewCreatePicker.implicitHeight : 0,
        lovboxPicker.open ? lovboxPicker.implicitHeight : 0,
        bluetoothPicker.open ? bluetoothPicker.implicitHeight : 0,
        timerPicker.open ? timerPicker.implicitHeight : 0,
        networkPicker.open ? networkPicker.implicitHeight : 0,
        asusProfilePicker.open ? asusProfilePicker.implicitHeight : 0,
        emojiPicker.open ? emojiPicker.implicitHeight : 0,
        claudeRenamePicker.open ? claudeRenamePicker.implicitHeight : 0,
        colorFormatPicker.open ? colorFormatPicker.implicitHeight : 0,
        clipboardPicker.open ? clipboardPicker.implicitHeight : 0,
        notesPicker.open ? notesPicker.implicitHeight : 0,
        todoListPicker.open ? todoListPicker.implicitHeight : 0,
        notificationJumpPicker.open ? notificationJumpPicker.implicitHeight : 0,
        agentAskPicker.open ? agentAskPicker.implicitHeight : 0,
        cockpitPicker.open ? cockpitPicker.implicitHeight : 0
    )

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 800
    exclusiveZone: Modules.Theme.barHeight + 4
    exclusionMode: ExclusionMode.Normal
    color: "transparent"
    WlrLayershell.namespace: "qs-rounded-bar"
    WlrLayershell.keyboardFocus: pickerActive
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None
    mask: Region { item: capsule }

    readonly property string worktreeStack: {
        const _ = Modules.NiriState.version
        const name = Modules.NiriState.activeWorkspaceName(bar.screen ? bar.screen.name : "")
        if (!name.startsWith("lovable-") || name === "lovable-deps") return ""
        return name.substring("lovable-".length)
    }

    Lib.ExpandableContainer {
        id: capsule
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 4
        }
        expanded: bar.pickerActive
        collapsedHeight: Modules.Theme.barHeight
        expandedHeight: Modules.Theme.barHeight + bar.activePickerHeight
        width: Math.min(parent.width - 32, Math.max(
            leftGroup.implicitWidth + rightGroup.implicitWidth
                + centerGroup.implicitWidth + Modules.Theme.notchInnerGap * 2
                + Modules.Theme.notchPadH * 2,
            Modules.Theme.notchMinWidth
        ))
        color: Modules.Theme.hairline

        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: Math.max(0, capsule.radius - 1)
            color: Modules.Theme.notch
        }

        Row {
            id: leftGroup
            height: Modules.Theme.barHeight
            anchors {
                left: parent.left
                top: parent.top
                leftMargin: Modules.Theme.notchPadH + 6
            }
            spacing: 8

            Item {
                visible: Modules.TimerState.items.length > 0
                width: timerRow.implicitWidth
                height: parent.height

                Row {
                    id: timerRow
                    spacing: 8
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "󰔛"
                        color: Modules.TimerState.ringing ? Modules.Theme.red : Modules.Theme.fg
                        font.family: Modules.Theme.iconFontFamily
                        font.pixelSize: Modules.Theme.fontSize + 1
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: {
                            if (Modules.TimerState.items.length === 0) return ""
                            if (Modules.TimerState.ringing) {
                                const ringing = Modules.TimerState.items.find(timer => timer.rang)
                                return (ringing && ringing.label ? ringing.label + " " : "") + "0:00"
                            }
                            return Modules.TimerState.fmt(Modules.TimerState.items[0].end - Modules.TimerState.now)
                                + (Modules.TimerState.items.length > 1 ? " +" + (Modules.TimerState.items.length - 1) : "")
                        }
                        color: Modules.TimerState.ringing ? Modules.Theme.red : Modules.Theme.fg
                        font.family: Modules.Theme.fontFamily
                        font.pixelSize: Modules.Theme.fontSize
                        font.weight: Modules.Theme.fontWeight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Modules.TimerState.ringing
                        ? Modules.TimerState.dismissRung()
                        : Modules.TimerState.toggle()
                }
            }

            Modules.DateText {}
            Modules.Weather {}
            Modules.Cpu {}
            Modules.Memory {}

            Lib.Crossfade {
                id: activitySwap
                visible: Modules.TodoListPickerState.openCount > 0 || bar.workingActivities.length > 0
                width: Math.max(18, quickNotes.implicitWidth)
                height: parent.height
                showSecond: bar.workingActivities.length > 0
                enterDuration: 250
                exitDuration: 250
                shift: 8

                first: Modules.Todos {
                    id: quickNotes
                    anchors.centerIn: parent
                    enabled: bar.workingActivities.length === 0
                }

                second: Lib.ThinkingOrb {
                    width: 18
                    height: 18
                    anchors.centerIn: parent
                    running: bar.workingActivities.length > 0
                    seedKey: "rounded-bar-aggregate"
                    glow: Lib.AgentActivity.colorFor(bar.workingActivities[0])
                    activityColors: Lib.AgentActivity.colorsFor(bar.workingActivities)
                }
            }
        }

        Row {
            id: centerGroup
            height: Modules.Theme.barHeight
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: parent.top
            }

            Modules.Minimap { output: bar.screen ? bar.screen.name : "" }
        }

        Row {
            id: rightGroup
            height: Modules.Theme.barHeight
            anchors {
                right: parent.right
                top: parent.top
                rightMargin: Modules.Theme.notchPadH + 6
            }
            spacing: 8

            Modules.Inbox {}
            Modules.Dnd {}
            Modules.Network {}
            Modules.Audio {}
            Modules.Battery {}
            Modules.Clock {}

            Row {
                visible: bar.worktreeStack.length > 0
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
                    color: Modules.Theme.fg
                    font.family: Modules.Theme.fontFamily
                    font.pixelSize: Modules.Theme.fontSize
                    font.weight: Modules.Theme.fontWeight
                    anchors.verticalCenter: parent.verticalCenter
                }

                Row {
                    visible: Modules.PlanState.available
                    spacing: 8
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: Modules.PlanState.icon
                        color: Modules.Theme.fg
                        font.family: Modules.Theme.iconFontFamily
                        font.pixelSize: Modules.Theme.fontSize + 2
                        font.weight: Modules.Theme.fontWeight
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        visible: Modules.PlanState.total > 0
                        text: Modules.PlanState.done + "/" + Modules.PlanState.total
                        color: Modules.Theme.fg
                        font.family: Modules.Theme.fontFamily
                        font.pixelSize: Modules.Theme.fontSize
                        font.weight: Modules.Theme.fontWeight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        Item {
            id: pickerHost
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                topMargin: Modules.Theme.barHeight
            }
            z: 2

            Modules.ReviewCreatePicker { id: reviewCreatePicker; anchors.fill: parent }
            Modules.LovboxPicker { id: lovboxPicker; anchors.fill: parent }
            Modules.BluetoothPicker { id: bluetoothPicker; anchors.fill: parent }
            Modules.TimerPicker { id: timerPicker; anchors.fill: parent }
            Modules.NetworkPicker { id: networkPicker; anchors.fill: parent }
            Modules.AsusProfilePicker { id: asusProfilePicker; anchors.fill: parent }
            Modules.EmojiPicker { id: emojiPicker; anchors.fill: parent }
            Modules.ClaudeRenamePicker { id: claudeRenamePicker; anchors.fill: parent }
            Modules.ColorFormatPicker { id: colorFormatPicker; anchors.fill: parent }
            Modules.ClipboardPicker { id: clipboardPicker; anchors.fill: parent }
            Modules.NotesPicker { id: notesPicker; anchors.fill: parent }
            Modules.TodoListPicker { id: todoListPicker; anchors.fill: parent }
            Modules.NotificationJumpPicker { id: notificationJumpPicker; anchors.fill: parent }
            Modules.AgentAskPicker { id: agentAskPicker; anchors.fill: parent }
            Modules.CockpitPicker { id: cockpitPicker; anchors.fill: parent }
        }
    }
}
