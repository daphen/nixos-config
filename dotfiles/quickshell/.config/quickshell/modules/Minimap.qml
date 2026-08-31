import QtQuick
import "."

Item {
    id: root

    property string output: ""
    readonly property int columns: 13
    readonly property int rows: 3
    readonly property int dotSize: 3
    readonly property int gap: 6
    readonly property int pitch: dotSize + gap

    implicitWidth: Math.max(grid.implicitWidth, 100)
    implicitHeight: parent ? parent.height : Theme.barHeight

    function nativePosition(window) {
        const position = window && window.layout && window.layout.pos_in_scrolling_layout
        if (!position || position.length < 2) return null

        const column = Number(position[0])
        const row = Number(position[1])
        if (!Number.isFinite(column) || !Number.isFinite(row)
                || column < 1 || row < 1
                || column !== Math.floor(column) || row !== Math.floor(row)) return null

        const limit = 4096
        return {
            column: Math.min(limit, column),
            row: Math.min(limit, row),
        }
    }

    readonly property var occupancy: {
        const _ = NiriState.version
        let workspace = null
        for (const id in NiriState.workspaces) {
            const candidate = NiriState.workspaces[id]
            if (candidate.output === root.output && candidate.is_active === true) {
                workspace = candidate
                break
            }
        }
        if (!workspace) return ({ cells: ({}), activeCell: null })

        const positions = []
        let minColumn = Infinity
        let maxColumn = -Infinity
        let minRow = Infinity
        let maxRow = -Infinity
        for (const id in NiriState.windows) {
            if (positions.length >= 256) break
            const window = NiriState.windows[id]
            if (window.workspace_id !== workspace.id) continue
            const position = root.nativePosition(window)
            if (!position) continue
            positions.push({
                column: position.column,
                row: position.row,
                focused: window.is_focused === true,
            })
            minColumn = Math.min(minColumn, position.column)
            maxColumn = Math.max(maxColumn, position.column)
            minRow = Math.min(minRow, position.row)
            maxRow = Math.max(maxRow, position.row)
        }
        if (positions.length === 0) return ({ cells: ({}), activeCell: null })

        const columnSpan = maxColumn - minColumn + 1
        const rowSpan = maxRow - minRow + 1
        const columnOffset = Math.floor((root.columns - columnSpan) / 2)
        const rowOffset = Math.floor((root.rows - rowSpan) / 2)
        const cells = {}
        let activeCell = null
        for (const position of positions) {
            const column = Math.max(0, Math.min(root.columns - 1,
                position.column - minColumn + columnOffset))
            const row = Math.max(0, Math.min(root.rows - 1,
                position.row - minRow + rowOffset))
            cells[row * root.columns + column] = true
            if (position.focused) activeCell = { column: column, row: row }
        }
        return ({ cells: cells, activeCell: activeCell })
    }

    readonly property var activeCell: occupancy.activeCell

    Grid {
        id: grid
        anchors.centerIn: parent
        columns: root.columns
        columnSpacing: root.gap
        rowSpacing: root.gap

        Repeater {
            model: root.columns * root.rows

            Rectangle {
                required property int index
                readonly property bool occupied: root.occupancy.cells[index] === true
                width: root.dotSize
                height: root.dotSize
                radius: root.dotSize / 2
                color: Theme.fg
                opacity: occupied ? 0.62 : 0.16
            }
        }
    }

    Item {
        id: marker
        visible: root.activeCell !== null
        width: 10
        height: 10
        x: grid.x + (root.activeCell ? root.activeCell.column : Math.floor(root.columns / 2)) * root.pitch
            + (root.dotSize - width) / 2
        y: grid.y + (root.activeCell ? root.activeCell.row : Math.floor(root.rows / 2)) * root.pitch
            + (root.dotSize - height) / 2

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
