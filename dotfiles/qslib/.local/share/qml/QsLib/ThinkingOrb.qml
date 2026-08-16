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
      var hu = g0.hslHue < 0 ? 0 : g0.hslHue
      var sat = Math.min(1, Math.max(0.75, g0.hslSaturation))

      // Aurora mesh: soft color blobs on independent Lissajous orbits, blended
      // additively inside the disc. Every phase is a wall-clock (t%P)/P phase with
      // PRIME-ish periods, so the composite pattern drifts without ever visibly
      // looping or resetting — intricate at 44px, alive even at 20px.
      ctx.save()
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI); ctx.clip()
      // deep ground of the action hue so the blobs have something to glow out of
      ctx.fillStyle = Qt.hsla((hu + 0.94) % 1, sat, 0.10, 1)
      ctx.fillRect(cx - discR, cy - discR, discR * 2, discR * 2)
      var t = Date.now()
      function ph(P) { return (t % P) / P * 2 * Math.PI }
      // [xPeriod ms, yPeriod ms, orbit xr, orbit yr, blob size, hue offset, lightness]
      var blobs = [
        [ 8300, 12700, 0.55, 0.35, 1.00, 0.00, 0.52],
        [11900,  7300, 0.40, 0.60, 0.80, 0.07, 0.60],
        [ 9700, 14300, 0.62, 0.50, 0.66, -0.06, 0.46],
        [15100, 10100, 0.30, 0.45, 0.90, 0.13, 0.66]
      ]
      ctx.globalCompositeOperation = "lighter"
      for (var bi = 0; bi < blobs.length; bi++) {
        var B = blobs[bi]
        var bx = cx + Math.cos(ph(B[0]) + bi * 1.7) * discR * B[2]
        var by = cy + Math.sin(ph(B[1]) + bi * 2.3) * discR * B[3]
        var br = discR * B[4]
        var bh = ((hu + B[5]) % 1 + 1) % 1
        var bg = ctx.createRadialGradient(bx, by, 0, bx, by, br)
        bg.addColorStop(0.0, Qt.hsla(bh, sat, B[6], 0.85))
        bg.addColorStop(0.55, Qt.hsla(bh, sat, B[6] * 0.8, 0.35))
        bg.addColorStop(1.0, Qt.hsla(bh, sat, B[6] * 0.6, 0))
        ctx.fillStyle = bg
        ctx.beginPath(); ctx.arc(bx, by, br, 0, 2 * Math.PI); ctx.fill()
      }
      ctx.globalCompositeOperation = "source-over"
      ctx.restore()

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
