import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import QsLib as QsLib

// GPU mesh/streak wallpaper editor. The preview IS the renderer — a
// fragment shader with every knob bound as a uniform, so it updates at
// display refresh rate and Save grabs the identical shader at 4K.
FloatingWindow {
    id: win
    title: "wallpaper-studio"
    implicitWidth: 1360
    implicitHeight: 720
    color: QsLib.Theme.bg

    readonly property color chromeStage: QsLib.Theme.bgDim
    readonly property color chromeSurface: QsLib.Theme.surface1
    readonly property color chromeControl: QsLib.Theme.surface2
    readonly property color chromeBorder: QsLib.Theme.hairline
    readonly property color chromeText: QsLib.Theme.fg
    readonly property color chromeSecondary: QsLib.Theme.fg_secondary
    readonly property color chromeMuted: QsLib.Theme.fg_muted

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
    property string studioView: "wallpaper"
    property real orbAngle: -0.76
    property real orbBandX: 1.35
    property real orbBandY: 1.2
    property real orbWarp: 1.5
    property real orbGrain: 0.54
    property real orbFeather: 0.96
    property real orbBright: 0.55
    property real orbSwirl: 1.2
    property real orbPlasma: 0.05
    property string orbAction: "bash"
    property color orbCustomGlow: QsLib.AgentActivity.colorFor("bash")
    property real orbSize: 120
    property bool orbPlaying: false
    property string orbStatus: ""
    property int selected: 0
    property int anchorsRev: 0
    property real tNow: 0
    property bool playing: false
    // Paper static-mesh-gradient controls (pmesh style) — reference defaults
    property real pmPositions: 23
    property real pmWaveX: 0.53
    property real pmWaveXShift: 0.0
    property real pmWaveY: 0.95
    property real pmWaveYShift: 0.64
    property real pmMixing: 0.5
    property real pmGrainMix: 0.0
    property real pmGrainOverlay: 0.24
    // Paper warp controls (warp style) — reference "checks" preset defaults
    property real wProportion: 0.45
    property real wSoftness: 1.0
    property real wShape: 0
    property real wShapeScale: 0.1
    property real wDistortion: 0.25
    property real wSwirl: 0.8
    property real wSwirlIter: 10
    property real wScale: 1.0

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
    // fluted-glass layer params (global; the composite reads them for whichever
    // layer has style "glass"). Defaults ≈ Paper's default fluted glass.
    property real glSize: 0.5
    property real glAngle: 90
    property real glShape: 1
    property real glDistShape: 2
    property real glDistortion: 0.5
    property real glShadows: 0.5
    property real glHighlights: 0.5
    property real glBlur: 0.1
    // dither layer params (global; composite reads them for the "dither" layer)
    property real dPxSize: 4
    property real dType: 3
    property real dLevels: 4
    readonly property var styleNames: ["mesh", "streaks", "flow", "bands", "stripes", "conic", "radial", "rings", "balls", "blocks", "folds", "pmesh", "warp", "glass", "dither"]
    readonly property var stopStyles: ["bands", "stripes", "conic", "radial", "rings", "folds"]

    function snapshotCtx() {
        const a = []
        for (let i = 0; i < anchorsModel.count; i++) {
            const x = anchorsModel.get(i)
            a.push({ ax: x.ax, ay: x.ay, hex: x.hex, size: x.size })
        }
        return { seed: seed, waveAmp: waveAmp, waveLen: waveLen, swirl: swirl,
                 blurV: blurV, grain: grain, angle: angle, streak: streak,
                 chrome: chrome, aberration: aberration, postBlur: postBlur,
                 pmPositions: pmPositions, pmWaveX: pmWaveX, pmWaveXShift: pmWaveXShift,
                 pmWaveY: pmWaveY, pmWaveYShift: pmWaveYShift, pmMixing: pmMixing,
                 pmGrainMix: pmGrainMix, pmGrainOverlay: pmGrainOverlay,
                 wProportion: wProportion, wSoftness: wSoftness, wShape: wShape,
                 wShapeScale: wShapeScale, wDistortion: wDistortion, wSwirl: wSwirl,
                 wSwirlIter: wSwirlIter, wScale: wScale, anchors: a }
    }
    function applyCtx(c) {
        seed = c.seed; waveAmp = c.waveAmp; waveLen = c.waveLen; swirl = c.swirl
        blurV = c.blurV; grain = c.grain; angle = c.angle; streak = c.streak
        if (c.chrome !== undefined) chrome = c.chrome
        if (c.aberration !== undefined) aberration = c.aberration
        postBlur = c.postBlur !== undefined ? c.postBlur : 0
        pmPositions = c.pmPositions !== undefined ? c.pmPositions : 23
        pmWaveX = c.pmWaveX !== undefined ? c.pmWaveX : 0.53
        pmWaveXShift = c.pmWaveXShift !== undefined ? c.pmWaveXShift : 0.0
        pmWaveY = c.pmWaveY !== undefined ? c.pmWaveY : 0.95
        pmWaveYShift = c.pmWaveYShift !== undefined ? c.pmWaveYShift : 0.64
        pmMixing = c.pmMixing !== undefined ? c.pmMixing : 0.5
        pmGrainMix = c.pmGrainMix !== undefined ? c.pmGrainMix : 0.0
        pmGrainOverlay = c.pmGrainOverlay !== undefined ? c.pmGrainOverlay : 0.24
        wProportion = c.wProportion !== undefined ? c.wProportion : 0.5
        wSoftness = c.wSoftness !== undefined ? c.wSoftness : 1.0
        wShape = c.wShape !== undefined ? c.wShape : 0
        wShapeScale = c.wShapeScale !== undefined ? c.wShapeScale : 0.5
        wDistortion = c.wDistortion !== undefined ? c.wDistortion : 0.25
        wSwirl = c.wSwirl !== undefined ? c.wSwirl : 0.8
        wSwirlIter = c.wSwirlIter !== undefined ? c.wSwirlIter : 10
        wScale = c.wScale !== undefined ? c.wScale : 1.0
        anchorsModel.clear()
        for (const x of c.anchors) anchorsModel.append(x)
        selected = 0
        anchorsRev++
    }
    function defaultKnobs() {
        waveAmp = 50; waveLen = 1600; swirl = 30; blurV = 80; grain = 0.12
        angle = 25; streak = 220; chrome = 0.5; aberration = 6; postBlur = 0
        pmPositions = 23; pmWaveX = 0.53; pmWaveXShift = 0.0; pmWaveY = 0.95
        pmWaveYShift = 0.64; pmMixing = 0.5; pmGrainMix = 0.0; pmGrainOverlay = 0.24
        wProportion = 0.45; wSoftness = 1.0; wShape = 0; wShapeScale = 0.1
        wDistortion = 0.25; wSwirl = 0.8; wSwirlIter = 10; wScale = 1.0
    }
    function loadPost(p) {
        gGrain = p && p.grain !== undefined ? p.grain : 0
        gBlur = p && p.blur !== undefined ? p.blur : 0
        glSize = p && p.glSize !== undefined ? p.glSize : 0.5
        glAngle = p && p.glAngle !== undefined ? p.glAngle : 90
        glShape = p && p.glShape !== undefined ? p.glShape : 1
        glDistShape = p && p.glDistShape !== undefined ? p.glDistShape : 2
        glDistortion = p && p.glDistortion !== undefined ? p.glDistortion : 0.5
        glShadows = p && p.glShadows !== undefined ? p.glShadows : 0.5
        glHighlights = p && p.glHighlights !== undefined ? p.glHighlights : 0.5
        glBlur = p && p.glBlur !== undefined ? p.glBlur : 0.1
        dPxSize = p && p.dPxSize !== undefined ? p.dPxSize : 4
        dType = p && p.dType !== undefined ? p.dType : 3
        dLevels = p && p.dLevels !== undefined ? p.dLevels : 4
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
        saveState()   // sync the new style into layers[] FIRST...
        layersRev++   // ...then bump so glassIdx re-reads the updated array
    }
    function switchMode(m) {
        if (m === mode) return
        syncSelected()
        comps[mode] = { layers: layers, post: { grain: gGrain, blur: gBlur,
            glSize: glSize, glAngle: glAngle, glShape: glShape, glDistShape: glDistShape,
            glDistortion: glDistortion, glShadows: glShadows, glHighlights: glHighlights, glBlur: glBlur,
            dPxSize: dPxSize, dType: dType, dLevels: dLevels } }
        mode = m
        const c = comps[mode]
        if (c && c.layers && c.layers.length) {
            layers = c.layers
            loadPost(c.post)
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
    FileView {
        id: orbStateFile
        path: Quickshell.env("HOME") + "/.local/state/wallpaper-studio-orb.json"
        onLoaded: win.restoreOrbState()
    }
    function orbPreset() {
        return { source: "QsLib.AgentActivity/rail-v1", angle: orbAngle, bandX: orbBandX,
                 bandY: orbBandY, warp: orbWarp, grain: orbGrain, feather: orbFeather,
                 bright: orbBright, swirl: orbSwirl, plasma: orbPlasma,
                 action: orbAction, customGlow: String(orbCustomGlow),
                 size: orbSize, playing: orbPlaying }
    }
    function saveOrbState() {
        try { orbStateFile.setText(JSON.stringify(orbPreset())) } catch (e) {}
    }
    function restoreOrbState() {
        try {
            const o = JSON.parse(orbStateFile.text())
            if (o.source !== "QsLib.AgentActivity/rail-v1") { resetOrb(); return }
            orbAngle = o.angle; orbBandX = o.bandX; orbBandY = o.bandY; orbWarp = o.warp
            orbGrain = o.grain; orbFeather = o.feather; orbBright = o.bright
            orbSwirl = o.swirl; orbPlasma = o.plasma; orbAction = o.action || "bash"
            orbCustomGlow = o.customGlow; orbSize = o.size; orbPlaying = false
        } catch (e) {}
    }
    function resetOrb() {
        orbAngle = -0.76; orbBandX = 1.35; orbBandY = 1.2; orbWarp = 1.5
        orbGrain = 0.54; orbFeather = 0.96; orbBright = 0.55
        orbSwirl = 1.2; orbPlasma = 0.05
        orbAction = "bash"; orbCustomGlow = QsLib.AgentActivity.colorFor("bash")
        orbSize = 120; orbPlaying = false; saveOrbState()
    }
    function copyOrbBlock() {
        const p = orbPreset()
        const glow = p.action === "custom" ? '"' + p.customGlow + '"'
                                              : 'QsLib.AgentActivity.colorFor("' + p.action + '")'
        const qml = "QsLib.ThinkingOrb {\n" +
            "    width: " + p.size + "; height: " + p.size + "\n" +
            "    running: " + p.playing + "\n" +
            "    glow: " + glow + "\n" +
            "    angle: " + p.angle + "; bandX: " + p.bandX + "; bandY: " + p.bandY + "\n" +
            "    warp: " + p.warp + "; grain: " + p.grain + "; feather: " + p.feather + "\n" +
            "    bright: " + p.bright + "; swirl: " + p.swirl + "; plasma: " + p.plasma + "\n}"
        Quickshell.execDetached(["wl-copy", "--", qml])
        orbStatus = "QML property block copied ✓"
        orbStatusClear.restart()
    }
    Timer { id: orbStatusClear; interval: 2500; onTriggered: win.orbStatus = "" }
    function saveState() {
        syncSelected()
        comps[mode] = { layers: layers, post: { grain: gGrain, blur: gBlur,
            glSize: glSize, glAngle: glAngle, glShape: glShape, glDistShape: glDistShape,
            glDistortion: glDistortion, glShadows: glShadows, glHighlights: glHighlights, glBlur: glBlur,
            dPxSize: dPxSize, dType: dType, dLevels: dLevels } }
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
                loadPost(c.post)
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
        restoreOrbState()
        Qt.callLater(() => generate(false))
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
        if (style === "pmesh" || style === "warp" || style === "glass" || style === "dither") {
            // colours only — pmesh positions are procedural, warp is a
            // noise-warped ramp, glass ignores anchors (refracts below);
            // anchor xy is unused by all three
            const cols = mode === "dark"
                ? ["#013b65", "#03738c", "#a3d3ff", "#f2faef"]
                : ["#f2faef", "#a3d3ff", "#03738c", "#013b65"]
            for (let i = 0; i < 4; i++)
                anchorsModel.append({ ax: 0.5, ay: 0.5, hex: cols[i], size: 1.0 })
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

    // Drives u_time at display refresh so the shader animates live (the
    // sheets drift). elapsedTime is seconds — matches Paper's u_time scale.
    FrameAnimation {
        running: win.playing
        onTriggered: win.tNow = elapsedTime
    }

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
- flow: the same liquid, domain-warped aurora field as ThinkingOrb, expanded across the canvas. Ordered anchors form its deep-to-crest color ramp; use angle, fold scale/strength, brightness, softness, swirl, grain, island scale, and crease.
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
            pmPositions: clampN(o.pmPositions, 0, 100, 23), pmWaveX: clampN(o.pmWaveX, 0, 1, 0.53),
            pmWaveXShift: clampN(o.pmWaveXShift, 0, 1, 0.0), pmWaveY: clampN(o.pmWaveY, 0, 1, 0.95),
            pmWaveYShift: clampN(o.pmWaveYShift, 0, 1, 0.64), pmMixing: clampN(o.pmMixing, 0, 1, 0.5),
            pmGrainMix: clampN(o.pmGrainMix, 0, 1, 0.0), pmGrainOverlay: clampN(o.pmGrainOverlay, 0, 1, 0.24),
            wProportion: clampN(o.wProportion, 0, 1, 0.5), wSoftness: clampN(o.wSoftness, 0, 1, 1.0),
            wShape: clampN(o.wShape, 0, 2, 0), wShapeScale: clampN(o.wShapeScale, 0, 1, 0.5),
            wDistortion: clampN(o.wDistortion, 0, 1, 0.25), wSwirl: clampN(o.wSwirl, 0, 1, 0.8),
            wSwirlIter: clampN(o.wSwirlIter, 0, 20, 10), wScale: clampN(o.wScale, 0.1, 4, 1.0),
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
            Text { text: knobRoot.label; color: win.chromeSecondary; font.pixelSize: 12; font.family: "Geist" }
            Text { anchors.right: parent.right; text: Math.round(sl.value * 100) / 100; color: win.chromeMuted; font.pixelSize: 12; font.family: "Geist" }
        }
        Slider {
            id: sl; width: parent.width; height: 24
            onMoved: knobRoot.moved(value)
            background: Rectangle {
                y: sl.height / 2 - 2; width: sl.width; height: 4; radius: 2; color: win.chromeControl
                Rectangle { width: sl.visualPosition * parent.width; height: parent.height; radius: 2; color: win.chromeMuted }
            }
            handle: Rectangle {
                x: sl.visualPosition * (sl.width - width); y: sl.height / 2 - height / 2
                width: 14; height: 14; radius: 7; color: win.chromeText
            }
        }
        // A plain value binding is severed by the first user drag; a Binding
        // element re-asserts on context switches.
        Binding { target: sl; property: "value"; value: knobRoot.extValue }
    }
    component SectionLabel: Text {
        color: win.chromeMuted
        font.pixelSize: 11
        font.weight: 600
        font.letterSpacing: 1.2
        font.family: "Geist"
        font.capitalization: Font.AllUppercase
    }
    component Chip: Rectangle {
        property string label
        signal clicked()
        width: chipText.implicitWidth + 20; height: 26; radius: 13
        color: chipHover.hovered ? QsLib.Theme.surface3 : win.chromeControl
        scale: chipTap.pressed ? 0.96 : 1
        border.width: 1; border.color: win.chromeBorder
        Behavior on color { ColorAnimation { duration: 100 } }
        Behavior on scale { NumberAnimation { duration: 80 } }
        Text { id: chipText; anchors.centerIn: parent; text: parent.label; color: win.chromeText; font.pixelSize: 12; font.family: "Geist" }
        HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { id: chipTap; onTapped: parent.clicked() }
    }
    component Pill: Rectangle {
        property string label
        property bool active: false
        signal clicked()
        width: pillText.implicitWidth + 24
        height: 28; radius: 14
        color: active ? win.chromeText : (pillHover.hovered ? QsLib.Theme.surface3 : win.chromeControl)
        scale: pillTap.pressed ? 0.96 : 1
        Behavior on color { ColorAnimation { duration: 100 } }
        Behavior on scale { NumberAnimation { duration: 80 } }
        Text { id: pillText; anchors.centerIn: parent; text: parent.label; color: parent.active ? win.color : win.chromeSecondary; font.pixelSize: 12; font.family: "Geist" }
        HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { id: pillTap; onTapped: parent.clicked() }
    }
    component Card: Rectangle {
        default property alias content: inner.data
        width: 344
        implicitHeight: inner.implicitHeight + 28
        radius: 14
        color: win.chromeSurface
        Column { id: inner; x: 14; y: 14; width: parent.width - 28; spacing: 10 }
    }
    component OrbSample: QsLib.ThinkingOrb {
        required property real sampleSize
        width: sampleSize; height: sampleSize
        running: win.orbPlaying
        glow: win.orbAction === "custom" ? win.orbCustomGlow : QsLib.AgentActivity.colorFor(win.orbAction)
        angle: win.orbAngle; bandX: win.orbBandX; bandY: win.orbBandY
        warp: win.orbWarp; grain: win.orbGrain; feather: win.orbFeather
        bright: win.orbBright; swirl: win.orbSwirl; plasma: win.orbPlasma
        seedKey: "wallpaper-studio-orb-lab-" + sampleSize
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
        property real u_time: win.tNow
        property real pmPositions: win.pmPositions
        property real pmWaveX: win.pmWaveX
        property real pmWaveXShift: win.pmWaveXShift
        property real pmWaveY: win.pmWaveY
        property real pmWaveYShift: win.pmWaveYShift
        property real pmMixing: win.pmMixing
        property real pmGrainMix: win.pmGrainMix
        property real pmGrainOverlay: win.pmGrainOverlay
        property real wProportion: win.wProportion
        property real wSoftness: win.wSoftness
        property real wShape: win.wShape
        property real wShapeScale: win.wShapeScale
        property real wDistortion: win.wDistortion
        property real wSwirl: win.wSwirl
        property real wSwirlIter: win.wSwirlIter
        property real wScale: win.wScale
    }

    Row {
        id: viewTabs
        z: 10
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 10
        spacing: 8
        Pill { label: "WALLPAPER"; active: win.studioView === "wallpaper"; onClicked: win.studioView = "wallpaper" }
        Pill { label: "ORB LAB"; active: win.studioView === "orb"; onClicked: win.studioView = "orb" }
    }

    Row {
        id: mainRow
        visible: win.studioView === "wallpaper"
        anchors.fill: parent
        anchors.topMargin: 48
        focus: visible

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
            else if (k === Qt.Key_Space) win.playing = !win.playing
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
            color: win.chromeStage

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
                property real glassIdx: { win.layersRev; let gi = -1; for (let i = 0; i < win.layers.length; i++) if (win.layers[i].style === "glass") gi = i; return gi }
                property real glSize: win.glSize
                property real glAngle: win.glAngle
                property real glShape: win.glShape
                property real glDistShape: win.glDistShape
                property real glDistortion: win.glDistortion
                property real glShadows: win.glShadows
                property real glHighlights: win.glHighlights
                property real glBlur: win.glBlur
                property real ditherIdx: { win.layersRev; let di = -1; for (let i = 0; i < win.layers.length; i++) if (win.layers[i].style === "dither") di = i; return di }
                property real dPxSize: win.dPxSize
                property real dType: win.dType
                property real dLevels: win.dLevels
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
                    border.color: isSel ? QsLib.Theme.orange : win.chromeText

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
                        width: 316; height: 32; radius: 16; color: win.chromeControl
                        TextInput {
                            id: promptField
                            anchors.fill: parent
                            anchors.leftMargin: 12; anchors.rightMargin: 12
                            verticalAlignment: TextInput.AlignVCenter
                            color: win.chromeText; font.pixelSize: 12; font.family: "Geist"
                            clip: true
                            onAccepted: win.generate(false)
                        }
                        Text {
                            visible: promptField.text === "" && !promptField.activeFocus
                            anchors.verticalCenter: parent.verticalCenter; x: 12
                            text: "describe a vibe — or just hit generate"
                            color: win.chromeMuted; font.pixelSize: 12; font.family: "Geist"
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
                    Knob { visible: ["streaks", "flow", "folds"].includes(win.style); label: win.style === "folds" ? "ribbon" : win.style === "flow" ? "brightness" : "chrome"; from: 0; to: 1; step: 0.02; extValue: win.chrome; onMoved: v => { win.chrome = v; win.saveState() } }
                    Knob { visible: win.style === "streaks" || win.style === "flow"; label: win.style === "flow" ? "crease" : "chromatic shift"; from: 0; to: 20; step: 1; extValue: win.aberration; onMoved: v => { win.aberration = v; win.saveState() } }
                    Knob { visible: win.style === "streaks" || win.style === "flow"; label: win.style === "flow" ? "island scale" : "streak length"; from: 40; to: 400; step: 5; extValue: win.streak; onMoved: v => { win.streak = v; win.saveState() } }
                    Knob { visible: !["mesh", "radial", "balls", "blocks", "pmesh", "warp", "glass", "dither"].includes(win.style); label: win.style === "folds" ? "rotation" : "angle"; from: -60; to: 60; step: 1; extValue: win.angle; onMoved: v => { win.angle = v; win.saveState() } }
                    Knob { visible: !["folds", "pmesh", "warp", "glass", "dither"].includes(win.style); label: win.style === "flow" ? "fold strength" : "wave amplitude"; from: 0; to: 160; step: 1; extValue: win.waveAmp; onMoved: v => { win.waveAmp = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "saturation"; from: 0; to: 2; step: 0.05; extValue: win.waveAmp; onMoved: v => { win.waveAmp = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "ribbon width"; from: 0.1; to: 2; step: 0.05; extValue: win.streak; onMoved: v => { win.streak = v; win.saveState() } }
                    Knob { visible: !["folds", "pmesh", "warp", "glass", "dither"].includes(win.style); label: ["stripes", "rings"].includes(win.style) ? "period" : win.style === "blocks" ? "block size" : win.style === "flow" ? "fold scale" : "wave length"; from: 300; to: 3000; step: 10; extValue: win.waveLen; onMoved: v => { win.waveLen = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "zoom"; from: 1; to: 24; step: 1; extValue: win.waveLen; onMoved: v => { win.waveLen = v; win.saveState() } }
                    Knob { visible: !["folds", "pmesh", "warp", "glass", "dither"].includes(win.style); label: "swirl"; from: -180; to: 180; step: 1; extValue: win.swirl; onMoved: v => { win.swirl = v; win.saveState() } }
                    Knob { visible: !["streaks", "folds", "pmesh", "warp", "glass", "dither"].includes(win.style); label: "softness"; from: 10; to: 220; step: 1; extValue: win.blurV; onMoved: v => { win.blurV = v; win.saveState() } }
                    Knob { visible: win.style === "folds"; label: "softness"; from: 0; to: 2; step: 0.05; extValue: win.blurV; onMoved: v => { win.blurV = v; win.saveState() } }
                    Knob { visible: !["streaks", "flow", "folds", "pmesh", "warp", "glass", "dither"].includes(win.style); label: "soft blur"; from: 0; to: 200; step: 2; extValue: win.postBlur; onMoved: v => { win.postBlur = v; win.saveState() } }
                    Knob { visible: !["folds", "pmesh", "warp", "glass", "dither"].includes(win.style); label: "grain"; from: 0; to: 0.5; step: 0.01; extValue: win.grain; onMoved: v => { win.grain = v; win.saveState() } }
                    // Paper static-mesh-gradient controls — mirror its panel 1:1
                    Knob { visible: win.style === "pmesh"; label: "positions"; from: 0; to: 100; step: 1; extValue: win.pmPositions; onMoved: v => { win.pmPositions = v; win.saveState() } }
                    Knob { visible: win.style === "pmesh"; label: "wave X"; from: 0; to: 1; step: 0.01; extValue: win.pmWaveX; onMoved: v => { win.pmWaveX = v; win.saveState() } }
                    Knob { visible: win.style === "pmesh"; label: "wave X shift"; from: 0; to: 1; step: 0.01; extValue: win.pmWaveXShift; onMoved: v => { win.pmWaveXShift = v; win.saveState() } }
                    Knob { visible: win.style === "pmesh"; label: "wave Y"; from: 0; to: 1; step: 0.01; extValue: win.pmWaveY; onMoved: v => { win.pmWaveY = v; win.saveState() } }
                    Knob { visible: win.style === "pmesh"; label: "wave Y shift"; from: 0; to: 1; step: 0.01; extValue: win.pmWaveYShift; onMoved: v => { win.pmWaveYShift = v; win.saveState() } }
                    Knob { visible: win.style === "pmesh"; label: "mixing"; from: 0; to: 1; step: 0.01; extValue: win.pmMixing; onMoved: v => { win.pmMixing = v; win.saveState() } }
                    Knob { visible: win.style === "pmesh"; label: "grain mixer"; from: 0; to: 1; step: 0.01; extValue: win.pmGrainMix; onMoved: v => { win.pmGrainMix = v; win.saveState() } }
                    Knob { visible: win.style === "pmesh"; label: "grain overlay"; from: 0; to: 1; step: 0.01; extValue: win.pmGrainOverlay; onMoved: v => { win.pmGrainOverlay = v; win.saveState() } }
                    // Paper warp controls
                    Knob { visible: win.style === "warp"; label: "shape (0 chk·1 str·2 edge)"; from: 0; to: 2; step: 1; extValue: win.wShape; onMoved: v => { win.wShape = v; win.saveState() } }
                    Knob { visible: win.style === "warp"; label: "shape scale"; from: 0; to: 1; step: 0.01; extValue: win.wShapeScale; onMoved: v => { win.wShapeScale = v; win.saveState() } }
                    Knob { visible: win.style === "warp"; label: "proportion"; from: 0; to: 1; step: 0.01; extValue: win.wProportion; onMoved: v => { win.wProportion = v; win.saveState() } }
                    Knob { visible: win.style === "warp"; label: "softness"; from: 0; to: 1; step: 0.01; extValue: win.wSoftness; onMoved: v => { win.wSoftness = v; win.saveState() } }
                    Knob { visible: win.style === "warp"; label: "distortion"; from: 0; to: 1; step: 0.01; extValue: win.wDistortion; onMoved: v => { win.wDistortion = v; win.saveState() } }
                    Knob { visible: win.style === "warp"; label: "swirl"; from: 0; to: 1; step: 0.01; extValue: win.wSwirl; onMoved: v => { win.wSwirl = v; win.saveState() } }
                    Knob { visible: win.style === "warp"; label: "swirl iterations"; from: 0; to: 20; step: 1; extValue: win.wSwirlIter; onMoved: v => { win.wSwirlIter = v; win.saveState() } }
                    Knob { visible: win.style === "warp"; label: "scale (zoom)"; from: 0.1; to: 4; step: 0.05; extValue: win.wScale; onMoved: v => { win.wScale = v; win.saveState() } }
                    // Fluted-glass layer controls — refracts the layers beneath it
                    Knob { visible: win.style === "glass"; label: "flute density"; from: 0; to: 1; step: 0.01; extValue: win.glSize; onMoved: v => { win.glSize = v; win.saveState() } }
                    Knob { visible: win.style === "glass"; label: "angle"; from: 0; to: 180; step: 1; extValue: win.glAngle; onMoved: v => { win.glAngle = v; win.saveState() } }
                    Knob { visible: win.style === "glass"; label: "grid (1ln·2irr·3wv·4zz·5pat)"; from: 1; to: 5; step: 1; extValue: win.glShape; onMoved: v => { win.glShape = v; win.saveState() } }
                    Knob { visible: win.style === "glass"; label: "distort (1prsm·2lens·3ctr·4csc·5flat)"; from: 1; to: 5; step: 1; extValue: win.glDistShape; onMoved: v => { win.glDistShape = v; win.saveState() } }
                    Knob { visible: win.style === "glass"; label: "distortion"; from: 0; to: 1; step: 0.01; extValue: win.glDistortion; onMoved: v => { win.glDistortion = v; win.saveState() } }
                    Knob { visible: win.style === "glass"; label: "shadows"; from: 0; to: 1; step: 0.01; extValue: win.glShadows; onMoved: v => { win.glShadows = v; win.saveState() } }
                    Knob { visible: win.style === "glass"; label: "highlights"; from: 0; to: 1; step: 0.01; extValue: win.glHighlights; onMoved: v => { win.glHighlights = v; win.saveState() } }
                    Knob { visible: win.style === "glass"; label: "blur"; from: 0; to: 1; step: 0.01; extValue: win.glBlur; onMoved: v => { win.glBlur = v; win.saveState() } }
                    // Dither layer controls — ordered-dithers the layers beneath it
                    Knob { visible: win.style === "dither"; label: "pixel size"; from: 1; to: 16; step: 1; extValue: win.dPxSize; onMoved: v => { win.dPxSize = v; win.saveState() } }
                    Knob { visible: win.style === "dither"; label: "type (1rnd·2b2·3b4·4b8)"; from: 1; to: 4; step: 1; extValue: win.dType; onMoved: v => { win.dType = v; win.saveState() } }
                    Knob { visible: win.style === "dither"; label: "levels (per channel)"; from: 2; to: 8; step: 1; extValue: win.dLevels; onMoved: v => { win.dLevels = v; win.saveState() } }
                }

                Card {
                    SectionLabel { text: "Selected anchor — " + (win.selected + 1) + " of " + anchorsModel.count }
                    Text { text: "drag to move, scroll to resize, double-click canvas to add (max 8)"
                           width: 316; wrapMode: Text.WordWrap; color: win.chromeMuted; font.pixelSize: 11; font.family: "Geist" }

                    Flow {
                        width: 316; spacing: 6
                        Repeater {
                            model: win.palette
                            Rectangle {
                                required property string modelData
                                width: 30; height: 30; radius: 8
                                color: modelData
                                scale: paletteTap.pressed ? 0.9 : (paletteHover.hovered ? 1.08 : 1)
                                border.width: anchorsModel.count > win.selected && anchorsModel.get(win.selected).hex === modelData ? 3 : 1
                                border.color: border.width === 3 ? QsLib.Theme.orange : win.chromeBorder
                                Behavior on scale { NumberAnimation { duration: 80 } }
                                HoverHandler { id: paletteHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { id: paletteTap; onTapped: {
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
                        width: 168; height: 34; radius: 17
                        color: saveHover.hovered ? win.chromeSecondary : win.chromeText
                        scale: saveTap.pressed ? 0.97 : 1
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Behavior on scale { NumberAnimation { duration: 80 } }
                        Text { anchors.centerIn: parent; text: "Save 4K"; color: win.color; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                        HoverHandler { id: saveHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { id: saveTap; onTapped: win.save4k(false) }
                    }
                    Rectangle {
                        width: 168; height: 34; radius: 17
                        color: setHover.hovered ? QsLib.Theme.surface3 : win.chromeControl
                        scale: setTap.pressed ? 0.97 : 1
                        border.width: 1; border.color: win.chromeBorder
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Behavior on scale { NumberAnimation { duration: 80 } }
                        Text { anchors.centerIn: parent; text: "Save + Set"; color: win.chromeText; font.pixelSize: 12; font.weight: 600; font.family: "Geist" }
                        HoverHandler { id: setHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { id: setTap; onTapped: win.save4k(true) }
                    }
                }
                Text { text: win.status; color: QsLib.Theme.green; font.pixelSize: 12; font.family: "Geist" }
                Item { width: 1; height: 12 }
            }
        }
    }

    Row {
        visible: win.studioView === "orb"
        anchors.fill: parent
        anchors.topMargin: 48

        Rectangle {
            width: parent.width - orbPanelScroll.width; height: parent.height
            color: win.chromeStage
            Column {
                anchors.centerIn: parent
                spacing: 18
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "CANONICAL THINKING ORB"; color: win.chromeMuted; font.pixelSize: 12; font.letterSpacing: 1.4; font.family: "Geist" }
                Repeater {
                    model: [{ label: "DARK GROUND", ground: "#171717", ink: "#EDEDED" },
                            { label: "LIGHT GROUND", ground: "#FFFFFF", ink: "#10100E" }]
                    Rectangle {
                        required property var modelData
                        width: 620; height: Math.max(190, win.orbSize + 54); radius: 20
                        color: modelData.ground
                        border.width: 1; border.color: win.chromeBorder
                        Text { x: 18; y: 14; text: parent.modelData.label; color: parent.modelData.ink; opacity: 0.55; font.pixelSize: 10; font.letterSpacing: 1.2; font.family: "Geist" }
                        Row {
                            anchors.centerIn: parent
                            spacing: 50
                            OrbSample { sampleSize: win.orbSize }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 18
                                OrbSample { sampleSize: 44 }
                                OrbSample { sampleSize: 26 }
                            }
                        }
                    }
                }
            }
        }

        Flickable {
            id: orbPanelScroll
            width: 380; height: parent.height
            contentHeight: orbPanel.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: orbPanel
                width: 380; padding: 18; spacing: 12
                Card {
                    SectionLabel { text: "Orb lab preset" }
                    Knob { label: "size"; from: 48; to: 160; step: 2; extValue: win.orbSize; onMoved: v => { win.orbSize = v; win.saveOrbState() } }
                    Row {
                        spacing: 8
                        Chip { label: win.orbPlaying ? "pause" : "play"; onClicked: { win.orbPlaying = !win.orbPlaying; win.saveOrbState() } }
                        Chip { label: "reset shipped"; onClicked: win.resetOrb() }
                        Chip { label: "copy QML"; onClicked: win.copyOrbBlock() }
                    }
                    Text { text: win.orbStatus; color: QsLib.Theme.green; font.pixelSize: 11; font.family: "Geist" }
                }
                Card {
                    SectionLabel { text: "Field" }
                    Knob { label: "angle"; from: -3.14; to: 3.14; step: 0.01; extValue: win.orbAngle; onMoved: v => { win.orbAngle = v; win.saveOrbState() } }
                    Knob { label: "band X"; from: 0.2; to: 4; step: 0.05; extValue: win.orbBandX; onMoved: v => { win.orbBandX = v; win.saveOrbState() } }
                    Knob { label: "band Y"; from: 0.2; to: 4; step: 0.05; extValue: win.orbBandY; onMoved: v => { win.orbBandY = v; win.saveOrbState() } }
                    Knob { label: "warp"; from: 0; to: 4; step: 0.05; extValue: win.orbWarp; onMoved: v => { win.orbWarp = v; win.saveOrbState() } }
                    Knob { label: "grain"; from: 0; to: 2; step: 0.02; extValue: win.orbGrain; onMoved: v => { win.orbGrain = v; win.saveOrbState() } }
                    Knob { label: "feather"; from: 0.1; to: 1.2; step: 0.01; extValue: win.orbFeather; onMoved: v => { win.orbFeather = v; win.saveOrbState() } }
                    Knob { label: "bright"; from: 0; to: 1; step: 0.01; extValue: win.orbBright; onMoved: v => { win.orbBright = v; win.saveOrbState() } }
                    Knob { label: "swirl"; from: 0; to: 3; step: 0.05; extValue: win.orbSwirl; onMoved: v => { win.orbSwirl = v; win.saveOrbState() } }
                    Knob { label: "plasma"; from: 0; to: 1; step: 0.01; extValue: win.orbPlasma; onMoved: v => { win.orbPlasma = v; win.saveOrbState() } }
                }
                Card {
                    SectionLabel { text: "Cockpit session action" }
                    Flow {
                        width: 316; spacing: 6
                        Repeater {
                            model: ["read", "edit", "bash", "default"]
                            Pill {
                                required property string modelData
                                label: modelData
                                active: win.orbAction === modelData
                                onClicked: { win.orbAction = modelData; win.saveOrbState() }
                            }
                        }
                    }
                    SectionLabel { text: "Custom glow" }
                    Flow {
                        width: 316; spacing: 8
                        Repeater {
                            model: ["#FF570D", "#97B5A6", "#7DD3FC", "#5566ff", "#ff8a31", "#EDEDED"]
                            Rectangle {
                                required property string modelData
                                width: 42; height: 30; radius: 8; color: modelData
                                scale: glowTap.pressed ? 0.9 : (glowHover.hovered ? 1.08 : 1)
                                border.width: win.orbAction === "custom" && String(win.orbCustomGlow).toLowerCase() === modelData.toLowerCase() ? 3 : 1
                                border.color: border.width === 3 ? win.chromeText : win.chromeBorder
                                Behavior on scale { NumberAnimation { duration: 80 } }
                                HoverHandler { id: glowHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { id: glowTap; onTapped: { win.orbAction = "custom"; win.orbCustomGlow = parent.modelData; win.saveOrbState() } }
                            }
                        }
                    }
                }
                Item { width: 1; height: 12 }
            }
        }
    }
}
