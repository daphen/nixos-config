import QtQuick

// The companion app's boot splash as a card: mark, app name, label, sliding progress.
//   LaunchCard { title: "Slack"; running: shown }
Rectangle {
    id: card
    property string title: ""
    property string label: "launching"
    property bool running: true

    implicitWidth: 220
    implicitHeight: 212
    radius: Theme.radiusCard
    color: Theme.bg
    border.color: Theme.hairline

    Column {
        anchors.centerIn: parent
        spacing: 18

        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            height: 72; width: height * 248 / 308
            source: Qt.resolvedUrl("images/cockpit-mark-" + Theme.mode + ".png")
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 4
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: card.title.toUpperCase()
                color: Theme.fg
                font { family: Theme.fontFamily; pixelSize: 16; weight: Font.DemiBold; letterSpacing: 16 * 0.08 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: card.label.toUpperCase()
                color: Theme.fg_muted
                font { family: Theme.fontFamily; pixelSize: 10; letterSpacing: 10 * 0.08 }
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 96; height: 2; radius: 1
            color: Theme.hairlineSoft
            clip: true
            Rectangle {
                width: 38; height: parent.height; radius: 1
                color: Theme.orange
                SequentialAnimation on x {
                    running: card.running && card.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: -38; to: 96; duration: 900; easing.type: Easing.InOutQuad }
                    NumberAnimation { from: 96; to: -38; duration: 900; easing.type: Easing.InOutQuad }
                }
            }
        }
    }
}
