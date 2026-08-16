import QtQuick
import "."

// "Thinking" orb — a silk-aurora badge: a domain-warped fbm field (aurora.frag,
// compiled to aurora.frag.qsb) flows inside a hue-ringed disc. One continuous
// fabric of light that folds into itself — not shapes, not lines. The hue tracks
// what the agent is DOING (read/edit/run/…) via `glow`.
Item {
  id: orb
  property bool running: true
  property color glow: Theme.fg
  // Inert since the wireframe era; kept so old call sites that set it still load.
  property int nodes: 0
  implicitWidth: 26
  implicitHeight: 26
  // Enter/exit is animated, not a hard pop; callers bind `running` only.
  opacity: running ? 1 : 0
  scale: running ? 1 : 0.5
  visible: opacity > 0.01
  Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  Behavior on scale   { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
  // Ease between hues so tool changes glide instead of flashing.
  Behavior on glow { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }

  readonly property real hu: glow.hslHue < 0 ? 0 : glow.hslHue
  readonly property real sat: Math.min(1, Math.max(0.75, glow.hslSaturation))

  // Time is WALL-CLOCK seconds (daily modulus keeps float32 precision), never
  // animation state: stored-from-zero clocks visibly reset whenever `running`
  // flapped or the delegate was recreated. Every orb on screen flows in unison.
  property real t: 0
  FrameAnimation {
    running: orb.running
    onTriggered: orb.t = (Date.now() % 86400000) / 1000
  }

  ShaderEffect {
    id: field
    anchors.fill: parent
    anchors.margins: ring.border.width / 2
    fragmentShader: Qt.resolvedUrl("aurora.frag.qsb")
    property real time: orb.t
    // Bright-dominated palette: the field lives between mid and crest; the deep
    // tone only survives in the folds (the old near-black ground read as a pit).
    property color colA: Qt.hsla(orb.hu, orb.sat, 0.26, 1)
    property color colB: Qt.hsla(orb.hu, orb.sat, 0.56, 1)
    property color colC: Qt.hsla((orb.hu + 0.05) % 1, orb.sat * 0.7, 0.88, 1)
  }

  // The ring rides the action hue — bright tint on dark, deep shade on light —
  // so the frame belongs to the aurora instead of cutting against it.
  Rectangle {
    id: ring
    anchors.fill: parent
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1.25, Math.min(width, height) * 0.065)
    border.color: Qt.hsla(orb.hu, orb.sat * 0.85, Theme.mode === "light" ? 0.34 : 0.82, 1)
    antialiasing: true
  }
}
