import QtQuick

// Family scroll feel for any Flickable — declare inside the list:
//
//   Lib.ScrollFeel { flick: list; onScrolled: up => { ... } }
//
// Mouse wheels get a 5x notch gain (Qt's default is treacle); touchpads
// scroll from angleDelta at a measured gain — their pixelDeltas arrive
// junk-scaled (1–5px/event) on this hardware, so they are ignored.
// Both axes use the same gain; each axis moves only if the flick can scroll that way.
WheelHandler {
    id: root
    required property Flickable flick
    property real mouseGain: 5.0
    property real touchpadGain: 1.2
    // A sideways strip with nothing to scroll vertically: let the plain up/down wheel drive it.
    property bool verticalWheelScrollsSideways: false
    // fires after each wheel-driven move; up === scrolled toward older content
    signal scrolled(bool up)

    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    // A handler that sees an event keeps it even unaccepted, so each axis is off unless it can move.
    enabled: canY || (verticalWheelScrollsSideways && canX)
    readonly property bool canX: flick.flickableDirection !== Flickable.VerticalFlick && flick.orientation !== ListView.Vertical
        && flick.contentWidth + flick.leftMargin + flick.rightMargin > flick.width + 0.5
    readonly property bool canY: flick.flickableDirection !== Flickable.HorizontalFlick && flick.orientation !== ListView.Horizontal
        && flick.contentHeight + flick.topMargin + flick.bottomMargin > flick.height + 0.5
    function step(touchpad, angle, pixel) {
        return touchpad ? angle * touchpadGain : ((pixel !== 0) ? pixel : angle / 8) * mouseGain
    }
    // A WheelHandler only receives events along its orientation; this twin takes pure sideways swipes.
    readonly property WheelHandler sideways: WheelHandler {
        parent: root.parent
        enabled: root.canX
        target: null
        acceptedDevices: root.acceptedDevices
        orientation: Qt.Horizontal
        onWheel: e => {
            if (e.angleDelta.y !== 0 || e.pixelDelta.y !== 0) { e.accepted = false; return }
            root.apply(e, point.device.type === PointerDevice.TouchPad)
        }
    }
    onWheel: e => apply(e, point.device.type === PointerDevice.TouchPad)
    function apply(e, touchpad) {
        let px = step(touchpad, e.angleDelta.x, e.pixelDelta.x)
        let py = step(touchpad, e.angleDelta.y, e.pixelDelta.y)
        if (verticalWheelScrollsSideways && px === 0) { px = py; py = 0 }
        if (!canX) px = 0
        if (!canY) py = 0
        if (px === 0 && py === 0) { e.accepted = false; return }
        // Clamp instead of returnToBounds(): overshooting then rebounding jitters at the ends.
        if (px !== 0) {
            const lo = flick.originX - flick.leftMargin
            flick.contentX = Math.max(lo, Math.min(lo + flick.contentWidth + flick.leftMargin + flick.rightMargin - flick.width, flick.contentX - px))
        }
        if (py !== 0) {
            const lo = flick.originY - flick.topMargin
            flick.contentY = Math.max(lo, Math.min(lo + flick.contentHeight + flick.topMargin + flick.bottomMargin - flick.height, flick.contentY - py))
        }
        root.scrolled((py || px) > 0)
        e.accepted = true
    }
}
