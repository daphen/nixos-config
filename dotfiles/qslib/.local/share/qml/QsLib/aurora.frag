#version 440
// ThinkingOrb interior: domain-warped fbm "silk aurora" — a continuous flowing
// field (streaks folding into each other), not discrete shapes. Compiled with
// qsb to aurora.frag.qsb; colors + shape knobs arrive as uniforms so the QML
// hue glide works and the look is tunable live.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    // Drift arrives as four bounded phases (radians on prime-period wall
    // clocks), not linear time: t-translation grew noise coords past float32
    // precision by evening and the field degenerated into straight bands.
    float ph1;
    float ph2;
    float ph3;
    float ph4;
    vec4 colA;      // deep ground
    vec4 colB;      // mid body
    vec4 colC;      // bright crest
    float angle;    // streak direction (radians)
    float bandX;    // band scale across streaks
    float bandY;    // band scale along streaks (bigger = thinner bands)
    float warp;     // fold strength
    float gain;     // fbm octave gain (texture grain)
    float feather;  // 0 = crisp color steps, 1 = widest blends
    float bright;   // 0 = deep-dominated, 1 = crest-dominated
} ubuf;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + vec2(17.31, 9.17);
        a *= ubuf.gain;
    }
    return v;
}

void main() {
    vec2 uv = qt_TexCoord0 * 2.0 - 1.0;
    float r = length(uv);
    float mask = 1.0 - smoothstep(0.98, 1.0, r);
    float c = cos(ubuf.angle), s = sin(ubuf.angle);
    vec2 p = mat2(c, -s, s, c) * uv;
    p = vec2(p.x * ubuf.bandX, p.y * ubuf.bandY);
    // warp the warp: q displaces w displaces the final field — the folds.
    // Each layer meanders on its own circle in noise space; incommensurate
    // periods keep the composite from ever visibly repeating.
    vec2 d1 = 2.0 * vec2(cos(ubuf.ph1), sin(ubuf.ph1));
    vec2 d2 = 2.0 * vec2(cos(ubuf.ph2), sin(ubuf.ph2));
    vec2 d3 = 1.6 * vec2(cos(ubuf.ph3), sin(ubuf.ph3));
    vec2 d4 = 2.6 * vec2(cos(ubuf.ph4), sin(ubuf.ph4));
    vec2 q = vec2(fbm(p + d1),
                  fbm(p + vec2(5.2, 1.3) + d2));
    vec2 w = vec2(fbm(p + ubuf.warp * q + vec2(1.7, 9.2) + d3),
                  fbm(p + ubuf.warp * q + vec2(8.3, 2.8) + vec2(d3.y, -d1.x)));
    float v = fbm(p + ubuf.warp * 0.85 * w + d4);
    float sv = smoothstep(0.05, 1.0, v);
    sv = pow(sv, mix(1.7, 0.6, ubuf.bright));
    float abHi = mix(0.35, 0.95, ubuf.feather);
    float bcLo = mix(0.72, 0.30, ubuf.feather);
    float bcHi = mix(0.95, 1.45, ubuf.feather);
    vec3 col = mix(ubuf.colA.rgb, ubuf.colB.rgb, smoothstep(0.0, abHi, sv));
    col = mix(col, ubuf.colC.rgb, smoothstep(bcLo, bcHi, sv));
    col += ubuf.colC.rgb * 0.06 * smoothstep(0.75, 1.15, sv);
    col *= 1.0 - 0.18 * smoothstep(0.55, 1.0, r);
    fragColor = vec4(col, 1.0) * mask * ubuf.qt_Opacity;
}
