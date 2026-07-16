import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

// GPU mesh/streak wallpaper editor. The preview IS the renderer — a
// fragment shader with every knob bound as a uniform, so it updates at
// display refresh rate and Save grabs the identical shader at 4K.
FloatingWindow {
    id: win
    title: "wallpaper-studio"
    implicitWidth: 1360
    implicitHeight: 720
    color: "#141414"

    property string mode: "dark"
    property string style: "mesh"
    property int seed: 42
    property int waveAmp: 50
    property int waveLen: 1600
    property int swirl: 30
    property int blurV: 80
    property real grain: 0.12
    property int angle: 25
    property int streak: 220
    property real chrome: 0.5
    property int aberration: 6
    property int postBlur: 0
    property string status: ""
    property int selected: 0
    property int anchorsRev: 0

    ListModel { id: anchorsModel }
    function touchAnchors() { anchorsRev++; saveState() }

    function nudgeAnchor(dx, dy) {
        if (selected >= anchorsModel.count) return
        const a = anchorsModel.get(selected)
        anchorsModel.setProperty(selected, "ax", Math.max(0, Math.min(1, a.ax + dx)))
        anchorsModel.setProperty(selected, "ay", Math.max(0, Math.min(1, a.ay + dy)))
        touchAnchors()
    }
    function resizeAnchor(d) {
        if (selected >= anchorsModel.count) return
        const ns = Math.max(0.2, Math.min(3, anchorsModel.get(selected).size + d))
        anchorsModel.setProperty(selected, "size", ns)
        touchAnchors()
    }
    function addAnchorAt(u, v) {
        if (anchorsModel.count >= 8) return
        anchorsModel.append({ ax: u, ay: v, hex: palette[0] || "#888888", size: 1.0 })
        selected = anchorsModel.count - 1
        touchAnchors()
    }
    function removeSelAnchor() {
        if (anchorsModel.count <= 2) return
        anchorsModel.remove(selected)
        selected = Math.max(0, selected - 1)
        touchAnchors()
    }
    function cycleAnchor(d) {
        if (anchorsModel.count === 0) return
        selected = (selected + d + anchorsModel.count) % anchorsModel.count
        anchorsRev++
    }
    function cycleShape(d) {
        const i = styleNames.indexOf(style)
        retypeStyle(styleNames[(i + d + styleNames.length) % styleNames.length])
    }
    function cycleLayer(d) {
        if (layers.length < 2) return
        switchLayer((selLayer + d + layers.length) % layers.length)
    }

    // Composition model: per mode, an ordered stack of up to 4 layers, each
    // with its own style + knobs + anchors, plus a global post stack. The
    // SELECTED layer lives in the flat win.* knob properties + anchorsModel
    // (so every existing editing surface keeps working); the others rest in
    // the layers array. syncSelected/loadLayer move data between the two.
    property var contexts: ({})   // dormant v1 data, kept for rollback
    property var comps: ({})
    property var layers: []
    property int selLayer: 0
    property int layersRev: 0
    property real layerOpacity: 1
    property int layerBlend: 0    // 0 normal, 1 screen, 2 multiply, 3 overlay
    property real gGrain: 0
    property real gBlur: 0
    readonly property var styleNames: ["mesh", "streaks", "flow", "bands", "stripes", "conic", "radial", "rings", "balls", "blocks", "folds"]
    readonly property var stopStyles: ["bands", "stripes", "conic", "radial", "rings", "folds"]

    function snapshotCtx() {
        const a = []
        for (let i = 0; i < anchorsModel.count; i++) {
            const x = anchorsModel.get(i)
            a.push({ ax: x.ax, ay: x.ay, hex: x.hex, size: x.size })
        }
        return { seed: seed, waveAmp: waveAmp, waveLen: waveLen, swirl: swirl,
                 blurV: blurV, grain: grain, angle: angle, streak: streak,
                 chrome: chrome, aberration: aberration, postBlur: postBlur, anchors: a }
    }
    function applyCtx(c) {
        seed = c.seed; waveAmp = c.waveAmp; waveLen = c.waveLen; swirl = c.swirl
        blurV = c.blurV; grain = c.grain; angle = c.angle; streak = c.streak
        if (c.chrome !== undefined) chrome = c.chrome
        if (c.aberration !== undefined) aberration = c.aberration
        postBlur = c.postBlur !== undefined ? c.postBlur : 0
        anchorsModel.clear()
        for (const x of c.anchors) anchorsModel.append(x)
        selected = 0
        anchorsRev++
    }
    function defaultKnobs() {
        waveAmp = 50; waveLen = 1600; swirl = 30; blurV = 80; grain = 0.12
        angle = 25; streak = 220; chrome = 0.5; aberration = 6; postBlur = 0
    }

    function snapshotLayer() {
        return Object.assign({ style: style, opacity: layerOpacity, blend: layerBlend }, snapshotCtx())
    }
    function syncSelected() {
        if (layers.length === 0) { layers.push(snapshotLayer()); return }
        layers[selLayer] = snapshotLayer()
    }
    function loadLayer(i) {
        selLayer = i
        const l = layers[i]
        style = l.style
        layerOpacity = l.opacity !== undefined ? l.opacity : 1
        layerBlend = l.blend !== undefined ? l.blend : 0
        applyCtx(l)
        layersRev++
    }
    function switchLayer(i) {
        if (i === selLayer || i >= layers.length) return
        syncSelected()
        loadLayer(i)
        saveState()
    }
    function addLayer() {
        if (layers.length >= 4) return
        syncSelected()
        layers.push(snapshotLayer())
        selLayer = layers.length - 1
        defaultKnobs()
        layerOpacity = 0.8
        layerBlend = mode === "dark" ? 1 : 2   // screen adds light, multiply inks
        resetAnchors()
        layersRev++
        saveState()
    }
    function removeLayer() {
        if (selLayer === 0 || layers.length <= 1) return
        layers.splice(selLayer, 1)
        loadLayer(Math.max(0, selLayer - 1))
        saveState()
    }
    function retypeStyle(s) {
        if (s === style) return
        // keep anchors across same-family switches; stop-family anchors are
        // 1-D stops and make no sense as positions (and vice versa)
        const wasStop = stopStyles.includes(style)
        style = s
        if (wasStop !== stopStyles.includes(s)) resetAnchors()
        layersRev++
        saveState()
    }
    function switchMode(m) {
        if (m === mode) return
        syncSelected()
        comps[mode] = { layers: layers, post: { grain: gGrain, blur: gBlur } }
        mode = m
        const c = comps[mode]
        if (c && c.layers && c.layers.length) {
            layers = c.layers
            gGrain = c.post ? c.post.grain : 0
            gBlur = c.post ? c.post.blur : 0
            loadLayer(0)
        } else {
            layers = []
            gGrain = 0; gBlur = 0
            const legacy = contexts[m + "/" + style]
            if (legacy && legacy.anchors && legacy.anchors.length >= 2) {
                layers = [Object.assign({ style: style, opacity: 1, blend: 0 }, legacy)]
                loadLayer(0)
            } else {
                selLayer = 0
                layerOpacity = 1; layerBlend = 0
                defaultKnobs()
                resetAnchors()
                layersRev++
            }
        }
        saveState()
    }

    // ── persistence ─────────────────────────────────────────────────
    FileView {
        id: stateFile
        path: Quickshell.env("HOME") + "/.local/state/wallpaper-studio.json"
    }
    function saveState() {
        syncSelected()
        comps[mode] = { layers: layers, post: { grain: gGrain, blur: gBlur } }
        try {
            stateFile.setText(JSON.stringify({ version: 2, mode: mode, style: style, legend: showLegend,
                                               selLayer: selLayer, comps: comps, contexts: contexts }))
        } catch (e) {}
    }
    function restoreState() {
        try {
            const st = JSON.parse(stateFile.text())
            mode = st.mode || "dark"
            showLegend = st.legend === true
            contexts = st.contexts || {}
            if (st.version === 2 && st.comps && st.comps[mode] && st.comps[mode].layers.length) {
                comps = st.comps
                const c = comps[mode]
                layers = c.layers
                gGrain = c.post ? c.post.grain : 0
                gBlur = c.post ? c.post.blur : 0
                loadLayer(Math.min(st.selLayer || 0, layers.length - 1))
                return true
            }
            // v1 -> v2: the active mode/style context becomes layer 0
            style = st.style || "mesh"
            const c1 = contexts[mode + "/" + style]
            if (!c1 || !c1.anchors || c1.anchors.length < 2) return false
            layers = [Object.assign({ style: style, opacity: 1, blend: 0 }, c1)]
            loadLayer(0)
            return true
        } catch (e) { return false }
    }
    Component.onCompleted: {
        if (!restoreState()) {
            selLayer = 0
            resetAnchors()
            syncSelected()
        }
        anchorsRev++
        layersRev++
    }
    function resetAnchors() {
        anchorsModel.clear()
        // stop-family styles: anchors are color stops along t (ay), ax ignored
        const stopSets = {
            bands: {
                dark:  [["#CCD5E4", 0.08], ["#396171", 0.4], ["#0A0A0A", 0.8]],
                light: [["#FFFFFF", 0.1], ["#7DD3FC", 0.45], ["#10100E", 0.9]]
            },
            stripes: {
                dark:  [["#181818", 0.08], ["#FF570D", 0.35], ["#2E2E2E", 0.62], ["#CCD5E4", 0.9]],
                light: [["#FFFFFF", 0.1], ["#e16511", 0.4], ["#F4F5F2", 0.65], ["#0284C7", 0.9]]
            },
            conic: {
                dark:  [["#181818", 0.06], ["#396171", 0.45], ["#FF570D", 0.75], ["#181818", 0.95]],
                light: [["#FFFFFF", 0.08], ["#7DD3FC", 0.5], ["#e16511", 0.8], ["#FFFFFF", 0.96]]
            },
            radial: {
                dark:  [["#FF570D", 0.05], ["#396171", 0.4], ["#181818", 0.85]],
                light: [["#FFFFFF", 0.06], ["#7DD3FC", 0.5], ["#243560", 0.95]]
            },
            rings: {
                dark:  [["#181818", 0.1], ["#CCD5E4", 0.5], ["#181818", 0.9]],
                light: [["#FFFFFF", 0.1], ["#0284C7", 0.5], ["#FFFFFF", 0.9]]
            },
            folds: {
                dark:  [["#0A0A0A", 0.06], ["#396171", 0.38], ["#97B5A6", 0.62], ["#CCD5E4", 0.92]],
                light: [["#FFFFFF", 0.08], ["#7DD3FC", 0.45], ["#396171", 0.75], ["#243560", 0.96]]
            }
        }
        if (stopSets[style]) {
            for (const [hex, y] of stopSets[style][mode])
                anchorsModel.append({ ax: 0.5, ay: y, hex: hex, size: 1.0 })
            selected = 0
            touchAnchors()
            return
        }
        if (style === "balls") {
            const cols = mode === "dark"
                ? ["#FF570D", "#97B5A6", "#CCD5E4", "#396171", "#ff8a31"]
                : ["#e16511", "#0284C7", "#396171", "#7DD3FC", "#243560"]
            const pos = [[0.2, 0.3], [0.7, 0.2], [0.45, 0.65], [0.85, 0.75], [0.15, 0.8]]
            for (let i = 0; i < 5; i++)
                anchorsModel.append({ ax: pos[i][0], ay: pos[i][1], hex: cols[i], size: 0.5 + (i % 3) * 0.35 })
            selected = 0
            touchAnchors()
            return
        }
        if (style === "flow") {
            const cols = mode === "dark"
                ? ["#181818", "#CCD5E4", "#396171", "#181818", "#FF570D"]
                : ["#FFFFFF", "#396171", "#0284C7", "#F4F5F2", "#e16511"]
            const pos = [[0.15, 0.2], [0.6, 0.1], [0.85, 0.5], [0.35, 0.75], [0.75, 0.9]]
            for (let i = 0; i < 5; i++)
                anchorsModel.append({ ax: pos[i][0], ay: pos[i][1], hex: cols[i], size: 0.9 + (i % 2) * 0.4 })
            selected = 0
            touchAnchors()
            return
        }
        if (style === "streaks") {
            const hot = mode === "dark"
                ? ["#FFFFFF", "#FF570D", "#7DD3FC", "#CCD5E4", "#FFFFFF", "#FF570D"]
                : ["#e16511", "#0284C7", "#396171", "#e16511", "#0284C7", "#243560"]
            const pos = [[0.2, 0.25], [0.55, 0.15], [0.8, 0.35], [0.35, 0.6], [0.65, 0.75], [0.15, 0.8]]
            for (let i = 0; i < 6; i++)
                anchorsModel.append({ ax: pos[i][0], ay: pos[i][1], hex: hot[i], size: 0.5 + (i % 3) * 0.15 })
        } else {
            const base = mode === "dark" ? "#181818" : "#FFFFFF"
            const a1 = mode === "dark" ? "#FF570D" : "#df9001"
            const a2 = mode === "dark" ? "#97B5A6" : "#5E7270"
            anchorsModel.append({ ax: 0.25, ay: 0.3, hex: base, size: 1.4 })
            anchorsModel.append({ ax: 0.75, ay: 0.7, hex: base, size: 1.2 })
            anchorsModel.append({ ax: 0.7, ay: 0.2, hex: a1, size: 0.8 })
            anchorsModel.append({ ax: 0.3, ay: 0.8, hex: a2, size: 0.9 })
        }
        selected = 0
        touchAnchors()
    }

    // ── theme palette swatches ──────────────────────────────────────
    FileView {
        id: colorsFile
        path: Quickshell.env("HOME") + "/.config/themes/colors.json"
        watchChanges: true
    }
    readonly property var palette: {
        try {
            const t = JSON.parse(colorsFile.text())["themes"][mode]
            const out = []
            for (const k of ["primary", "secondary", "tertiary", "selection", "overlay", "prompt"])
                if (t.background[k]) out.push(t.background[k])
            for (const k in t.accent) out.push(t.accent[k])
            return out
        } catch (e) { return ["#181818", "#FFFFFF", "#FF570D"] }
    }
    // hex -> theme color name, for the on-canvas legend
    readonly property var paletteNames: {
        try {
            const t = JSON.parse(colorsFile.text())["themes"][mode]
            const out = {}
            for (const k of ["primary", "secondary", "tertiary", "selection", "overlay", "prompt"])
                if (t.background[k]) out[t.background[k].toLowerCase()] = k
            for (const k in t.accent) out[t.accent[k].toLowerCase()] = k
            return out
        } catch (e) { return {} }
    }
    property bool showLegend: false

    // ── per-layer uniforms ──────────────────────────────────────────
    // The selected layer reads live editing state; the rest read the array.
    // The rev counters are referenced so bindings re-evaluate on edits that
    // QML can't observe (ListModel contents, plain JS array mutation).
    function ldata(i) {
        layersRev; anchorsRev
        if (i === selLayer) return snapshotLayer()
        return i < layers.length ? layers[i] : null
    }
    function lKnob(i, k) {
        const d = ldata(i)
        return d && d[k] !== undefined ? d[k] : 0
    }
    function lStyleNum(i) {
        const d = ldata(i)
        return d ? Math.max(0, styleNames.indexOf(d.style)) : 0
    }
    function lAnchorVec(i, j) {
        const d = ldata(i)
        if (!d || j >= d.anchors.length) return Qt.vector4d(0, 0, 0, 0)
        const a = d.anchors[j]
        const sz = a.size * (d.style === "streaks" ? 0.45 : 1.0)   // flow keeps full fields
        return Qt.vector4d(a.ax, a.ay, sz, 1)
    }
    function lColorVec(i, j) {
        const d = ldata(i)
        if (!d || j >= d.anchors.length) return Qt.vector4d(0, 0, 0, 1)
        const c = Qt.color(d.anchors[j].hex)
        return Qt.vector4d(c.r, c.g, c.b, 1)
    }
    function lBase(i) {
        const d = ldata(i)
        const c = Qt.color(mode === "dark" ? "#181818" : "#FFFFFF")
        const f = (d && d.style === "streaks" && mode === "dark") ? 0.25 : 1.0
        return Qt.vector4d(c.r * f, c.g * f, c.b * f, 1)
    }
    function lOpacVec() {
        layersRev
        const v = [1, 1, 1, 1]
        for (let i = 0; i < 4; i++) {
            const d = ldata(i)
            if (d && d.opacity !== undefined) v[i] = d.opacity
        }
        return Qt.vector4d(v[0], v[1], v[2], v[3])
    }
    function lBlendVec() {
        layersRev
        const v = [0, 0, 0, 0]
        for (let i = 0; i < 4; i++) {
            const d = ldata(i)
            if (d && d.blend !== undefined) v[i] = d.blend
        }
        return Qt.vector4d(v[0], v[1], v[2], v[3])
    }

    function setPath() {
        // top-level Wallpapers dir: waypaper browses it with subfolders off,
        // so saves into generated/ never showed up in its picker
        return Quickshell.env("HOME") + "/Pictures/Wallpapers/gl-" + mode + "-" +
               seed + "-" + Math.floor(Math.random() * 100000) + ".png"
    }
    Process { id: applyProc }
    FileView {
        id: themeModeFile
        path: Quickshell.env("HOME") + "/.config/theme_mode"
        watchChanges: true
    }
    property bool pendingSet: false
    property string pendingOut: ""
    function save4k(andSet) {
        win.status = "rendering 4K…"
        pendingSet = andSet
        pendingOut = setPath()
        // layer textures follow preview size; force them to 4K before the
        // grab or the composite upscales soft copies of the layers
        const big = Qt.size(3840, 2400)
        ses0.textureSize = big; ses1.textureSize = big
        ses2.textureSize = big; ses3.textureSize = big
        saveSettle.restart()
    }
    Timer {
        id: saveSettle
        interval: 120
        onTriggered: win.doGrab()
    }
    function doGrab() {
        const out = pendingOut
        const andSet = pendingSet
        fx.grabToImage(function (res) {
            const reset = Qt.size(0, 0)
            ses0.textureSize = reset; ses1.textureSize = reset
            ses2.textureSize = reset; ses3.textureSize = reset
            if (!res.saveToFile(out)) { win.status = "save failed"; return }
            win.status = andSet ? "saved + set ✓" : "saved ✓"
            statusClear.restart()
            if (andSet) {
                // setsid: waypaper/swaybg must survive this Process's exit —
                // plain & left them in our process group and they died with
                // it (both monitors went bare-backdrop gray).
                // Set means set — apply immediately regardless of the current
                // theme mode; the symlink still lands in the composition's
                // mode slot so theme switches keep pairing correctly.
                applyProc.command = ["bash", "-c",
                    "ln -sf '" + out + "' \"$HOME/.config/themes/wallpaper-" + win.mode + "\"; " +
                    "pkill -x swaybg; setsid waypaper --wallpaper '" + out + "' >/dev/null 2>&1 </dev/null &"]
                applyProc.running = true
            }
        }, Qt.size(3840, 2400))
    }
    Timer { id: statusClear; interval: 2500; onTriggered: win.status = "" }

    // ── AI generation ───────────────────────────────────────────────
    // The AI never touches pixels: it emits state for the same schema the
    // app persists, so generations render through the identical shader.
    property var undoComp: null
    Process {
        id: genProc
        stdout: StdioCollector { onStreamFinished: win.applyGenerated(this.text) }
        stderr: StdioCollector { id: genErr }
    }
    function aiSchema() {
        return `You generate wallpaper compositions for a GPU shader wallpaper editor.
Respond with ONLY one JSON object. No prose, no markdown fences.

Schema:
{
  "layers": [ 1-3 layers; the first is the base, the rest blend on top:
    { "style": "mesh" | "streaks" | "flow" | "bands" | "stripes" | "conic" | "radial" | "rings" | "balls" | "blocks" | "folds",
      "opacity": <0-1>, "blend": "normal" | "screen" | "multiply" | "overlay",
      "seed": <int 1-99999>,
      "anchors": [ 2-8 of { "ax": <0-1>, "ay": <0-1>, "hex": "#RRGGBB", "size": <0.2-3.0> } ],
      "waveAmp": <0-160>, "waveLen": <300-3000>, "swirl": <-180 to 180>,
      "blurV": <10-220>, "grain": <0-0.5>, "angle": <-60 to 60>,
      "streak": <40-400>, "chrome": <0-1>, "aberration": <0-20>, "postBlur": <0-200> } ],
  "post": { "grain": <0-0.5>, "blur": <0-200> }
}

Layering: the base layer's opacity/blend are ignored. "screen" adds light (best on dark),
"multiply" inks color in (best on light), "overlay" boosts contrast. One layer is often
enough; reach for 2-3 when mixing structures (e.g. a folds base with streak highlights).
"post" applies grain/blur over the finished composite — prefer it over per-layer grain.

Styles (for the stop-family — bands/stripes/conic/radial/rings/folds — anchors are color STOPS: ay = position along the gradient 0-1, ax ignored, size = stop weight):
- mesh: soft mesh gradient; anchors are colored blobs blended by inverse-distance. blurV = softness, postBlur = extra blur. Large-size dark/base anchors make breathing room.
- streaks: hot glowing cores smeared into directional strokes on a near-solid stage. streak = length, angle = direction, chrome = brushed-filament texture, aberration = chromatic fringing. Anchor size stays small (0.4-0.9).
- flow: the mesh field smeared directionally, like silk folds. Uses streak/angle/chrome too.
- bands: horizontal color bands, rotated by angle, warped by waveAmp/waveLen/swirl.
- stripes: repeating angled stripes; waveLen = stripe period in px, angle = direction.
- conic: angular sweep around the center (mirrored, seamless), rotated by angle.
- radial: radial gradient; ay 0 = center, 1 = corners.
- rings: repeating concentric rings; waveLen = ring period in px.
- balls: anchors are soft solid discs on the base color; size = disc radius, blurV = edge softness. Position via ax/ay like mesh.
- blocks: pixel-mosaic of the mesh gradient; waveLen = block size in px. Anchors position like mesh.
- folds: draped folded-silk sheets of light (domain-warped noise); waveLen = fold scale (small = many folds), chrome = drape lighting strength, seed reshapes the folds. Elegant, Raycast-wallpaper-like.

Context:
- Mode: ${mode}. Stage/base color is ${mode === "dark" ? "#181818" : "#FFFFFF"}; compose for that ground.
- Theme palette (prefer these, other hexes allowed if they harmonize): ${JSON.stringify(palette)}
- Canvas: 3840x2400 desktop wallpaper. It sits behind windows — bold is fine, busy is not.

Pick the style that best fits the description unless one is named.`
    }
    function generate(riff) {
        if (genProc.running) return
        // empty prompt = surprise-me; the schema/palette/mode context above
        // is always the real briefing, the user text is just the vibe
        const p = promptField.text.trim()
            || (riff ? "make it more interesting — your call"
                     : "invent a tasteful composition of your choosing; feel free to pick a less obvious style")
        let full = aiSchema()
        if (riff) {
            syncSelected()
            full += "\n\nCurrent composition:\n"
                 + JSON.stringify({ layers: layers, post: { grain: gGrain, blur: gBlur } })
                 + "\n\nModify it per this instruction, keeping what already works: " + p
        } else full += "\n\nUser description: " + p
        win.status = "generating…"
        genProc.command = ["claude", "-p", full]
        genProc.running = true
    }
    function clampN(v, lo, hi, dflt) {
        const n = Number(v)
        return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : dflt
    }
    function cleanLayer(o) {
        if (!o || !Array.isArray(o.anchors) || o.anchors.length < 2) return null
        return {
            style: styleNames.includes(o.style) ? o.style : "mesh",
            opacity: clampN(o.opacity, 0, 1, 1),
            blend: ({ normal: 0, screen: 1, multiply: 2, overlay: 3 })[o.blend] || 0,
            seed: Math.round(clampN(o.seed, 1, 99999, 42)),
            waveAmp: clampN(o.waveAmp, 0, 160, 50), waveLen: clampN(o.waveLen, 300, 3000, 1600),
            swirl: clampN(o.swirl, -180, 180, 30), blurV: clampN(o.blurV, 10, 220, 80),
            grain: clampN(o.grain, 0, 0.5, 0.12), angle: clampN(o.angle, -60, 60, 25),
            streak: clampN(o.streak, 40, 400, 220), chrome: clampN(o.chrome, 0, 1, 0.5),
            aberration: clampN(o.aberration, 0, 20, 6), postBlur: clampN(o.postBlur, 0, 200, 0),
            anchors: o.anchors.slice(0, 8).map(x => ({
                ax: clampN(x.ax, 0, 1, 0.5), ay: clampN(x.ay, 0, 1, 0.5),
                hex: /^#[0-9a-fA-F]{6}$/.test(x.hex) ? x.hex : (palette[0] || "#888888"),
                size: clampN(x.size, 0.2, 3, 1)
            }))
        }
    }
    function applyGenerated(text) {
        let o
        try {
            o = JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1))
        } catch (e) {
            win.status = ("AI failed: " + (genErr.text.trim() || "bad JSON")).slice(0, 80)
            statusClear.restart()
            return
        }
        const raw = Array.isArray(o.layers) ? o.layers : (o.anchors ? [o] : [])
        const ls = raw.slice(0, 4).map(cleanLayer).filter(l => l !== null)
        if (!ls.length) {
            win.status = "AI failed: no usable layers"; statusClear.restart(); return
        }
        syncSelected()
        undoComp = JSON.parse(JSON.stringify({ layers: layers, grain: gGrain, blur: gBlur }))
        layers = ls
        gGrain = o.post ? clampN(o.post.grain, 0, 0.5, 0) : 0
        gBlur = o.post ? clampN(o.post.blur, 0, 200, 0) : 0
        loadLayer(0)
        saveState()
        win.status = "AI ✓ (" + ls.length + (ls.length > 1 ? " layers)" : " layer)")
        statusClear.restart()
    }
    function undoGenerate() {
        if (!undoComp) return
        layers = undoComp.layers
        gGrain = undoComp.grain; gBlur = undoComp.blur
        loadLayer(0)
        saveState()
        undoComp = null
    }

    component Knob: Column {
        id: knobRoot
        property string label
        property real extValue: 0
        property alias from: sl.from
        property alias to: sl.to
        property alias step: sl.stepSize
        signal moved(real v)
        width: 316
        spacing: 0
        Item {
            width: parent.width; height: 16
            Text { text: knobRoot.label; color: "#D6D6D6"; font.pixelSize: 12; font.family: "Geist" }
            Text { anchors.right: parent.right; text: Math.round(sl.value * 100) / 100; color: "#707B84"; font.pixelSize: 12; font.family: "Geist" }
        }
        Slider {
            id: sl; width: parent.width; height: 24
            onMoved: knobRoot.moved(value)
            background: Rectangle {
                y: sl.height / 2 - 2; width: sl.width; height: 4; radius: 2; color: "#2E2E2E"
                Rectangle { width: sl.visualPosition * parent.width; height: parent.height; radius: 2; color: "#9AA7B0" }
            }
            handle: Rectangle {
                x: sl.visualPosition * (sl.width - width); y: sl.height / 2 - height / 2
                width: 14; height: 14; radius: 7; color: "#EDEDED"
            }
        }
        // A plain value binding is severed by the first user drag; a Binding
        // element re-asserts on context switches.
        Binding { target: sl; property: "value"; value: knobRoot.extValue }
    }
    component SectionLabel: Text {
        color: "#707B84"
        font.pixelSize: 11
        font.weight: 600
        font.letterSpacing: 1.2
        font.family: "Geist"
        font.capitalization: Font.AllUppercase
    }
    component Chip: Rectangle {
        property string label
        signal clicked()
        width: chipText.implicitWidth + 20; height: 26; radius: 13; color: "#2A2A2A"
        border.width: 1; border.color: "#3A3A3A"
        Text { id: chipText; anchors.centerIn: parent; text: parent.label; color: "#EDEDED"; font.pixelSize: 12; font.family: "Geist" }
        TapHandler { onTapped: parent.clicked() }
    }
    component Pill: Rectangle {
        property string label
        property bool active: false
        signal clicked()
        width: pillText.implicitWidth + 24
        height: 28; radius: 14
        color: active ? "#EDEDED" : "#2A2A2A"
        Text { id: pillText; anchors.centerIn: parent; text: parent.label; color: parent.active ? "#141414" : "#D6D6D6"; font.pixelSize: 12; font.family: "Geist" }
        TapHandler { onTapped: parent.clicked() }
    }
    component Card: Rectangle {
        default property alias content: inner.data
        width: 344
        implicitHeight: inner.implicitHeight + 28
        radius: 14
        color: "#1F1F1F"
        Column { id: inner; x: 14; y: 14; width: parent.width - 28; spacing: 10 }
    }
    // one layer of the composition, rendered with the shared wallpaper shader
    component LayerFx: ShaderEffect {
        required property int li
        fragmentShader: "file://" + Quickshell.env("HOME") + "/.config/themes/wallpaper.frag.qsb"
        property vector4d a0: win.lAnchorVec(li, 0)
        property vector4d a1: win.lAnchorVec(li, 1)
        property vector4d a2: win.lAnchorVec(li, 2)
        property vector4d a3: win.lAnchorVec(li, 3)
        property vector4d a4: win.lAnchorVec(li, 4)
        property vector4d a5: win.lAnchorVec(li, 5)
        property vector4d a6: win.lAnchorVec(li, 6)
        property vector4d a7: win.lAnchorVec(li, 7)
        property vector4d c0: win.lColorVec(li, 0)
        property vector4d c1: win.lColorVec(li, 1)
        property vector4d c2: win.lColorVec(li, 2)
        property vector4d c3: win.lColorVec(li, 3)
        property vector4d c4: win.lColorVec(li, 4)
        property vector4d c5: win.lColorVec(li, 5)
        property vector4d c6: win.lColorVec(li, 6)
        property vector4d c7: win.lColorVec(li, 7)
        property vector4d baseColor: win.lBase(li)
        property real styleMode: win.lStyleNum(li)
        property real modeLight: win.mode === "light" ? 1 : 0
        property real waveAmp: win.lKnob(li, "waveAmp")
        property real waveLen: win.lKnob(li, "waveLen")
        property real swirlDeg: win.lKnob(li, "swirl")
        property real blurK: win.lKnob(li, "blurV")
        property real grainAmt: win.lKnob(li, "grain")
        property real angleDeg: win.lKnob(li, "angle")
        property real streakLen: win.lKnob(li, "streak")
        property real aberr: win.lKnob(li, "aberration")
        property real seedF: win.lKnob(li, "seed")
        property real chromeAmt: win.lKnob(li, "chrome")
        property real postBlur: win.lKnob(li, "postBlur")
    }

    Row {
        id: mainRow
        anchors.fill: parent
        focus: true

        // Vim bindings, following the house picker idiom: ctrl-combos work
        // everywhere (even while typing in the prompt); plain keys only when
        // the prompt isn't focused. i = insert (focus prompt), Esc = leave.
        Keys.onPressed: event => {
            const ctrl = event.modifiers & Qt.ControlModifier
            const shift = event.modifiers & Qt.ShiftModifier
            const k = event.key
            event.accepted = true
            if (ctrl && k === Qt.Key_J) win.cycleAnchor(1)
            else if (ctrl && k === Qt.Key_K) win.cycleAnchor(-1)
            else if (ctrl && shift && (k === Qt.Key_H || k === Qt.Key_L)) win.cycleShape(k === Qt.Key_L ? 1 : -1)
            else if (ctrl && (k === Qt.Key_H || k === Qt.Key_L)) win.cycleLayer(k === Qt.Key_L ? 1 : -1)
            else if (ctrl && shift && k === Qt.Key_S) win.save4k(true)
            else if (ctrl && k === Qt.Key_S) win.save4k(false)
            else if (k === Qt.Key_Escape) {
                if (promptField.activeFocus) { promptField.focus = false; mainRow.forceActiveFocus() }
                else event.accepted = false
            }
            else if (promptField.activeFocus) event.accepted = false
            else if (k === Qt.Key_H) win.nudgeAnchor(shift ? -0.05 : -0.01, 0)
            else if (k === Qt.Key_L) win.nudgeAnchor(shift ? 0.05 : 0.01, 0)
            else if (k === Qt.Key_J) win.nudgeAnchor(0, shift ? 0.05 : 0.01)
            else if (k === Qt.Key_K) win.nudgeAnchor(0, shift ? -0.05 : -0.01)
            else if (k === Qt.Key_Minus) win.resizeAnchor(-0.1)
            else if (k === Qt.Key_Equal || k === Qt.Key_Plus) win.resizeAnchor(0.1)
            else if (k === Qt.Key_I) promptField.forceActiveFocus()
            else if (k === Qt.Key_R) win.generate(true)
            else if (k === Qt.Key_U) win.undoGenerate()
            else if (k === Qt.Key_A) win.addAnchorAt(0.5, 0.5)
            else if (shift && k === Qt.Key_X) win.removeLayer()
            else if (k === Qt.Key_X) win.removeSelAnchor()
            else if (k === Qt.Key_N) win.addLayer()
            else if (k === Qt.Key_M) win.switchMode(win.mode === "dark" ? "light" : "dark")
            else if (k === Qt.Key_T) { win.showLegend = !win.showLegend; win.saveState() }
            else if (k >= Qt.Key_1 && k <= Qt.Key_4) {
                const i = k - Qt.Key_1
                if (i < win.layers.length) win.switchLayer(i)
            }
            else event.accepted = false
        }

        // ── live shader preview + draggable anchors ─────────────────
        Rectangle {
            id: stage
            width: parent.width - panelScroll.width; height: parent.height
            color: "#0E0E0E"

            readonly property real fitW: Math.min(width - 28, (height - 28) * 1.6)
            readonly property real fitH: fitW / 1.6
            readonly property real ox: (width - fitW) / 2
            readonly property real oy: (height - fitH) / 2

            // hidden per-layer renders -> textures -> composite. The layer
            // items must stay in the visible tree (ShaderEffectSource won't
            // render an invisible source); hideSource keeps them off screen.
            LayerFx { id: lfx0; li: 0; x: stage.ox; y: stage.oy; width: stage.fitW; height: stage.fitH }
            LayerFx { id: lfx1; li: 1; x: stage.ox; y: stage.oy; width: stage.fitW; height: stage.fitH }
            LayerFx { id: lfx2; li: 2; x: stage.ox; y: stage.oy; width: stage.fitW; height: stage.fitH }
            LayerFx { id: lfx3; li: 3; x: stage.ox; y: stage.oy; width: stage.fitW; height: stage.fitH }
            ShaderEffectSource { id: ses0; sourceItem: lfx0; hideSource: true; visible: false }
            ShaderEffectSource { id: ses1; sourceItem: lfx1; hideSource: true; visible: false }
            ShaderEffectSource { id: ses2; sourceItem: lfx2; hideSource: true; visible: false }
            ShaderEffectSource { id: ses3; sourceItem: lfx3; hideSource: true; visible: false }

            ShaderEffect {
                id: fx
                x: stage.ox; y: stage.oy
                width: stage.fitW; height: stage.fitH
                fragmentShader: "file://" + Quickshell.env("HOME") + "/.config/themes/composite.frag.qsb"
                property var s0: ses0
                property var s1: ses1
                property var s2: ses2
                property var s3: ses3
                property vector4d opac: win.lOpacVec()
                property vector4d modev: win.lBlendVec()
                property real count: { win.layersRev; return Math.max(1, win.layers.length) }
                property real gGrain: win.gGrain
                property real gBlur: win.gBlur
                property real seedF: win.seed
            }

            // rounded-corner frame: a thick border whose inner radius bites
            // the fx corners; preview chrome only, never in the 4K grab
            Rectangle {
                x: fx.x - 20; y: fx.y - 20
                width: fx.width + 40; height: fx.height + 40
                color: "transparent"
                border.color: stage.color
                border.width: 20
                radius: 34
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onDoubleTapped: e => {
                    const u = (e.position.x - stage.ox) / stage.fitW
                    const v = (e.position.y - stage.oy) / stage.fitH
                    if (u < 0 || u > 1 || v < 0 || v > 1) return
                    win.addAnchorAt(u, v)
                }
            }

            Repeater {
                model: anchorsModel
                Rectangle {
                    id: handle
                    required property int index
                    required property real ax
                    required property real ay
                    required property string hex
                    required property real size
                    readonly property bool isSel: win.selected === index
                    width: 16 + size * 14; height: width; radius: width / 2
                    x: stage.ox + ax * stage.fitW - width / 2
                    y: stage.oy + ay * stage.fitH - height / 2
                    color: hex
                    border.width: isSel ? 3 : 1
                    border.color: isSel ? "#FF570D" : "#EDEDED"

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.SizeAllCursor
                        onPressed: win.selected = handle.index
                        onPositionChanged: mouse => {
                            if (!pressed) return
                            const p = mapToItem(stage, mouse.x, mouse.y)
                            const u = Math.max(0, Math.min(1, (p.x - stage.ox) / stage.fitW))
                            const v = Math.max(0, Math.min(1, (p.y - stage.oy) / stage.fitH))
                            anchorsModel.setProperty(handle.index, "ax", u)
                            anchorsModel.setProperty(handle.index, "ay", v)
                            win.touchAnchors()
                        }
                        onWheel: wheel => {
                            win.selected = handle.index
                            const d = wheel.angleDelta.y > 0 ? 0.1 : -0.1
                            const ns = Math.max(0.2, Math.min(3, handle.size + d))
                            anchorsModel.setProperty(handle.index, "size", ns)
                            win.touchAnchors()
                        }
                    }
                }
            }

            // on-canvas color legend, styled after the reference: white pills
            // with dot + theme name + hex, hugging the preview's right edge
            Column {
                visible: win.showLegend
                x: stage.ox + stage.fitW - width - 16
                y: stage.oy + 16
                spacing: 8
                Repeater {
                    model: anchorsModel
                    Rectangle {
                        required property string hex
                        width: legendRow.implicitWidth + 22; height: 30; radius: 15
                        color: "#F2F2F2"
                        Row {
                            id: legendRow
                            anchors.centerIn: parent
                            spacing: 7
                            Rectangle {
                                width: 12; height: 12; radius: 6
                                anchors.verticalCenter: parent.verticalCenter
                                color: parent.parent.hex
                                border.width: 1; border.color: "#22000000"
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: {
                                    const h = parent.parent.hex
                                    const n = win.paletteNames[h.toLowerCase()]
                                    return (n ? n.toUpperCase() + "  " : "") + h.toUpperCase()
                                }
                                color: "#181818"
                                font.pixelSize: 11; font.weight: 600; font.family: "Geist"
                            }
                        }
                    }
                }
            }
        }

        // ── controls ────────────────────────────────────────────────
        Flickable {
            id: panelScroll
            width: 380; height: parent.height
            contentHeight: panel.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: panel
                width: 380
                padding: 18
                spacing: 12

                Card {
                    SectionLabel { text: "AI — starting point" }
                    Rectangle {
                        width: 316; height: 32; radius: 16; color: "#2A2A2A"
                        TextInput {
                            id: promptField
                            anchors.fill: parent
                            anchors.leftMargin: 12; anchors.rightMargin: 12
                            verticalAlignment: TextInput.AlignVCenter
                            color: "#EDEDED"; font.pixelSize: 12; font.family: "Geist"
                            clip: true
                            onAccepted: win.generate(false)
                        }
                        Text {
                            visible: promptField.text === "" && !promptField.activeFocus
                            anchors.verticalCenter: parent.verticalCenter; x: 12
                            text: "describe a vibe — or just hit generate"
                            color: "#707B84"; font.pixelSize: 12; font.family: "Geist"
                        }
                    }
                    Row {
                        spacing: 8
                        Chip { label: genProc.running ? "generating…" : "generate"; onClicked: win.generate(false) }
                        Chip { label: "riff on current"; onClicked: win.generate(true) }
                        Chip { visible: win.undoComp !== null; label: "undo"; onClicked: win.undoGenerate() }
                    }
                }

                Card {
                    SectionLabel { text: "Mode" }
                    Row {
                        spacing: 6
                        Repeater {
                            model: ["dark", "light"]
                            Pill {
                                required property string modelData
                                width: 155
                                label: modelData
                                active: win.mode === modelData
                                onClicked: win.switchMode(modelData)
                            }
                        }
                    }
                    SectionLabel { text: "Shape — of selected layer" }
                    Flow {
                        width: 316; spacing: 6
                        Repeater {
                            model: win.styleNames
                            Pill {
                                required property string modelData
                                width: 74
                                label: modelData
                                active: win.style === modelData
                                onClicked: win.retypeStyle(modelData)
                            }
                        }
                    }
                }

                Card {
                    SectionLabel { text: "Layers" }
                    Flow {
                        width: 316; spacing: 6
                        Repeater {
                            model: { win.layersRev; return win.layers.map((l, i) => ({ idx: i, name: (i + 1) + " · " + (i === win.selLayer ? win.style : l.style) })) }
                            Pill {
                                required property var modelData
                                label: modelData.name
                                active: win.selLayer === modelData.idx
                                onClicked: win.switchLayer(modelData.idx)
                            }
                        }
                        Chip { visible: win.layersRev >= 0 && win.layers.length < 4; label: "+ add"; onClicked: win.addLayer() }
                        Chip { visible: win.selLayer > 0; label: "remove"; onClicked: win.removeLayer() }
                    }
                    Row {
                        visible: win.selLayer > 0
                        spacing: 6
                        Repeater {
                            model: ["normal", "screen", "multiply", "overlay"]
                            Pill {
                                required property string modelData
                                required property int index
                                width: 74
                                label: modelData
                                active: win.layerBlend === index
                                onClicked: { win.layerBlend = index; win.saveState() }
                            }
                        }
                    }
                    Knob { visible: win.selLayer > 0; label: "layer opacity"; from: 0; to: 1; step: 0.02; extValue: win.layerOpacity; onMoved: v => { win.layerOpacity = v; win.saveState() } }
                }

                Card {
                    SectionLabel { text: "Adjust" }
                    Knob { visible: ["streaks", "flow", "folds"].includes(win.style); label: win.style === "folds" ? "ribbon" : "chrome"; from: 0; to: 1; step: 0.02; extValue: win.chrome; onMoved: v => { win.chrome = v; win.saveState() } }
                    Knob { visible: win.style === "streaks" || win.style === "flow"; label: "chromatic shift"; from: 0; to: 20; step: 1; extValue: win.aberration; onMoved: v => { win.aberration = v; win.saveState() } }
                    Knob { visible: win.style === "streaks" || win.style === "flow"; label: "streak length"; from: 40; to: 400; step: 5; extValue: win.streak; onMoved: v => { win.streak = v; win.saveState() } }
                    Knob { visible: !["mesh", "radial", "balls", "blocks"].includes(win.style); label: win.style === "folds" ? "rotation" : "angle"; from: -60; to: 60; step: 1; extValue: win.angle; onMoved: v => { win.angle = v; win.saveState() } }
                    Knob { visible: win.style !== "folds"; label: "wave amplitude"; from: 0; to: 160; step: 1; extValue: win.waveAmp; onMoved: v => { win.waveAmp = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "saturation"; from: 0; to: 2; step: 0.05; extValue: win.waveAmp; onMoved: v => { win.waveAmp = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "ribbon width"; from: 0.1; to: 2; step: 0.05; extValue: win.streak; onMoved: v => { win.streak = v; win.saveState() } }
                    Knob { visible: win.style !== "folds"; label: ["stripes", "rings"].includes(win.style) ? "period" : win.style === "blocks" ? "block size" : "wave length"; from: 300; to: 3000; step: 10; extValue: win.waveLen; onMoved: v => { win.waveLen = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "zoom"; from: 1; to: 24; step: 1; extValue: win.waveLen; onMoved: v => { win.waveLen = v; win.saveState() } }
                    Knob { visible: win.style !== "folds"; label: "swirl"; from: -180; to: 180; step: 1; extValue: win.swirl; onMoved: v => { win.swirl = v; win.saveState() } }
                    Knob { visible: !["streaks", "folds"].includes(win.style); label: "softness"; from: 10; to: 220; step: 1; extValue: win.blurV; onMoved: v => { win.blurV = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "softness"; from: 0; to: 2; step: 0.05; extValue: win.blurV; onMoved: v => { win.blurV = v; win.saveState() } }
                    Knob { visible: !["streaks", "flow", "folds"].includes(win.style); label: "soft blur"; from: 0; to: 200; step: 2; extValue: win.postBlur; onMoved: v => { win.postBlur = v; win.saveState() } }
                    Knob { visible: win.style !== "folds"; label: "grain"; from: 0; to: 0.5; step: 0.01; extValue: win.grain; onMoved: v => { win.grain = v; win.saveState() } }
                }

                Card {
                    SectionLabel { text: "Selected anchor — " + (win.selected + 1) + " of " + anchorsModel.count }
                    Text { text: "drag to move, scroll to resize, double-click canvas to add (max 8)"
                           width: 316; wrapMode: Text.WordWrap; color: "#707B84"; font.pixelSize: 11; font.family: "Geist" }

                    Flow {
                        width: 316; spacing: 6
                        Repeater {
                            model: win.palette
                            Rectangle {
                                required property string modelData
                                width: 30; height: 30; radius: 8
                                color: modelData
                                border.width: anchorsModel.count > win.selected && anchorsModel.get(win.selected).hex === modelData ? 3 : 1
                                border.color: border.width === 3 ? "#FF570D" : "#3A3A3A"
                                TapHandler { onTapped: {
                                    anchorsModel.setProperty(win.selected, "hex", parent.modelData)
                                    win.touchAnchors()
                                } }
                            }
                        }
                    }

                    Knob {
                        label: "anchor size"
                        from: 0.2; to: 3; step: 0.05
                        extValue: { win.anchorsRev; return anchorsModel.count > win.selected ? anchorsModel.get(win.selected).size : 1 }
                        onMoved: v => { anchorsModel.setProperty(win.selected, "size", v); win.touchAnchors() }
                    }

                    Row {
                        spacing: 8
                        Chip { label: "remove anchor"; onClicked: win.removeSelAnchor() }
                        Chip { label: "reset anchors"; onClicked: win.resetAnchors() }
                        Chip { label: win.showLegend ? "legend ✓" : "legend"; onClicked: { win.showLegend = !win.showLegend; win.saveState() } }
                    }
                }

                Card {
                    SectionLabel { text: "Post — over all layers" }
                    Knob { label: "global grain"; from: 0; to: 0.5; step: 0.01; extValue: win.gGrain; onMoved: v => { win.gGrain = v; win.saveState() } }
                    Knob { label: "global soft blur"; from: 0; to: 200; step: 2; extValue: win.gBlur; onMoved: v => { win.gBlur = v; win.saveState() } }
                }

                Row {
                    spacing: 8
                    Rectangle {
                        width: 168; height: 34; radius: 17; color: "#EDEDED"
                        Text { anchors.centerIn: parent; text: "Save 4K"; color: "#141414"; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                        TapHandler { onTapped: win.save4k(false) }
                    }
                    Rectangle {
                        width: 168; height: 34; radius: 17; color: "#2A2A2A"
                        border.width: 1; border.color: "#3A3A3A"
                        Text { anchors.centerIn: parent; text: "Save + Set"; color: "#EDEDED"; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                        TapHandler { onTapped: win.save4k(true) }
                    }
                }
                Text { text: win.status; color: "#97B5A6"; font.pixelSize: 12; font.family: "Geist" }
                Item { width: 1; height: 12 }
            }
        }
    }
}
