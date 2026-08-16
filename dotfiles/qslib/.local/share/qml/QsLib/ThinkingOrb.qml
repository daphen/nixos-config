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
  // Hue/sat animate as NUMBERS, not via ColorAnimation on glow: RGB-lerped
  // colors desaturate mid-path and their hslHue swings wildly there, which made
  // tool-change transitions visibly hop instead of glide.
  readonly property real _thu: glow.hslHue < 0 ? 0 : glow.hslHue
  // An achromatic glow (Theme.bg on cursor rows) must stay achromatic: hue -1
  // maps to 0 = red, and the saturation floor was painting those orbs pink.
  readonly property real _tsat: glow.hslSaturation < 0.05 ? 0 : Math.min(1, Math.max(0.75, glow.hslSaturation))
  property real hu: _thu
  property real sat: _tsat
  Behavior on hu  { NumberAnimation { duration: 650; easing.type: Easing.InOutQuad } }
  Behavior on sat { NumberAnimation { duration: 650; easing.type: Easing.InOutQuad } }

  // Drift phases are WALL-CLOCK (never animation state, so nothing resets on
  // running flaps or delegate recreation) and BOUNDED (radians, so the shader
  // never sees coordinates big enough to break float32 noise). flow scales the
  // clock, keeping continuity. Prime-ish periods so the composite never loops.
  property real ph1: 0
  property real ph2: 0
  property real ph3: 0
  property real ph4: 0
  function _ph(P) { return ((Date.now() * flow) % P) / P * 2 * Math.PI }
  FrameAnimation {
    running: orb.running
    onTriggered: { orb.ph1 = orb._ph(47000); orb.ph2 = orb._ph(61000); orb.ph3 = orb._ph(83000); orb.ph4 = orb._ph(29000) }
  }
  // Big badge flows livelier; the small roster orbs stay calm. A constant
  // multiplier on the wall clock keeps continuity (no resets, ever).
  // 0.64 was tuned against a 140px preview; at the real 44px badge apparent
  // motion scales down with size and it read as near-still. 1.3 restores life.
  property real flow: width >= 40 ? 3.5 : 1.8

  // Field shape knobs (shader uniforms). Defaults are the shipped look; the
  // orb-tuner dev shell binds sliders to them.
  property real angle: -0.76
  property real bandX: 1.84
  property real bandY: 5.03
  property real warp: 6.37
  property real grain: 0.45
  property real feather: 0.74
  property real bright: 0.25

  ShaderEffect {
    id: field
    anchors.fill: parent
    anchors.margins: ring.border.width / 2
    fragmentShader: Qt.resolvedUrl("aurora.frag.qsb")
    property real ph1: orb.ph1
    property real ph2: orb.ph2
    property real ph3: orb.ph3
    property real ph4: orb.ph4
    property real angle: orb.angle
    property real bandX: orb.bandX
    property real bandY: orb.bandY
    property real warp: orb.warp
    property real gain: orb.grain
    property real feather: orb.feather
    property real bright: orb.bright
    // Bright-dominated palette: the field lives between mid and crest; the deep
    // tone only survives in the folds (the old near-black ground read as a pit).
    // Lifted on light mode: identical pixels read much darker against a pale
    // ground (simultaneous contrast), so the field compensates instead of the
    // viewer squinting.
    property color colA: Qt.hsla(orb.hu, orb.sat, Theme.mode === "light" ? 0.68 : 0.26, 1)
    property color colB: Qt.hsla(orb.hu, orb.sat, Theme.mode === "light" ? 0.82 : 0.56, 1)
    property color colC: Qt.hsla((orb.hu + 0.05) % 1, orb.sat * 0.7, Theme.mode === "light" ? 0.95 : 0.88, 1)
  }

  // The ring rides the action hue — bright tint on dark, deep shade on light —
  // so the frame belongs to the aurora instead of cutting against it.
  Rectangle {
    id: ring
    anchors.fill: parent
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1.25, Math.min(width, height) * 0.065)
    border.color: Qt.hsla(orb.hu, orb.sat * 0.5, Theme.mode === "light" ? 0.34 : 0.82, 1)
    antialiasing: true
  }
}
