#version 440
// GPU renderer for wallpaper-studio: mesh gradients and chroma streaks.
// One implementation for preview and save — WYSIWYG by construction.
// compile: qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o wallpaper.frag.qsb wallpaper.frag
// (qsb lives in the qtshadertools nix package)
// A running quickshell instance caches compiled shaders per-URL — after a
// recompile the studio PROCESS must be restarted; QML hot-reload won't do it.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    // anchors: xy = pos (uv), z = size, w = active flag
    vec4 a0; vec4 a1; vec4 a2; vec4 a3; vec4 a4; vec4 a5; vec4 a6; vec4 a7;
    // colors (rgb)
    vec4 c0; vec4 c1; vec4 c2; vec4 c3; vec4 c4; vec4 c5; vec4 c6; vec4 c7;
    vec4 baseColor;
    float styleMode;   // 0 mesh, 1 streaks, 2 flow (smeared mesh), 3 bands
    float modeLight;   // 0 dark, 1 light
    float waveAmp;     // calibrated at 3840px width
    float waveLen;
    float swirlDeg;
    float blurK;       // mesh softness
    float grainAmt;
    float angleDeg;
    float streakLen;   // 40..400
    float aberr;       // chromatic offset, px at 3840
    float seedF;       // noise seed
    float chromeAmt;   // brushed-filament strength 0..1
    float postBlur;    // soft blur over the composed scene (mesh/bands), px at 3840
    float u_time;      // seconds; animates the folds/flow fields (0 = frozen)
    // Paper static-mesh-gradient controls (style 11) — own uniforms, no reuse
    float pmPositions; float pmWaveX; float pmWaveXShift; float pmWaveY;
    float pmWaveYShift; float pmMixing; float pmGrainMix; float pmGrainOverlay;
    // Paper warp controls (style 12)
    float wProportion; float wSoftness; float wShape; float wShapeScale;
    float wDistortion; float wSwirl; float wSwirlIter; float wScale;
};

const float ASPECT = 1.6;   // 16:10 canvas

float hash12(vec2 p) {
    // Hoskins hash — stable at coordinates in the thousands (a cheaper
    // fract-mul hash lost precision and the grain degenerated into
    // horizontal weave).
    vec3 p3 = fract(vec3(p.xyx) * 0.1031 + seedF * 0.017);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + vec2(1, 0));
    float c = hash12(i + vec2(0, 1)), d = hash12(i + vec2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
    float a = 0.5, f = 0.0;
    for (int i = 0; i < 5; i++) { f += a * vnoise(p); p = p * 2.03 + 17.7; a *= 0.5; }
    return f;
}

vec2 rotAbout(vec2 uv, float deg) {
    vec2 c = uv - 0.5;
    c.x *= ASPECT;
    float th = radians(deg), cs = cos(th), sn = sin(th);
    c = vec2(c.x * cs - c.y * sn, c.x * sn + c.y * cs);
    c.x /= ASPECT;
    return c + 0.5;
}

void getAnchor(int i, out vec4 A, out vec3 C) {
    if      (i == 0) { A = a0; C = c0.rgb; }
    else if (i == 1) { A = a1; C = c1.rgb; }
    else if (i == 2) { A = a2; C = c2.rgb; }
    else if (i == 3) { A = a3; C = c3.rgb; }
    else if (i == 4) { A = a4; C = c4.rgb; }
    else if (i == 5) { A = a5; C = c5.rgb; }
    else if (i == 6) { A = a6; C = c6.rgb; }
    else             { A = a7; C = c7.rgb; }
}

// distance² in aspect-corrected space
float d2(vec2 uv, vec2 p) {
    vec2 d = uv - p;
    d.x *= ASPECT;
    return dot(d, d);
}

vec3 meshField(vec2 uv) {
    float soft = mix(0.008, 0.09, clamp(blurK / 220.0, 0.0, 1.0));
    vec3 num = vec3(0.0);
    float den = 0.0;
    for (int i = 0; i < 8; i++) {
        vec4 A; vec3 C; getAnchor(i, A, C);
        if (A.w < 0.5) continue;
        float w = (A.z * A.z) / (d2(uv, A.xy) + soft);
        num += C * w;
        den += w;
    }
    return den > 0.0 ? num / den : baseColor.rgb;
}

// hot cores on the stage; chrome noise breaks them into filaments (dark)
vec3 glowField(vec2 uv) {
    vec3 acc = baseColor.rgb;
    for (int i = 0; i < 8; i++) {
        vec4 A; vec3 C; getAnchor(i, A, C);
        if (A.w < 0.5) continue;
        float g = exp(-d2(uv, A.xy) / (0.014 * A.z * A.z + 1e-6));
        acc += (C - baseColor.rgb) * g;
    }
    if (chromeAmt > 0.001) {
        // fine vertical frequency -> the directional smear draws it into
        // thin threads; modulate only the LIGHT (delta), never the stage,
        // so white paper stays white.
        float n = vnoise(uv * vec2(45.0 * ASPECT, 240.0));
        n = mix(1.0, 0.25 + 1.5 * n, chromeAmt);
        acc = baseColor.rgb + (acc - baseColor.rgb) * n;
    }
    return acc;
}

// 1-D mesh over a scalar coordinate: anchors are color STOPS (ay = stop
// position, ax ignored); IDW interpolates between stops without sorting.
// bands feeds it uv.y; stripes/conic/radial/rings/folds feed it their own t.
vec3 stopsField(float t) {
    float soft = mix(0.002, 0.05, clamp(blurK / 220.0, 0.0, 1.0));
    vec3 num = vec3(0.0);
    float den = 0.0;
    for (int i = 0; i < 8; i++) {
        vec4 A; vec3 C; getAnchor(i, A, C);
        if (A.w < 0.5) continue;
        float dt = t - A.y;
        float w = (A.z * A.z) / (dt * dt + soft);
        num += C * w;
        den += w;
    }
    return den > 0.0 ? num / den : baseColor.rgb;
}

// mirror a repeating coordinate so stop cycles reverse instead of seam-snapping
float pingpong(float t) { return 1.0 - abs(1.0 - 2.0 * fract(t)); }

vec3 stripesField(vec2 uv) {
    float period = max(waveLen, 60.0) / 3840.0;
    return stopsField(pingpong(uv.x / period));
}

vec3 conicField(vec2 uv) {
    vec2 c = uv - 0.5;
    c.x *= ASPECT;
    float t = atan(c.y, c.x) / 6.28318530718 + 0.5;
    return stopsField(pingpong(t));
}

vec3 radialField(vec2 uv) {
    vec2 c = uv - 0.5;
    c.x *= ASPECT;
    // 0.943 = center-to-corner distance in aspect space; t=1 lands on corners
    return stopsField(clamp(length(c) / 0.943, 0.0, 1.0));
}

vec3 ringsField(vec2 uv) {
    vec2 c = uv - 0.5;
    c.x *= ASPECT;
    float period = max(waveLen, 60.0) / 3840.0;
    return stopsField(pingpong(length(c) / period));
}

// anchors as soft solid discs painted in order over the base
vec3 ballsField(vec2 uv) {
    vec3 col = baseColor.rgb;
    float soft = mix(0.002, 0.12, clamp(blurK / 220.0, 0.0, 1.0));
    for (int i = 0; i < 8; i++) {
        vec4 A; vec3 C; getAnchor(i, A, C);
        if (A.w < 0.5) continue;
        float r = 0.16 * A.z;
        float d = sqrt(d2(uv, A.xy));
        col = mix(col, C, 1.0 - smoothstep(r - soft, r + soft, d));
    }
    return col;
}

// pixel-mosaic of the mesh field: sample it at square cell centers only
vec3 blocksField(vec2 uv) {
    float nx = 3840.0 / max(waveLen, 120.0);
    vec2 g = vec2(nx, nx / ASPECT);
    return meshField((floor(uv * g) + 0.5) / g);
}

// draped light sheets: triple domain-warped fbm mapped through the color
// stops, shaded by the field's slope (after mattrothenberg/fold-gradient).
// ── FoldGradient port (mattrothenberg/fold-gradient, MIT) ──────────────
// Faithful port of the real shader: SQUARED value-noise (crisp peaks),
// triple domain-warped fbm, screen-space derivative NORMAL lighting with a
// sharp specular crest (the "crystal" ray-edges the eyeballed version could
// never get), ribbon banding, ACES tonemap. Own noise fns so the other
// styles stay untouched. Knobs map onto the studio's existing uniforms.
mat2 rot2(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }
float fg_hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031 + seedF * 0.017);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float fg_vnoise(vec2 p) {
    vec2 ip = floor(p), u = fract(p); u = u * u * (3.0 - 2.0 * u);
    float r = mix(mix(fg_hash12(ip),          fg_hash12(ip + vec2(1, 0)), u.x),
                  mix(fg_hash12(ip + vec2(0, 1)), fg_hash12(ip + vec2(1, 1)), u.x), u.y);
    return r * r;   // squared → sharp peaks, the "crystal" grain
}
const mat2 FG_M2 = mat2(0.8, -0.6, 0.6, 0.8);
float fg_fbm(vec2 p) {
    float f = 0.0;
    f += 0.5000 * fg_vnoise(p); p = FG_M2 * p * 2.02;
    f += 0.2500 * fg_vnoise(p); p = FG_M2 * p * 2.03;
    f += 0.1250 * fg_vnoise(p);
    return f / 0.875;
}
float fg_pat(vec2 p, out float hue) {
    vec2 q = vec2(fg_fbm(p), fg_fbm(p + vec2(5.2, 1.3)));
    vec2 r = vec2(fg_fbm(p + 4.0 * q + vec2(1.7, 9.2)), fg_fbm(p + 4.0 * q + vec2(8.3, 2.8)));
    hue = clamp(r.x * 0.95 + 0.03, 0.0, 1.0);   // hue from bounded r (no drift)
    r += u_time * 0.045;                        // time animates sheet motion only
    return fg_fbm(p + 1.76 * r);
}
// active anchors (c0..c7) as an ordered color ramp
vec3 fg_palette(float x) {
    int n = 0;
    for (int i = 0; i < 8; i++) { vec4 A; vec3 C; getAnchor(i, A, C); if (A.w > 0.5) n++; }
    if (n < 2) n = 2;
    x = clamp(x, 0.0, 1.0) * float(n - 1);
    int idx = int(floor(x)); float f = fract(x);
    vec3 ca = baseColor.rgb, cb = baseColor.rgb; int seen = 0;
    for (int i = 0; i < 8; i++) {
        vec4 A; vec3 C; getAnchor(i, A, C); if (A.w < 0.5) continue;
        if (seen == idx) ca = C;
        if (seen == min(idx + 1, n - 1)) cb = C;
        seen++;
    }
    return mix(ca, cb, smoothstep(0.0, 1.0, f));
}
vec3 foldsField(vec2 uv) {
    float asp = ASPECT;
    // knob mapping → FoldGradient uniforms
    float u_softness    = clamp(blurK, 0.0, 2.0);
    float u_rotation    = angleDeg;
    float u_folds       = clamp(waveLen, 1.0, 24.0);
    float u_ribbon      = clamp(chromeAmt, 0.0, 1.0);
    float u_ribbonWidth = clamp(streakLen, 0.1, 2.0);
    float u_saturation  = clamp(waveAmp, 0.0, 2.0);
    vec3  u_back        = baseColor.rgb * 0.22;
    vec3  u_shadow      = baseColor.rgb * 0.06;

    vec2 dir = normalize(vec2(0.66, 0.75));
    vec2 perp = vec2(-dir.y, dir.x);
    float sm = 0.045 + (2.0 - u_softness) * 0.075;
    float jit = 0.0;   // no per-pixel jitter: dither reads as spray at preview res

    mat2 R = rot2(radians(u_rotation));
    float zsc = 29.16 / u_folds;
    vec2 pBase = vec2((uv.x - 0.5) * asp, uv.y - 0.5) * R * zsc;
    vec2 wDir  = vec2(dir.x * asp,  dir.y ) * R * zsc;
    vec2 wPerp = vec2(perp.x * asp, perp.y) * R * zsc;

    float bandGain = 1.0;
    if (u_ribbon > 0.001) {
        float t = dot(pBase, normalize(wPerp)) / 3.24 / (0.16 * max(u_ribbonWidth, 0.05));
        t += 0.35 * sin(t * 1.7 + 2.1);
        float band = floor(t), fb = fract(t);
        float k = smoothstep(0.0, 0.16, fb);
        float bA = band - 1.0, bB = band;
        float s = dot(pBase, normalize(wDir)) / 3.24;
        float shear = mix(fg_hash12(vec2(bA, 7.7)), fg_hash12(vec2(bB, 7.7)), k);
        pBase += normalize(wDir) * (shear - 0.5) * 4.5 * u_ribbon;
        float c = mix(fg_hash12(vec2(bA, 9.1)), fg_hash12(vec2(bB, 9.1)), k) - 0.5;
        float hl = 0.42 + 0.40 * mix(fg_hash12(vec2(bA, 11.3)), fg_hash12(vec2(bB, 11.3)), k);
        float cap = 1.0 - smoothstep(hl - 0.24, hl + 0.14, abs(s - c * 0.8));
        float e = mix(fg_hash12(vec2(bA, 3.3)), fg_hash12(vec2(bB, 3.3)), k);
        bandGain = mix(1.0, (0.62 + 1.25 * e * e) * cap * 1.3, u_ribbon);
        float fo = mix(fg_hash12(vec2(bA, 5.5)), fg_hash12(vec2(bB, 5.5)), k);
        sm *= mix(1.0, 0.70 + 1.25 * fo, u_ribbon);
    }

    vec3 L = normalize(vec3(0.55, 0.35, 0.55));
    vec3 HL = normalize(L + vec3(0.0, 0.0, 1.0));
    float lum = 0.0, hue = 0.0, wsum = 0.0, bloom = 0.0;
    float fscale = mix(1.0, 0.52, clamp(u_ribbon, 0.0, 1.0));
    for (int i = -6; i <= 6; i++) {
        float fi = (float(i) + jit) / 6.0;
        float w = exp(-fi * fi * 2.5);
        vec2 off = wDir * (fi * sm) + wPerp * (fi * sm * 0.11);
        float hh; float h = fg_pat((pBase + off) * fscale, hh);
        vec2 g = vec2(dFdx(h) / max(dFdx(uv.x), 1e-6),
                      dFdy(h) / max(dFdy(uv.y), 1e-6)) * 0.0016;
        vec3 N = normalize(vec3(-g, 0.5));
        float diff = clamp(dot(N, L), 0.0, 1.0);
        float crest = pow(clamp(dot(N, HL), 0.0, 1.0), 16.0);
        float ribbon = smoothstep(0.14, 0.92, h);
        float baseW = mix(0.34, 0.72, u_ribbon);
        float diffW = mix(0.90, 0.08, u_ribbon);
        float crestW = mix(0.60, 0.0, u_ribbon);
        float sheen = pow(h, 5.0) * 0.45 * u_ribbon;
        float lv = (ribbon * (baseW + diff * diffW) + crest * crestW + sheen) * smoothstep(0.02, 0.45, h);
        lum += lv * w; hue += hh * w; wsum += w;
        bloom += smoothstep(0.55, 1.0, lv) * w;
    }
    lum /= wsum; hue /= wsum; bloom /= wsum;
    lum *= bandGain;
    vec2 qc = (uv - 0.5); qc.x *= asp; lum *= 1.0 - dot(qc, qc) * 0.45;
    vec3 grad = fg_palette(hue * 0.62 + lum * 0.42);
    vec3 col = mix(u_back, u_shadow, smoothstep(0.015, 0.30, lum));
    col = mix(col, grad, smoothstep(0.22, 0.72, lum));
    col += grad * bloom * 0.55;
    // ACES filmic tonemap + gamma + saturation
    col = clamp((col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14), 0.0, 1.0);
    col = pow(col, vec3(1.0 / 2.2));
    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = clamp(mix(vec3(luma), col, u_saturation), 0.0, 1.0);
    return col;
}

// ── Paper static-mesh-gradient (paper-design/shaders, MIT) ─────────────
// Faithful port: inverse-distance colour spots (placed procedurally from a
// seed, à la Paper's getPosition), two-axis wave warp, and SMOOTH value-
// noise film grain (not white-noise) — the reason Paper's grain reads lush,
// not like sandpaper. Own pm_* uniforms so nothing collides with the other
// styles. Anchors supply the colours; positions come from the seed.
float pm_hash21(vec2 p) {
    p = fract(p * vec2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}
float pm_vnoise(vec2 st) {
    vec2 ip = floor(st), f = fract(st);
    float a = pm_hash21(ip), b = pm_hash21(ip + vec2(1, 0));
    float c = pm_hash21(ip + vec2(0, 1)), d = pm_hash21(ip + vec2(1, 1));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
vec2 pm_rotate(vec2 uv, float th) { return mat2(cos(th), sin(th), -sin(th), cos(th)) * uv; }
vec2 pm_getPos(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + mod(float(i), 3.0) * 0.3;
    float c = 0.8 + mod(float(i + 1), 4.0) * 0.25;
    return 0.5 + 0.5 * vec2(sin(t * b + a), cos(t * c + a * 1.5));
}
vec3 pmeshField(vec2 uv) {
    vec2 grainUV = uv * 1000.0;
    float mixerGrain = 0.4 * pmGrainMix * (pm_vnoise(grainUV) - 0.5);

    float center = 1.0 - smoothstep(0.0, 1.0, length(uv - 0.5));
    for (float i = 1.0; i <= 2.0; i++) {
        uv.x += pmWaveX * center / i * cos(6.28318530718 * pmWaveXShift + i * 2.0 * smoothstep(0.0, 1.0, uv.y));
        uv.y += pmWaveY * center / i * cos(6.28318530718 * pmWaveYShift + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    vec3 color = vec3(0.0);
    float totalWeight = 0.0;
    float positionSeed = 25.0 + 0.33 * pmPositions;
    float mixing = pow(pmMixing, 0.7);
    float power = mix(2.0, 1.0, mixing);
    int seen = 0;
    for (int i = 0; i < 8; i++) {
        vec4 A; vec3 C; getAnchor(i, A, C); if (A.w < 0.5) continue;
        vec2 pos = pm_getPos(seen, positionSeed) + mixerGrain;
        seen++;
        float dist = pow(length(uv - pos), power);
        float w = 1.0 / (dist + 1e-3);
        float sharpness = mix(mix(0.0, 8.0, clamp(w, 0.0, 1.0)), 1.0, mixing);
        w = pow(w, sharpness);
        color += C * w;
        totalWeight += w;
    }
    if (seen == 0) return baseColor.rgb;
    color /= max(1e-4, totalWeight);

    // smooth value-noise film grain overlay (two rotated octaves → b/w flecks)
    float go = pm_vnoise(pm_rotate(grainUV, 1.0) + vec2(3.0));
    go = mix(go, pm_vnoise(pm_rotate(grainUV, 2.0) + vec2(-1.0)), 0.5);
    go = pow(go, 1.3);
    float gv = go * 2.0 - 1.0;
    float gs = pow(pmGrainOverlay * abs(gv), 0.8);
    color = mix(color, vec3(step(0.0, gv)), 0.35 * gs);
    return color;
}

// ── Paper warp (paper-design/shaders, MIT) ─────────────────────────────
// Faithful port: noise + swirl domain-warp over a base pattern (checks /
// stripes / edge), coloured through the anchor ramp with soft stepped mix.
// Paper samples a noise texture; we use procedural value noise instead.
// Own w* uniforms; animated via u_time.
vec3 warpField(vec2 uv) {
    // base pattern frequency: too small a span → noise sees <1 cell → smooth
    // bands. ~5 units across the frame gives Paper's marbled turbulence.
    float zoom = clamp(wScale, 0.1, 4.0);
    vec2 p = vec2((uv.x - 0.5) * ASPECT, uv.y - 0.5) * (5.0 / zoom);

    float t = 0.0625 * (u_time + 118.0);
    float n1 = pm_vnoise(p * 1.0 + t);
    float n2 = pm_vnoise(p * 2.0 - t);
    float angle = n1 * 6.28318530718;
    p.x += 4.0 * wDistortion * n2 * cos(angle);
    p.y += 4.0 * wDistortion * n2 * sin(angle);

    for (int i = 1; i <= 20; i++) {
        if (i >= int(wSwirlIter)) break;
        float f = float(i);
        p.x += wSwirl / f * cos(t + f * 1.5 * p.y);
        p.y += wSwirl / f * cos(t + f * 1.0 * p.x);
    }

    float proportion = clamp(wProportion, 0.0, 1.0);
    float shape = 0.0;
    if (wShape < 0.5) {
        vec2 cu = p * (0.5 + 3.5 * wShapeScale);
        shape = 0.5 + 0.5 * sin(cu.x) * cos(cu.y);
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else if (wShape < 1.5) {
        vec2 su = p * (2.0 * wShapeScale);
        float f = fract(su.y);
        shape = smoothstep(0.0, 0.55, f) * (1.0 - smoothstep(0.45, 1.0, f));
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else {
        float ss = 5.0 * (1.0 - wShapeScale);
        float e0 = 0.45 - ss, e1 = 0.55 + ss;
        shape = smoothstep(min(e0, e1), max(e0, e1), 1.0 - p.y + 0.3 * (proportion - 0.5));
    }

    vec3 cols[8]; int n = 0;
    for (int i = 0; i < 8; i++) { vec4 A; vec3 C; getAnchor(i, A, C); if (A.w > 0.5) { cols[n] = C; n++; } }
    if (n < 1) return baseColor.rgb;
    float mixer = shape * float(n - 1);
    float aa = fwidth(shape);
    vec3 gradient = cols[0];
    for (int i = 1; i < 8; i++) {
        if (i >= n) break;
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        float localStart = floor(m);
        float softness = 0.5 * wSoftness + fwidth(m);
        float smoothed = smoothstep(max(0.0, 0.5 - softness - aa), min(1.0, 0.5 + softness + aa), m - localStart);
        float stepped = localStart + smoothed;
        m = mix(stepped, m, wSoftness);
        gradient = mix(gradient, cols[i], m);
    }
    return gradient;
}

// organic noise field for flow: gently domain-warped fbm mapped through the
// color STOPS (anchors as an ordered ramp, à la Raycast Flow's colors[]).
// streaksAt then motion-blurs this along the rotation axis → flowing aurora
// sheets. Kept to 3 fbm calls since streaksAt evaluates it once per smear tap.
vec3 flowNoise(vec2 uv) {
    // LOW frequency + few octaves = big soft shapes ("shading"); 5-octave fbm
    // here made fine striations that the directional smear drew into visible
    // brush strokes. Two smooth vnoise octaves, gently warped, keep it soft.
    float z = mix(4.2, 1.2, clamp((waveLen - 300.0) / 2700.0, 0.0, 1.0));
    vec2 p = (uv - 0.5) * z;
    p.x *= ASPECT;
    vec2 w = vec2(vnoise(p + vec2(3.1, 7.4)), vnoise(p + vec2(8.3, 2.8)));
    float f = 0.65 * vnoise(p + 1.1 * w) + 0.35 * vnoise(p * 2.0 + 3.0 * w);
    float t = clamp((f - 0.30) / 0.40, 0.0, 1.0);
    // bias toward the first (dark) stop → black dominates, brights sparse
    t = pow(t, 2.0);
    return stopsField(t);
}

vec2 warp(vec2 uv) {
    // swirl about center
    vec2 c = uv - 0.5;
    c.x *= ASPECT;
    float r = length(c);
    float th = radians(swirlDeg) * exp(-r * r * 3.0);
    float cs = cos(th), sn = sin(th);
    c = vec2(c.x * cs - c.y * sn, c.x * sn + c.y * cs);
    c.x /= ASPECT;
    uv = c + 0.5;
    // wave along x
    uv.y += (waveAmp / 2400.0) * sin(uv.x * 6.28318 * (3840.0 / max(waveLen, 60.0)));
    return uv;
}

vec3 streaksAt(vec2 uv) {
    // rotate sampling space so the smear axis is horizontal
    vec2 c = uv - 0.5;
    c.x *= ASPECT;
    float th = radians(-angleDeg);
    float cs = cos(th), sn = sin(th);
    c = vec2(c.x * cs - c.y * sn, c.x * sn + c.y * cs);
    c.x /= ASPECT;
    vec2 ruv = warp(c + 0.5);

    // Flat stroke profile: uniform weight along the line with soft ends —
    // a gaussian kept the anchor as a hot blob with comet tails. 63 taps
    // keep long strokes smooth.
    float halfLen = streakLen / 700.0;
    vec3 accL = vec3(0.0), accS = vec3(0.0);
    float wsumL = 0.0, wsumS = 0.0;
    const int N = 63;
    for (int k = 0; k < N; k++) {
        float t = (float(k) / float(N - 1) - 0.5) * 2.0;   // ±1
        float au = abs(t);
        float wL = 1.0 - smoothstep(0.82, 1.0, au);
        float wS = 1.0 - smoothstep(0.10, 0.16, au);       // short core layer
        vec2 sp = ruv + vec2(t * halfLen, 0.0);
        // flow = an organic noise field smeared directionally (Raycast Flow
        // aurora sheets); streaks = hot cores on a stage.
        vec3 s = (styleMode > 1.5) ? flowNoise(sp) : glowField(sp);
        accL += s * wL; wsumL += wL;
        accS += s * wS; wsumS += wS;
    }
    vec3 L = accL / wsumL;
    vec3 S = accS / max(wsumS, 1e-4);
    if (modeLight < 0.5) {
        // soften the core so anchors don't read as blobs
        vec3 Ssoft = baseColor.rgb + (S - baseColor.rgb) * 0.4;
        return 1.0 - (1.0 - L) * (1.0 - Ssoft);
    }
    vec3 pl = L / max(baseColor.rgb, vec3(1e-4));
    vec3 ps = S / max(baseColor.rgb, vec3(1e-4));
    ps = mix(vec3(1.0), ps, 0.4);
    return clamp(pl * ps * baseColor.rgb, 0.0, 1.0);
}

vec3 finish(vec3 c) {
    if (styleMode < 0.5) return c;   // mesh keeps its natural range
    if (styleMode > 1.5) {
        // flow: firmer S-curve + saturation lift → vivid streaks on black
        c = mix(c, c * c * (3.0 - 2.0 * c), 0.55);
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        c = clamp(l + (c - l) * 1.35, 0.0, 1.0);
        return c;
    }
    if (modeLight < 0.5) {
        c = clamp(c / 0.16, 0.0, 1.0);              // lift faint light
        c = c * c * (3.0 - 2.0 * c);                // soft sigmoid
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        c = clamp(l + (c - l) * 1.4, 0.0, 1.0);     // saturation
    } else {
        c = pow(clamp(c, 0.0, 1.0), vec3(2.0));     // deepen ink
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        c = clamp(l + (c - l) * 1.5, 0.0, 1.0);
    }
    return c;
}

// the composed scene for the cheap field styles (everything but streaks/flow)
vec3 sceneMB(vec2 uv) {
    int s = int(styleMode + 0.5);
    if (s == 3 || s == 4 || s == 5 || s == 7 || s == 10) {   // angled t-styles
        vec2 w = warp(rotAbout(uv, -angleDeg));
        if (s == 3)  return stopsField(w.y);
        if (s == 4)  return stripesField(w);
        if (s == 5)  return conicField(w);
        if (s == 7)  return ringsField(w);
        return foldsField(w);
    }
    if (s == 6) return radialField(warp(uv));
    if (s == 8) return ballsField(warp(uv));
    if (s == 9) return blocksField(warp(uv));
    if (s == 11) return pmeshField(uv);   // Paper mesh: own warp + grain
    if (s == 12) return warpField(uv);    // Paper warp: own noise/swirl warp
    if (s == 13) return vec3(0.0);        // glass: refracts below in composite
    if (s == 14) return vec3(0.0);        // dither: filters below in composite
    return meshField(warp(uv));
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 col;
    if (styleMode < 0.5 || styleMode > 2.5) {
        if (postBlur < 0.5) {
            col = sceneMB(uv);
        } else {
            // 12-tap poisson disc over the COMPOSED scene — a true soft
            // blur on top of the finished gradient, resolution-independent.
            float r = postBlur / 2200.0;
            vec2 D[12] = vec2[](
                vec2(-0.326, -0.406), vec2(-0.840, -0.074), vec2(-0.696, 0.457),
                vec2(-0.203, 0.621),  vec2(0.962, -0.195),  vec2(0.473, -0.480),
                vec2(0.519, 0.767),   vec2(0.185, -0.893),  vec2(0.507, 0.064),
                vec2(0.896, 0.412),   vec2(-0.322, -0.933), vec2(-0.792, -0.598));
            col = sceneMB(uv);
            for (int k = 0; k < 12; k++)
                col += sceneMB(uv + vec2(D[k].x / ASPECT, D[k].y) * r);
            col /= 13.0;
        }
    } else {
        // chromatic fringes: shift the R/B sampling axes
        float ab = aberr / 3840.0;
        vec2 off = vec2(ab, 0.0);
        col.r = streaksAt(uv + off).r;
        col.g = streaksAt(uv).g;
        col.b = streaksAt(uv - off).b;
        col = finish(col);
    }
    // film grain — folds (10) and pmesh (11) do their own; skip the harsh
    // white-noise pass for them (it reads as sandpaper at preview res)
    if (styleMode < 9.5) {
        float g = (hash12(uv * vec2(3840.0, 2400.0)) - 0.5) * grainAmt;
        col = clamp(col + g, 0.0, 1.0);
    }
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
