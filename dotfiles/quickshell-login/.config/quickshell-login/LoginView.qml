import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell

Item {
    id: root

    property bool deckMode: false
    property bool fakeAuthentication: true
    property bool showLoginControls: true
    property string authState: "idle"
    property real settleProgress: 0
    property string wallpaperPath: Quickshell.env("LOGIN_WALLPAPER") || Quickshell.env("HOME") + "/.config/themes/wallpaper-dark"

    signal passwordSubmitted(string password)
    signal unlockPreviewFinished()

    function playLock() {
        unlockAnimation.stop()
        settleProgress = 0
        authState = "idle"
        passwordInput.text = ""
        lockAnimation.restart()
    }

    function playUnlock() {
        lockAnimation.stop()
        settleProgress = 1
        unlockAnimation.restart()
    }

    function showError() {
        authState = "error"
        passwordInput.selectAll()
        passwordInput.forceActiveFocus()
    }

    function authenticate() {
        if (!passwordInput.text.length || authState === "authenticating") return
        authState = "authenticating"
        if (fakeAuthentication) fakeAuth.restart()
        else passwordSubmitted(passwordInput.text)
    }

    function clearPassword() {
        passwordInput.text = ""
    }

    focus: true
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space) {
            playLock()
            event.accepted = true
        } else if (event.key === Qt.Key_U) {
            playUnlock()
            event.accepted = true
        } else if (event.key === Qt.Key_E) {
            showError()
            event.accepted = true
        } else if (event.key === Qt.Key_D) {
            deckMode = !deckMode
            event.accepted = true
        }
    }

    Item {
        id: world
        anchors.fill: parent

        Image {
            id: wallpaper
            anchors.fill: parent
            source: "file://" + root.wallpaperPath
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            mipmap: true
        }

        MultiEffect {
            anchors.fill: parent
            source: wallpaper
            blurEnabled: true
            blur: 1
            blurMax: 18
            opacity: 0.7 * root.settleProgress
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0.015, 0.02, 0.035, 0.35 * root.settleProgress)
        }
    }

    ShaderEffectSource {
        id: worldTexture
        sourceItem: world
        hideSource: true
        live: true
        smooth: true
    }

    ShaderEffect {
        anchors.fill: parent
        property variant source: worldTexture
        property real progress: root.settleProgress
        property real edgeBlur: 0
        property real edgeBlurStart: 0.45
        property real vignette: 0
        property real chromatic: 0
        property vector2d fullSize: Qt.vector2d(width, height)
        fragmentShader: Qt.resolvedUrl("canvas-lens.frag.qsb")
    }

    Column {
        visible: root.showLoginControls
        anchors {
            left: parent.left
            top: parent.top
            leftMargin: root.deckMode ? 42 : 68
            topMargin: root.deckMode ? 46 : 66
        }
        spacing: 2
        opacity: Math.max(0, Math.min(1, (root.settleProgress - 0.24) / 0.76))
        transform: Translate { y: 12 * (1 - root.settleProgress) }

        SystemClock { id: clock; precision: SystemClock.Seconds }

        Text {
            text: Qt.formatTime(clock.date, "HH:mm")
            color: "#FAFAFA"
            font.family: "Inter"
            font.pixelSize: root.deckMode ? 42 : 56
            font.weight: 520
        }
        Text {
            text: Qt.formatDate(clock.date, "dddd, MMMM d")
            color: Qt.rgba(1, 1, 1, 0.68)
            font.family: "Inter"
            font.pixelSize: root.deckMode ? 14 : 16
            font.weight: 500
        }
    }

    Row {
        visible: root.showLoginControls
        anchors {
            right: parent.right
            top: parent.top
            rightMargin: root.deckMode ? 38 : 62
            topMargin: root.deckMode ? 42 : 62
        }
        spacing: 10
        opacity: Math.max(0, Math.min(1, (root.settleProgress - 0.24) / 0.76))

        Repeater {
            model: ["⌁", "⏻"]
            Rectangle {
                required property string modelData
                width: root.deckMode ? 46 : 42
                height: width
                radius: width / 2
                color: Qt.rgba(0.04, 0.05, 0.06, 0.66)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.16)
                Text {
                    anchors.centerIn: parent
                    text: parent.modelData
                    color: "#F5F5F5"
                    font.family: "Inter"
                    font.pixelSize: 18
                }
            }
        }
    }

    Rectangle {
        id: loginPanel
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: root.deckMode ? 54 : 72
        }
        visible: root.showLoginControls
        width: Math.min(parent.width - 64, root.deckMode ? 520 : 460)
        height: root.deckMode ? 112 : 106
        radius: 28
        color: Qt.rgba(0.035, 0.04, 0.045, 0.84)
        border.width: 1
        border.color: root.authState === "error"
            ? Qt.rgba(1, 0.38, 0.34, 0.82)
            : Qt.rgba(1, 1, 1, 0.18)
        opacity: Math.max(0, Math.min(1, (root.settleProgress - 0.32) / 0.68))
        transform: Translate { y: 18 * (1 - root.settleProgress) }

        Behavior on border.color { ColorAnimation { duration: 180 } }

        RowLayout {
            anchors { fill: parent; margins: 14 }
            spacing: 14

            Rectangle {
                Layout.preferredWidth: root.deckMode ? 72 : 66
                Layout.preferredHeight: Layout.preferredWidth
                radius: 22
                color: "#8069C9"
                Text {
                    anchors.centerIn: parent
                    text: "D"
                    color: "#FFFFFF"
                    font.family: "Inter"
                    font.pixelSize: 25
                    font.weight: 650
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: "David"
                    color: "#FFFFFF"
                    font.family: "Inter"
                    font.pixelSize: 15
                    font.weight: 600
                }

                TextInput {
                    id: passwordInput
                    Layout.fillWidth: true
                    color: "#FFFFFF"
                    selectionColor: "#8069C9"
                    selectedTextColor: "#FFFFFF"
                    font.family: "Inter"
                    font.pixelSize: root.deckMode ? 17 : 16
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    enabled: root.authState !== "authenticating"
                    onTextEdited: {
                        if (root.authState === "error") root.authState = "idle"
                    }
                    onAccepted: root.authenticate()

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !passwordInput.text.length
                        text: root.authState === "error" ? "That password didn’t work" : "Password"
                        color: root.authState === "error"
                            ? "#FF9A94" : Qt.rgba(1, 1, 1, 0.48)
                        font: passwordInput.font
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: root.authState === "error" ? "#E86B64" : Qt.rgba(1, 1, 1, 0.2)
                }
            }

            Rectangle {
                Layout.preferredWidth: root.deckMode ? 58 : 52
                Layout.preferredHeight: Layout.preferredWidth
                radius: 18
                color: root.authState === "authenticating" ? "#6E628E" : "#8069C9"

                Text {
                    anchors.centerIn: parent
                    text: root.authState === "authenticating" ? "···" : "→"
                    color: "#FFFFFF"
                    font.family: "Inter"
                    font.pixelSize: 22
                    font.weight: 600
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.authenticate()
                }
            }
        }
    }

    Text {
        visible: root.showLoginControls
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: root.deckMode ? 30 : 42
        }
        opacity: loginPanel.opacity
        text: root.deckMode ? "Touch the password field to open the keyboard" : "Enter to sign in"
        color: Qt.rgba(1, 1, 1, 0.44)
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: 500
    }

    NumberAnimation {
        id: lockAnimation
        target: root
        property: "settleProgress"
        from: 0
        to: 1
        duration: 800
        easing.type: Easing.BezierSpline
        easing.bezierCurve: [0.22, 1.0, 0.36, 1.0, 1.0, 1.0]
        onFinished: {
            if (root.showLoginControls) passwordInput.forceActiveFocus()
        }
    }

    NumberAnimation {
        id: unlockAnimation
        target: root
        property: "settleProgress"
        from: 1
        to: 0
        duration: 650
        easing.type: Easing.BezierSpline
        easing.bezierCurve: [0.22, 1.0, 0.36, 1.0, 1.0, 1.0]
        onFinished: root.unlockPreviewFinished()
    }

    Timer {
        id: fakeAuth
        interval: 900
        onTriggered: root.showError()
    }

    Component.onCompleted: playLock()
}
