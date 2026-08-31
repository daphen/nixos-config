import QtQuick
import "."

Item {
    id: root

    property string output: ""
    readonly property int columns: 13
    readonly property int dotSize: 2
    readonly property int gap: 6
    readonly property int pitch: dotSize + gap
    readonly property var workspaceGroups: {
        const _ = NiriState.version
        return NiriState.visibleWorkspaces(root.output)
    }
    readonly property int rows: Math.max(3, workspaceGroups.length)

    implicitWidth: Math.max(grid.implicitWidth, 100)
    implicitHeight: parent ? parent.height : Theme.barHeight

    function nativeColumn(window) {
        const position = window && window.layout && window.layout.pos_in_scrolling_layout
        if (!position || position.length < 1) return null

        const column = Number(position[0])
        if (!Number.isFinite(column) || column < 1 || column !== Math.floor(column)) return null
        return Math.min(4096, column)
    }

    readonly property var occupancy: {
        const groups = root.workspaceGroups
        if (groups.length === 0) return ({ cells: ({}), activeCell: null })

        const positions = []
        let minColumn = Infinity
        let maxColumn = -Infinity
        for (let groupIndex = 0; groupIndex < groups.length; groupIndex++) {
            const group = groups[groupIndex]
            for (const window of group.windows) {
                if (positions.length >= 256) break
                const column = root.nativeColumn(window)
                if (column === null) continue
                positions.push({
                    column: column,
                    row: groups.length === 1
                        ? Math.floor(root.rows / 2)
                        : Math.round(groupIndex * (root.rows - 1) / (groups.length - 1)),
                    focused: window.is_focused === true,
                })
                minColumn = Math.min(minColumn, column)
                maxColumn = Math.max(maxColumn, column)
            }
        }
        if (positions.length === 0) return ({ cells: ({}), activeCell: null })

        const columnSpan = maxColumn - minColumn + 1
        const columnOffset = Math.floor((root.columns - columnSpan) / 2)
        const cells = {}
        let activeCell = null
        for (const position of positions) {
            const column = Math.max(0, Math.min(root.columns - 1,
                position.column - minColumn + columnOffset))
            cells[position.row * root.columns + column] = true
            if (position.focused) activeCell = { column: column, row: position.row }
        }
        return ({ cells: cells, activeCell: activeCell })
    }

    readonly property var activeCell: occupancy.activeCell

    GridView {
        id: grid
        anchors.centerIn: parent
        width: root.columns * root.pitch
        height: root.rows > 0 ? root.rows * root.pitch : 0
        cellWidth: root.pitch
        cellHeight: root.pitch
        interactive: false
        model: root.columns * root.rows

        Behavior on height {
            NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
        }
        add: Transition {
            NumberAnimation { property: "opacity"; from: 0; duration: 190; easing.type: Easing.OutCubic }
            NumberAnimation { property: "scale"; from: 0.65; duration: 190; easing.type: Easing.OutCubic }
        }
        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: 170; easing.type: Easing.InCubic }
            NumberAnimation { property: "scale"; to: 0.65; duration: 170; easing.type: Easing.InCubic }
        }

        delegate: Item {
            required property int index
            readonly property int column: index % root.columns
            readonly property int row: Math.floor(index / root.columns)
            readonly property bool occupied: root.occupancy.cells[index] === true
            readonly property real normalizedX: root.columns > 1
                ? (column - (root.columns - 1) / 2) / ((root.columns - 1) / 2)
                : 0
            readonly property real normalizedY: root.rows > 1
                ? (row - (root.rows - 1) / 2) / ((root.rows - 1) / 2)
                : 0
            readonly property real radialDistance: Math.min(1,
                Math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY))

            width: grid.cellWidth
            height: grid.cellHeight

            Rectangle {
                anchors.centerIn: parent
                width: root.dotSize
                height: root.dotSize
                radius: root.dotSize / 2
                color: Theme.fg
                opacity: parent.occupied
                    ? 0.62
                    : 0.18 * Math.pow(1 - parent.radialDistance, 0.8)
            }
        }
    }

    Item {
        id: marker
        visible: root.activeCell !== null
        width: 10
        height: 10
        x: grid.x + (root.activeCell ? root.activeCell.column : Math.floor(root.columns / 2)) * root.pitch
            + (root.pitch - width) / 2
        y: grid.y + (root.activeCell ? root.activeCell.row : Math.floor(root.rows / 2)) * root.pitch
            + (root.pitch - height) / 2

        Behavior on x {
            NumberAnimation {
                duration: 110
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.34, 1.56, 0.64, 1.0, 1.0, 1.0]
            }
        }
        Behavior on y {
            NumberAnimation {
                duration: 110
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.34, 1.56, 0.64, 1.0, 1.0, 1.0]
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.surface2
        }

        Rectangle {
            anchors.centerIn: parent
            width: 4
            height: 4
            radius: 2
            color: Theme.cursor
            Behavior on color { ColorAnimation { duration: 110 } }
        }
    }
}
