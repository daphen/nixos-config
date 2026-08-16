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

      // Aurora morph: filled amoeba shapes whose OUTLINES deform continuously.
      // Each shape is a closed smooth curve through points whose radii breathe on
      // two sine harmonics with independent wall-clock phases -- the silhouette
      // itself morphs (ribbons before this just read as rotating lines). Overlaps
      // blend additively into brighter creases that fold and unfold.
      ctx.save()
      ctx.beginPath(); ctx.arc(cx, cy, discR, 0, 2 * Math.PI); ctx.clip()
      ctx.fillStyle = Qt.hsla((hu + 0.94) % 1, sat, 0.10, 1)
      ctx.fillRect(cx - discR, cy - discR, discR * 2, discR * 2)
      var t = Date.now()
      function ph(P) { return (t % P) / P * 2 * Math.PI }
      var core = ctx.createRadialGradient(cx, cy, 0, cx, cy, discR)
      core.addColorStop(0, Qt.hsla(hu, sat, 0.28, 0.45))
      core.addColorStop(1, Qt.hsla(hu, sat, 0.12, 0))
      ctx.fillStyle = core
      ctx.fillRect(cx - discR, cy - discR, discR * 2, discR * 2)
      ctx.globalCompositeOperation = "lighter"
      // [driftPx, driftPy, morphP1, morphP2, base r, hue off, lightness, alpha]
      var shapes = [
        [16900, 12700,  8300, 11300, 0.62, 0.00, 0.55, 0.50],
        [13100, 17900,  9700,  7300, 0.50, 0.07, 0.62, 0.45],
        [19700, 14300, 10900,  8900, 0.44, -0.06, 0.48, 0.45]
      ]
      var N = 9  // outline points per shape; smooth-closed via midpoint quadratics
      for (var si = 0; si < shapes.length; si++) {
        var S2 = shapes[si]
        var scx = cx + Math.cos(ph(S2[0]) + si * 2.1) * discR * 0.38
        var scy = cy + Math.sin(ph(S2[1]) + si * 1.4) * discR * 0.38
        var base = discR * S2[4]
        var m1 = ph(S2[2]), m2 = ph(S2[3])
        var pts = []
        for (var i = 0; i < N; i++) {
          var a = i / N * 2 * Math.PI
          // two harmonics (2 and 3 lobes) at different clocks = the morph
          var rr = base * (1 + 0.38 * Math.sin(2 * a + m1 + si) + 0.26 * Math.sin(3 * a - m2 + si * 2))
          pts.push([scx + Math.cos(a) * rr, scy + Math.sin(a) * rr])
        }
        var bh = ((hu + S2[5]) % 1 + 1) % 1
        var fg = ctx.createRadialGradient(scx, scy, 0, scx, scy, base * 1.6)
        fg.addColorStop(0,   Qt.hsla(bh, sat, S2[6], S2[7]))
        fg.addColorStop(0.7, Qt.hsla((bh + 0.04) % 1, sat, S2[6] * 0.75, S2[7] * 0.6))
        fg.addColorStop(1,   Qt.hsla(bh, sat, S2[6] * 0.5, 0))
        ctx.fillStyle = fg
        ctx.beginPath()
        var mx = (pts[0][0] + pts[1][0]) / 2, my = (pts[0][1] + pts[1][1]) / 2
        ctx.moveTo(mx, my)
        for (var j = 1; j <= N; j++) {
          var p1 = pts[j % N], p2 = pts[(j + 1) % N]
          ctx.quadraticCurveTo(p1[0], p1[1], (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2)
        }
        ctx.closePath()
        ctx.fill()
      }
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
