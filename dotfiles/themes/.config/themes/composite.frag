#version 440
// Layer compositor for wallpaper-studio: blends up to 4 wallpaper.frag
// layers (each pre-rendered into a texture), then applies the global
// post stack — soft blur and grain — over the composed result.
// compile: qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o composite.frag.qsb composite.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 opac;      // per-layer opacity
    vec4 modev;     // per-layer blend: 0 normal, 1 screen, 2 multiply, 3 overlay
    float count;    // active layer count 1..4
    float gGrain;   // global grain over the composite
    float gBlur;    // global soft blur, px at 3840
    float seedF;
};
layout(binding = 1) uniform sampler2D s0;
layout(binding = 2) uniform sampler2D s1;
layout(binding = 3) uniform sampler2D s2;
layout(binding = 4) uniform sampler2D s3;

const float ASPECT = 1.6;

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031 + seedF * 0.017);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 blendOne(vec3 dst, vec3 src, float m, float o) {
    vec3 b = src;
    if (m > 2.5) {
        vec3 lo = 2.0 * dst * src;
        vec3 hi = 1.0 - 2.0 * (1.0 - dst) * (1.0 - src);
        b = mix(hi, lo, step(dst, vec3(0.5)));
    } else if (m > 1.5) {
        b = dst * src;
    } else if (m > 0.5) {
        b = 1.0 - (1.0 - dst) * (1.0 - src);
    }
    return mix(dst, b, o);
}

vec3 scene(vec2 uv) {
    vec3 c = texture(s0, uv).rgb;
    int n = int(count + 0.5);
    if (n > 1) c = blendOne(c, texture(s1, uv).rgb, modev.y, opac.y);
    if (n > 2) c = blendOne(c, texture(s2, uv).rgb, modev.z, opac.z);
    if (n > 3) c = blendOne(c, texture(s3, uv).rgb, modev.w, opac.w);
    return c;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 col;
    if (gBlur < 0.5) {
        col = scene(uv);
    } else {
        float r = gBlur / 2200.0;
        vec2 D[12] = vec2[](
            vec2(-0.326, -0.406), vec2(-0.840, -0.074), vec2(-0.696, 0.457),
            vec2(-0.203, 0.621),  vec2(0.962, -0.195),  vec2(0.473, -0.480),
            vec2(0.519, 0.767),   vec2(0.185, -0.893),  vec2(0.507, 0.064),
            vec2(0.896, 0.412),   vec2(-0.322, -0.933), vec2(-0.792, -0.598));
        col = scene(uv);
        for (int k = 0; k < 12; k++)
            col += scene(uv + vec2(D[k].x / ASPECT, D[k].y) * r);
        col /= 13.0;
    }
    col = clamp(col + (hash12(uv * vec2(3840.0, 2400.0)) - 0.5) * gGrain, 0.0, 1.0);
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
