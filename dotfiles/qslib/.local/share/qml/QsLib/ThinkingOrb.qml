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
  // Flip the ring's light/dark pick — for orbs sitting on an inverted ground
  // (the roster's cursor pill), where the normal ring melts into the fill.
  property bool invertRing: false
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
  // Hue/sat are INSTANT; the derived colors animate in RGB below. Animating hue
  // as a scalar walked the hue wheel — orange→azure visibly passed through
  // green — where an RGB lerp goes straight to the target through a muted mid.
  // An achromatic glow (Theme.bg on cursor rows) must stay achromatic: hue -1
  // maps to 0 = red, and the saturation floor would paint those orbs pink.
  readonly property real hu: glow.hslHue < 0 ? 0 : glow.hslHue
  readonly property real sat: glow.hslSaturation < 0.05 ? 0 : Math.min(1, Math.max(0.75, glow.hslSaturation))

  // Drift phases are WALL-CLOCK (never animation state, so nothing resets on
  // running flaps or delegate recreation) and BOUNDED (radians, so the shader
  // never sees coordinates big enough to break float32 noise). flow scales the
  // clock, keeping continuity. Prime-ish periods so the composite never loops.
  property real ph1: 0
  property real ph2: 0
  property real ph3: 0
  property real ph4: 0
  // Per-instance random seed: every orb starts at its own point in the cycle.
  // The wall clock still drives the motion (reset-proof), but identical phases
  // made all visible orbs move in lockstep, which read as one cheap loop.
  // Assigned in onCompleted, not a binding — JS globals aren't reliably there
  // during component creation (the old "Math is undefined" trap).
  property real seed: 0
  Component.onCompleted: seed = Math.random()
  function _ph(P) { return ((Date.now() * flow) % P) / P * 2 * Math.PI }
  FrameAnimation {
    running: orb.running
    onTriggered: {
      orb.ph1 = orb._ph(47000) + orb.seed * 6.2832
      orb.ph2 = orb._ph(61000) + orb.seed * 17.9
      orb.ph3 = orb._ph(83000) + orb.seed * 29.3
      orb.ph4 = orb._ph(29000) + orb.seed * 41.7
    }
  }
  // Big badge flows livelier; the small roster orbs stay calm. A constant
  // multiplier on the wall clock keeps continuity (no resets, ever).
  // 0.64 was tuned against a 140px preview; at the real 44px badge apparent
  // motion scales down with size and it read as near-still. 1.3 restores life.
  property real flow: width >= 40 ? 3.5 : 1.8

  // Field shape knobs (shader uniforms). Defaults are the shipped look; the
  // orb-tuner dev shell binds sliders to them.
  property real angle: -0.76
  property real bandX: 1.35   // feature scale (bigger = broader folds)
  property real bandY: 1.2    // island field frequency
  property real warp: 1.5     // fold strength
  property real grain: 0.54   // wobble frequency
  property real feather: 0.96
  property real bright: 0.55  // dark-vs-luminous balance
  property real swirl: 1.2
  property real plasma: 0.05 // crease/seam intensity (aura = no line)

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
    property real swirl: orb.swirl
    property real plasma: orb.plasma
    // Bright-dominated palette: the field lives between mid and crest; the deep
    // tone only survives in the folds (the old near-black ground read as a pit).
    // Lifted on light mode: identical pixels read much darker against a pale
    // ground (simultaneous contrast), so the field compensates instead of the
    // viewer squinting.
    // Duotone: depths lean one neighboring hue, crests the other (azure body ->
    // violet depths, cyan crests). A same-hue ramp with pale crests read as
    // "<color> + white" and lost the character.
    // AuraGlass palette: mostly-light pastel body with ONE deep shadow and a
    // desaturated cream-leaning highlight (fitted to the Ocean Teal stops
    // #254754/#2D9BAD/#DBE8CD). The low crest saturation is what makes the
    // bright regions read as diffuse glow instead of colored paint.
    readonly property bool _warm: orb.hu < 0.45
    readonly property real _lift: 0.10 * Math.max(0, Math.min(1, (orb.hu - 0.565) / 0.06))
    // Warm hues can't use a dark anchor: darkened orange reads as BROWN. Their
    // low stop is instead the saturated true hue at medium lightness, with the
    // body pushed brighter above it; cool hues keep the deep-shadow ramp.
    property color colA: _warm
      ? Qt.hsla((orb.hu + 0.02) % 1, orb.sat * 0.85, Theme.mode === "light" ? 0.52 : 0.47, 1)
      : Qt.hsla((orb.hu + 0.03) % 1, orb.sat * 0.60,
                (Theme.mode === "light" ? 0.30 : 0.24) + _lift * 0.6, 1)
    property color colB: _warm
      ? Qt.hsla(orb.hu, orb.sat * 0.65, Theme.mode === "light" ? 0.72 : 0.68, 1)
      : Qt.hsla(orb.hu, orb.sat * 0.55,
                (Theme.mode === "light" ? 0.58 : 0.52) + _lift, 1)
    property color colC: Qt.hsla((orb.hu + (_warm ? 0.045 : 0.96)) % 1, orb.sat * 0.35,
                                 (Theme.mode === "light" ? 0.84 : 0.80) + _lift * 0.5, 1)
    Behavior on colA { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
    Behavior on colB { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
    Behavior on colC { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
  }

  // The ring rides the action hue — bright tint on dark, deep shade on light —
  // so the frame belongs to the aurora instead of cutting against it.
  Rectangle {
    id: ring
    anchors.fill: parent
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1.25, Math.min(width, height) * 0.065) + (Theme.mode === "light" ? 1 : 0)
    border.color: Qt.hsla(orb.hu, orb.sat * 0.5, (Theme.mode === "light") !== orb.invertRing ? 0.34 : 0.82, 1)
    Behavior on border.color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
    antialiasing: true
  }
}
