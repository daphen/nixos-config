#version 440
// GPU renderer for wallpaper-studio: mesh gradients and chroma streaks.
// One implementation for preview and save — WYSIWYG by construction.

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
    float styleMode;   // 0 mesh, 1 streaks
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
        vec3 s = glowField(ruv + vec2(t * halfLen, 0.0));
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

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 col;
    if (styleMode < 0.5) {
        col = meshField(warp(uv));
    } else {
        // chromatic fringes: shift the R/B sampling axes
        float ab = aberr / 3840.0;
        vec2 off = vec2(ab, 0.0);
        col.r = streaksAt(uv + off).r;
        col.g = streaksAt(uv).g;
        col.b = streaksAt(uv - off).b;
        col = finish(col);
    }
    // film grain
    float g = (hash12(uv * vec2(3840.0, 2400.0)) - 0.5) * grainAmt;
    col = clamp(col + g, 0.0, 1.0);
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
