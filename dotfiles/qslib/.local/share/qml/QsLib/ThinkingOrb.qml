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
      var ring = Math.max(1.25, Math.min(w, h) * 0.065)
      var discR = Math.min(w, h) / 2 - ring / 2 - 1   // 1px in from the item edge (AA headroom)
      var g0 = orb.glow
      var hu = g0.hslHue < 0 ? 0 : g0.hslHue
      var sat = Math.min(1, Math.max(0.75, g0.hslSaturation))

      // Aurora folds: silk-like ribbons instead of round blobs. Each ribbon is a
      // cubic bezier swept across the disc and stroked in feathered passes (wide
      // faint -> narrow bright), additively blended, so overlaps read as creases
      // of folded light. Endpoints/controls all drift on wall-clock phases with
      // prime-ish periods -- the folds slide and re-crease without ever looping.
      ctx.save()
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI); ctx.clip()
      ctx.fillStyle = Qt.hsla((hu + 0.94) % 1, sat, 0.10, 1)
      ctx.fillRect(cx - discR, cy - discR, discR * 2, discR * 2)
      var t = Date.now()
      function ph(P) { return (t % P) / P * 2 * Math.PI }
      // dim core glow so the folds sit IN something, not on flat black
      var core = ctx.createRadialGradient(cx, cy, 0, cx, cy, discR)
      core.addColorStop(0, Qt.hsla(hu, sat, 0.30, 0.5))
      core.addColorStop(1, Qt.hsla(hu, sat, 0.12, 0))
      ctx.fillStyle = core
      ctx.fillRect(cx - discR, cy - discR, discR * 2, discR * 2)
      ctx.globalCompositeOperation = "lighter"
      ctx.lineCap = "round"
      // [angPeriod, wobblePeriod, foldPeriod, hue offset, lightness, base width]
      var ribbons = [
        [17300,  8300, 12700, 0.00, 0.55, 0.85],
        [13100, 10900,  7900, 0.07, 0.62, 0.65],
        [19700,  7300, 14900, -0.06, 0.48, 0.75]
      ]
      for (var ri = 0; ri < ribbons.length; ri++) {
        var R2 = ribbons[ri]
        var ang = ph(R2[0]) + ri * 2.1
        var wob = Math.sin(ph(R2[1]) + ri * 1.3) * 0.7
        var fold = Math.sin(ph(R2[2]) + ri * 2.6)
        // endpoints outside the disc so clipped ends never show round caps
        var er = discR * 1.35
        var x0 = cx + Math.cos(ang) * er,        y0 = cy + Math.sin(ang) * er
        var x3 = cx + Math.cos(ang + Math.PI + wob) * er
        var y3 = cy + Math.sin(ang + Math.PI + wob) * er
        // controls pushed to opposite sides of the chord = S-curve = a crease
        var px = -Math.sin(ang), py = Math.cos(ang)
        var k = discR * (0.5 + 0.45 * fold)
        var c1x = cx + px * k,  c1y = cy + py * k
        var c2x = cx - px * k * 0.8, c2y = cy - py * k * 0.8
        var bh = ((hu + R2[3]) % 1 + 1) % 1
        var lg = ctx.createLinearGradient(x0, y0, x3, y3)
        lg.addColorStop(0,   Qt.hsla(bh, sat, R2[4] * 0.7, 1))
        lg.addColorStop(0.5, Qt.hsla((bh + 0.05) % 1, sat, R2[4], 1))
        lg.addColorStop(1,   Qt.hsla(bh, sat, R2[4] * 0.6, 1))
        ctx.strokeStyle = lg
        // feathered passes: wide+faint underneath, narrow+bright crest on top
        var passes = [[1.0, 0.10], [0.55, 0.16], [0.24, 0.30]]
        for (var pi = 0; pi < passes.length; pi++) {
          ctx.globalAlpha = passes[pi][1]
          ctx.lineWidth = discR * R2[5] * passes[pi][0]
          ctx.beginPath()
          ctx.moveTo(x0, y0)
          ctx.bezierCurveTo(c1x, c1y, c2x, c2y, x3, y3)
          ctx.stroke()
        }
      }
      ctx.globalAlpha = 1
      ctx.globalCompositeOperation = "source-over"
      ctx.restore()

      ctx.lineWidth = ring
      // The ring rides the action hue — bright tint of it on dark, deep shade on
      // light — so the frame belongs to the aurora instead of cutting against it.
      ctx.strokeStyle = Qt.hsla(hu, sat * 0.85, Theme.mode === "light" ? 0.34 : 0.82, 1)
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI); ctx.stroke()

      var R = (Math.min(w, h) / 2 - ring * 1.6) / 1.2
      // Mesh removed: at badge sizes the wireframe fought the gradient in any
      // ink — the animated duotone + ring carry the whole signal.
    }
  }
}
