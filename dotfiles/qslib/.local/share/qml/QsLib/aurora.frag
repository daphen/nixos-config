#version 440
// ThinkingOrb interior: domain-warped fbm "silk aurora" — a continuous flowing
// field (streaks folding into each other), not discrete shapes. Compiled with
// qsb to aurora.frag.qsb; colors arrive as uniforms so the QML hue glide works.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;
    vec4 colA;   // deep ground
    vec4 colB;   // mid body
    vec4 colC;   // bright crest
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
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + vec2(17.31, 9.17);
        a *= 0.55;
    }
    return v;
}

void main() {
    vec2 uv = qt_TexCoord0 * 2.0 - 1.0;
    float r = length(uv);
    float mask = 1.0 - smoothstep(0.98, 1.0, r);
    // diagonal silk space: rotate, then stretch so the noise reads as streaks
    float c = cos(-0.9), s = sin(-0.9);
    vec2 p = mat2(c, -s, s, c) * uv;
    p = vec2(p.x * 2.2, p.y * 5.5);
    float t = ubuf.time;
    // warp the warp: q displaces r displaces the final field — the folds
    vec2 q = vec2(fbm(p + vec2(0.0, -t * 0.22)),
                  fbm(p + vec2(5.2, 1.3) - t * 0.16));
    vec2 w = vec2(fbm(p + 2.6 * q + vec2(1.7, 9.2) + t * 0.11),
                  fbm(p + 2.6 * q + vec2(8.3, 2.8) - t * 0.08));
    float v = fbm(p + 2.4 * w + vec2(0.0, -t * 0.26));
    float sv = smoothstep(0.15, 0.95, v);
    // mostly mid-tone body; the deep tone survives only in the folds, the pale
    // crest only on the thinnest ridges -- the reference is cyan-dominated
    vec3 col = mix(ubuf.colA.rgb, ubuf.colB.rgb, smoothstep(0.0, 0.62, sv));
    col = mix(col, ubuf.colC.rgb, smoothstep(0.48, 1.05, sv));
    col += ubuf.colC.rgb * 0.10 * smoothstep(0.80, 1.05, sv);
    col *= 1.0 - 0.18 * smoothstep(0.55, 1.0, r);
    fragColor = vec4(col, 1.0) * mask * ubuf.qt_Opacity;
}
