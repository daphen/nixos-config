import QtQuick

QtObject {
    id: root
    property var view: null
    property bool chatVisible: true
    property bool sticking: true
    property bool pendingCursor: false
    readonly property int bottomSlack: 48
    readonly property string mode: sticking ? "follow" : "free"
    readonly property bool following: sticking
    signal wantCursorAtEnd(bool force)

    function bottomY() {
        if (!view) return 0
        return view.originY + Math.max(0, view.contentHeight - view.height)
    }

    function atBottom() {
        return !view || view.contentY >= bottomY() - bottomSlack
    }

    function pin() {
        if (!view || !chatVisible || view.count <= 0) return
        var last = view.itemAtIndex(view.count - 1)
        if (last && last.y + last.height > view.contentHeight + 0.5) {
            view.positionViewAtIndex(view.count - 1, ListView.Beginning)
            view.positionViewAtEnd()
        } else {
            view.contentY = bottomY()
            view.returnToBounds()
        }
    }

    readonly property Connections followConnections: Connections {
        target: root.view
        enabled: root.chatVisible && root.sticking
        function onContentHeightChanged() { root.pin() }
        function onHeightChanged() { root.pin() }
    }

    function userScrolled(up) {
        sticking = !up && atBottom()
    }

    function gestureStarted() {
        sticking = false
    }

    function gestureEnded() {
        sticking = atBottom()
    }

    function contentChanged() {
        if (chatVisible && sticking) wantCursorAtEnd(false)
    }

    function synced() {
        if (!chatVisible) return
        if (pendingCursor && view && view.count > 0) {
            pendingCursor = false
            wantCursorAtEnd(true)
        }
        if (sticking) pin()
    }

    function toEnd() {
        sticking = true
        pendingCursor = true
        pin()
    }

    function cursorMoved(index, isLast) {
        if (!chatVisible || !view) return
        if (isLast) {
            sticking = true
            pin()
        } else {
            sticking = false
            view.positionViewAtIndex(index, ListView.Contain)
        }
    }
}
