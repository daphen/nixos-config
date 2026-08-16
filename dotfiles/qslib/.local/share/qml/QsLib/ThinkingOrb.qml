import QtQuick
import "."

// "Thinking" orb — a slowly revolving wireframe network sphere: an orthographic
// projection of points on a unit sphere, rotated around Y each frame (real 3D
// globe spin). The feed-update debounce keeps the main thread free enough that
// this Canvas animation stays smooth during streaming.
Item {
  id: orb
  property bool running: true
  property color glow: Theme.fg
  implicitWidth: 26
  implicitHeight: 26
  // Enter/exit is animated, not a hard pop; callers bind `running` only.
  opacity: running ? 1 : 0
  scale: running ? 1 : 0.5
  visible: opacity > 0.01
  Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  Behavior on scale   { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
  // The gradient/mesh hue tracks what the agent is DOING (read/edit/run/…);
  // ease between hues so tool changes glide instead of flashing.
  Behavior on glow { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }

  // Node count scales with size. At roster size the 26-node mesh collapsed into a dark
  // blob: R is ~5px there, the edge threshold spans almost the whole disc, so all ~325
  // pairs drew a line. But 0.55 overshot the other way — 8 nodes at 14px read as thin
  // and scattered. 0.93 puts the roster orb at 13, which holds together as a mesh
  // (chosen against a true-size side-by-side; a scaled preview magnifies the Canvas
  // raster and tells you nothing).
  property int nodes: width >= 22 ? 26 : Math.max(6, Math.round(width * 0.93))

  property var _pts: []
  property real rot: 0

  Component.onCompleted: _build()
  onNodesChanged: _build()
  function _build() {
    // Guard: onNodesChanged can fire while the component is still being created (setting
    // `nodes` explicitly at a use site triggers it), and the JS globals are not reliably
    // there yet — the harness caught "Math is undefined" from exactly that path.
    if (typeof Math === "undefined" || orb.nodes === undefined) return
    var n = Math.max(4, orb.nodes), pts = [], off = 2 / n, inc = Math.PI * (3 - Math.sqrt(5))  // fibonacci sphere
    for (var i = 0; i < n; i++) {
      var y = i * off - 1 + off / 2
      var r = Math.sqrt(Math.max(0, 1 - y * y))
      var phi = i * inc
      pts.push([Math.cos(phi) * r, y, Math.sin(phi) * r])
    }
    _pts = pts
    canvas.requestPaint()
  }

  // Rotation is a WALL-CLOCK phase, not animation state: a stored-from-zero
  // NumberAnimation restarted whenever `running` flapped (pi's status flips
  // between tool cycles) or the delegate was recreated — the orb visibly
  // snapped back to its start pose. A clock phase cannot reset, and every orb
  // on screen spins in unison for free.
  FrameAnimation {
    running: orb.running
    onTriggered: orb.rot = (Date.now() % 7000) / 7000 * 2 * Math.PI
  }
  onRotChanged: canvas.requestPaint()
  onGlowChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    // Paint on the render thread: under streaming load the cooperative main-thread
    // repaints starved and the orb visibly stuttered/blanked.
    renderStrategy: Canvas.Threaded
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height, cx = w / 2, cy = h / 2
      // Largest sphere that still fits its own dots: a node sits at distance R and its
      // dot reaches R*0.20 past that, so the inset has to be that dot radius, not a
      // fixed 1.5px. At small sizes the flat inset was most of the difference — a 16px
      // box drew a ~13px sphere, so making the box bigger barely showed.
      // Badge chrome: an animated gradient disc behind the mesh, ringed in white.
      // The gradient's axis rides the same wall-clock phase as the sphere, so the
      // light appears to orbit with it. The mesh insets inside the ring.
      var ring = Math.max(1.5, Math.min(w, h) * 0.09)
      var discR = Math.min(w, h) / 2 - ring / 2 - 1   // 1px in from the item edge (AA headroom)
      var g0 = orb.glow
      // Lit-sphere shading: a radial gradient whose HIGHLIGHT orbits with the
      // phase — offset bright core → saturated glow mid → near-black rim. Big
      // luminance range is what makes it read as a gradient at 20px.
      // The highlight's own full-period clock: any (t%P)/P*2pi phase is continuous
      // at the wrap — rot*0.7 wrapped mid-angle and snapped every 7 seconds.
      var gphase = (Date.now() % 11000) / 11000 * 2 * Math.PI
      var gx = Math.cos(gphase), gy = Math.sin(gphase)
      var hx = cx + gx * discR * 0.45, hy = cy + gy * discR * 0.45
      // Duotone, not color-plus-white: the highlight is the glow's HUE-SHIFTED
      // sibling at full saturation (washing toward white read as pastel milk),
      // and the rim is the opposite shift driven deep — a saturated sweep with
      // real depth at every action color.
      var hu = g0.hslHue < 0 ? 0 : g0.hslHue
      var hi = Qt.hsla((hu + 0.09) % 1, Math.min(1, Math.max(0.75, g0.hslSaturation)), 0.62, 1)
      var rim = Qt.hsla((hu + 0.94) % 1, Math.min(1, Math.max(0.6, g0.hslSaturation)), 0.13, 1)
      var grad = ctx.createRadialGradient(hx, hy, discR * 0.35, cx, cy, discR * 1.35)
      grad.addColorStop(0.0, hi)
      grad.addColorStop(0.55, Qt.rgba(g0.r, g0.g, g0.b, 1))
      grad.addColorStop(1.0, rim)
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI)
      ctx.fillStyle = grad; ctx.fill()
      ctx.lineWidth = ring
      // The ring belongs to the duotone, not to black/white: the highlight hue,
      // brightened — it frames without introducing a foreign color. Light mode
      // deepens it instead so the badge still cuts against a pale ground.
      // The ring stays NEUTRAL — white on dark, near-black on light. Color lives
      // in the gradient only; a hued ring kept reading as "why is the outline X".
      ctx.strokeStyle = Theme.mode === "light" ? "#1F1F1F" : "#FFFFFF"
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI); ctx.stroke()

      var R = (Math.min(w, h) / 2 - ring * 1.6) / 1.2
      // Mesh removed: at badge sizes the wireframe fought the gradient in any
      // ink — the animated duotone + ring carry the whole signal.
    }
  }
}
