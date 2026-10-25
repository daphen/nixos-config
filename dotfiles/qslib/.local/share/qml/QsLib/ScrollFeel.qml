import QtQuick

// Family scroll feel for any Flickable — declare inside the list:
//
//   Lib.ScrollFeel { flick: list; onScrolled: up => { ... } }
//
// Mouse wheels get a 5x notch gain (Qt's default is treacle); touchpads
// scroll from angleDelta at a measured gain — their pixelDeltas arrive
// junk-scaled (1–5px/event) on this hardware, so they are ignored.
WheelHandler {
    id: root
    required property Flickable flick
    property real mouseGain: 5.0
    property real touchpadGain: 1.2
    // fires after each wheel-driven move; up === scrolled toward older content
    signal scrolled(bool up)

    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    // A horizontal-only list takes sideways swipes; the handler ignores the other axis.
    readonly property bool horizontal: flick.flickableDirection === Flickable.HorizontalFlick
    orientation: horizontal ? Qt.Horizontal : Qt.Vertical
    onWheel: e => {
        const touchpad = point.device.type === PointerDevice.TouchPad
        const angle = horizontal ? e.angleDelta.x : e.angleDelta.y
        const pixel = horizontal ? e.pixelDelta.x : e.pixelDelta.y
        const px = touchpad ? angle * touchpadGain : ((pixel !== 0) ? pixel : angle / 8) * mouseGain
        if (horizontal) flick.contentX -= px
        else flick.contentY -= px
        flick.returnToBounds()
        root.scrolled(px > 0)
        e.accepted = true
    }
}
