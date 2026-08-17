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
    float swirl;    // local space rotates with the flow field (liquid)
    float plasma;   // sine-interference mixed through the warp (filaments)
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
    float c = cos(ubuf.angle), sn = sin(ubuf.angle);
    vec2 u = mat2(c, -sn, sn, c) * uv;
    // liquid: the whole constellation swirls back and forth
    float ga = ubuf.swirl * 0.7 * sin(ubuf.ph1);
    float gc = cos(ga), gs = sin(ga);
    u = mat2(gc, -gs, gs, gc) * u;
    vec2 d1 = vec2(cos(ubuf.ph1), sin(ubuf.ph2));
    vec2 d2 = vec2(cos(ubuf.ph2 + 2.1), sin(ubuf.ph3 + 1.0));
    vec2 d3 = vec2(cos(ubuf.ph3 + 4.2), sin(ubuf.ph4 + 3.1));
    vec2 d4 = vec2(cos(ubuf.ph4 + 0.7), sin(ubuf.ph1 + 2.6));
    // organic edges: fbm wobbles where the lobes THINK they are
    float wf = 2.0 + 4.0 * ubuf.gain;
    vec2 wob = (vec2(fbm(u * wf + d3), fbm(u * wf + vec2(7.7, 3.3) + d4)) - 0.5) * (0.3 * ubuf.warp);
    vec2 uu = u + wob;
    // metaballs: glowing field sources that bloom and MERGE (the plasma body,
    // not marble veins) — inverse-square falloff sums where lobes approach
    float spread = 0.28 * ubuf.bandY;
    float rb = 0.30 * ubuf.bandX;
    float rb2 = rb * rb;
    float field = 0.0;
    vec2 dd;
    dd = uu - spread * d1;          field += rb2 / (dot(dd, dd) + 0.015);
    dd = uu - spread * d2;          field += rb2 / (dot(dd, dd) + 0.015);
    dd = uu - spread * d3 * 0.8;    field += rb2 / (dot(dd, dd) + 0.015);
    dd = uu - spread * d4 * 0.55;   field += rb2 / (dot(dd, dd) + 0.015);
    float v = clamp(0.55 * field - 0.35, 0.0, 1.0);
    // plasma: iso-contour rings blooming around the lobes (plasma-ball arcs)
    float pl = 0.5 + 0.5 * sin(9.0 * field - 3.0 * ubuf.ph2);
    v = mix(v, v * (0.5 + 0.6 * pl), clamp(ubuf.plasma, 0.0, 1.0));
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
