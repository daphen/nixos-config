import QtQuick
import QtQuick.Effects

Item {
    id: root

    property alias first: firstEffect.data
    property alias second: secondEffect.data
    property bool showSecond: false
    property int enterDuration: 150
    property int exitDuration: 150
    property real shift: 4
    property real blurAmount: 0.125
    property real inactiveScale: 1

    Item {
        id: firstSlot
        anchors.fill: parent
        z: root.showSecond ? 0 : 1
        opacity: root.showSecond ? 0 : 1
        scale: root.showSecond ? root.inactiveScale : 1
        property real motionBlur: root.showSecond ? root.blurAmount : 0
        property real motionY: root.showSecond ? -root.shift : 0
        transform: Translate { y: firstSlot.motionY }
        Item {
            id: firstEffect
            anchors.fill: parent
            layer.enabled: firstBlur.running
            layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: firstSlot.motionBlur }
        }
        Behavior on opacity { NumberAnimation { id: firstOpacity; duration: root.showSecond ? root.exitDuration : root.enterDuration; easing.type: Easing.InOutQuad } }
        Behavior on scale { NumberAnimation { id: firstScale; duration: root.showSecond ? root.exitDuration : root.enterDuration; easing.type: Easing.InOutQuad } }
        Behavior on motionBlur { NumberAnimation { id: firstBlur; duration: root.showSecond ? root.exitDuration : root.enterDuration; easing.type: Easing.InOutQuad } }
        Behavior on motionY { NumberAnimation { id: firstShift; duration: root.showSecond ? root.exitDuration : root.enterDuration; easing.type: Easing.OutCubic } }
    }

    Item {
        id: secondSlot
        anchors.fill: parent
        z: root.showSecond ? 1 : 0
        opacity: root.showSecond ? 1 : 0
        scale: root.showSecond ? 1 : root.inactiveScale
        property real motionBlur: root.showSecond ? 0 : root.blurAmount
        property real motionY: root.showSecond ? 0 : root.shift
        transform: Translate { y: secondSlot.motionY }
        Item {
            id: secondEffect
            anchors.fill: parent
            layer.enabled: secondBlur.running
            layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: secondSlot.motionBlur }
        }
        Behavior on opacity { NumberAnimation { id: secondOpacity; duration: root.showSecond ? root.enterDuration : root.exitDuration; easing.type: Easing.InOutQuad } }
        Behavior on scale { NumberAnimation { id: secondScale; duration: root.showSecond ? root.enterDuration : root.exitDuration; easing.type: Easing.InOutQuad } }
        Behavior on motionBlur { NumberAnimation { id: secondBlur; duration: root.showSecond ? root.enterDuration : root.exitDuration; easing.type: Easing.InOutQuad } }
        Behavior on motionY { NumberAnimation { id: secondShift; duration: root.showSecond ? root.enterDuration : root.exitDuration; easing.type: Easing.OutCubic } }
    }
}
