pragma Singleton

import QtQuick

Item {
  readonly property real now: ticker.now

  QtObject {
    id: ticker
    property real now: Date.now()
  }

  Timer {
    interval: 50
    repeat: true
    running: true
    onTriggered: ticker.now = Date.now()
  }
}
