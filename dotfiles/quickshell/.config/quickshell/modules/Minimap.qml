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

    function nativeColumn(window) {
        const position = window && window.layout && window.layout.pos_in_scrolling_layout
        if (!position || position.length < 1) return null

        const column = Number(position[0])
        if (!Number.isFinite(column) || column < 1 || column !== Math.floor(column)) return null
        return Math.min(4096, column)
    }

    readonly property var occupancy: {
        const _ = NiriState.version
        const groups = NiriState.visibleWorkspaces(root.output)
        if (groups.length === 0) return ({ cells: ({}), activeCell: null })

        let firstGroup = 0
        if (groups.length > root.rows) {
            let activeGroup = groups.findIndex(group => group.ws.is_active === true)
            if (activeGroup < 0) activeGroup = 0
            firstGroup = Math.max(0, Math.min(groups.length - root.rows,
                activeGroup - Math.floor(root.rows / 2)))
        }
        const visibleGroups = groups.slice(firstGroup, firstGroup + root.rows)
        const rowOffset = groups.length < root.rows
            ? Math.floor((root.rows - groups.length) / 2)
            : 0

        const positions = []
        let minColumn = Infinity
        let maxColumn = -Infinity
        for (let groupIndex = 0; groupIndex < visibleGroups.length; groupIndex++) {
            const group = visibleGroups[groupIndex]
            for (const window of group.windows) {
                if (positions.length >= 256) break
                const column = root.nativeColumn(window)
                if (column === null) continue
                positions.push({
                    column: column,
                    row: groupIndex + rowOffset,
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
