#version 440
// Layer compositor for wallpaper-studio: blends up to 4 wallpaper.frag
// layers (each pre-rendered into a texture), then applies the global post
// stack (soft blur + grain). A layer whose style is "glass" is not blended
// as a texture — instead it refracts the composite of the layers BELOW it
// through Paper's fluted-glass filter (paper-design/shaders, MIT), so you can
// drop a glass layer on top of a gradient.
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
    // fluted-glass layer
    float glassIdx;     // index of the glass layer, <0 = none
    float glSize;       // 0..1 flute density
    float glAngle;      // degrees, grid direction
    float glShape;      // 1 lines, 2 irregular, 3 wave, 4 zigzag, 5 pattern
    float glDistShape;  // 1 prism, 2 lens, 3 contour, 4 cascade, 5 flat
    float glDistortion; // 0..1 refraction power
    float glShadows;    // 0..1
    float glHighlights; // 0..1
    float glBlur;       // 0..1 one-directional blur
    // dither layer
    float ditherIdx;    // index of the dither layer, <0 = none
    float dPxSize;      // pixel-grid size
    float dType;        // 1 random, 2 Bayer2, 3 Bayer4, 4 Bayer8
    float dLevels;      // colour steps per channel (2..8)
};
layout(binding = 1) uniform sampler2D s0;
layout(binding = 2) uniform sampler2D s1;
layout(binding = 3) uniform sampler2D s2;
layout(binding = 4) uniform sampler2D s3;

const float ASPECT = 1.6;
const float PI = 3.14159265358979;

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

// composite layers [0, upto) at an arbitrary uv — the content a glass layer
// at index `upto` refracts. upto<1 → nothing below.
vec3 composeUpto(vec2 uv, int upto) {
    if (upto < 1) return vec3(0.0);
    vec3 c = texture(s0, uv).rgb;
    int n = min(upto, int(count + 0.5));
    if (n > 1) c = blendOne(c, texture(s1, uv).rgb, modev.y, opac.y);
    if (n > 2) c = blendOne(c, texture(s2, uv).rgb, modev.z, opac.z);
    if (n > 3) c = blendOne(c, texture(s3, uv).rgb, modev.w, opac.w);
    return c;
}

vec2 g_rotate(vec2 p, float a) { return mat2(cos(a), sin(a), -sin(a), cos(a)) * p; }
vec2 rotateAspect(vec2 p, float a, float aspect) { p.x *= aspect; p = g_rotate(p, a); p.x /= aspect; return p; }
float smoothFract(float x) {
    float f = fract(x), w = fwidth(x);
    float edge = abs(f - 0.5) - 0.5;
    return mix(f, 1.0 - f, smoothstep(-w, w, edge));
}

// Paper fluted-glass: refract composeUpto(., belowCount) through ribbed flutes.
vec3 flutedGlass(vec2 uv0, int belowCount) {
    float aspect = ASPECT;
    float patternRotation = -glAngle * PI / 180.0;
    float patternSize = mix(200.0, 5.0, clamp(glSize, 0.0, 1.0));

    vec2 uv = (uv0 - 0.5) * patternSize;
    uv = rotateAspect(uv, patternRotation, aspect);

    float curve = 0.0;
    float patternY = uv.y / aspect;
    if      (glShape > 4.5) curve = 0.5 + 0.5 * sin(0.5 * PI * uv.x) * cos(0.5 * PI * patternY);
    else if (glShape > 3.5) curve = 10.0 * abs(fract(0.1 * patternY) - 0.5);
    else if (glShape > 2.5) curve = 4.0 * sin(0.23 * patternY);
    else if (glShape > 1.5) curve = 0.5 + 0.5 * sin(0.5 * uv.x) * sin(1.7 * uv.x);

    vec2 UvToFract = uv + curve;
    vec2 fractOrigUV = fract(uv);
    vec2 floorOrigUV = floor(uv);

    float x = smoothFract(UvToFract.x);
    float xNonSmooth = fract(UvToFract.x) + 0.0001;

    float hlW = 2.0 * max(0.001, fwidth(UvToFract.x));
    float highlights = smoothstep(0.0, hlW, xNonSmooth) * smoothstep(1.0, 1.0 - hlW, xNonSmooth);
    highlights = clamp((1.0 - highlights) * clamp(glHighlights, 0.0, 1.0), 0.0, 1.0);

    float shadows = pow(x, 1.3);
    float distortion = 0.0, fadeX = 1.0;
    float aa = max(max(fwidth(xNonSmooth), fwidth(uv.x)), 0.0001);

    if (glDistShape < 1.5) {              // prism
        distortion = -pow(1.5 * x, 3.0) + 0.5;
        aa = max(0.2, aa) + mix(0.2, 0.0, glSize);
        fadeX = smoothstep(0.0, aa, xNonSmooth) * smoothstep(1.0, 1.0 - aa, xNonSmooth);
        distortion = mix(0.5, distortion, fadeX);
    } else if (glDistShape < 2.5) {       // lens
        distortion = 2.0 * pow(x, 2.0) - 0.5;
        aa = max(0.2, aa) + mix(0.2, 0.0, glSize);
        fadeX = smoothstep(0.0, aa, xNonSmooth) * smoothstep(1.0, 1.0 - aa, xNonSmooth);
        distortion = mix(0.5, distortion, fadeX);
    } else if (glDistShape < 3.5) {       // contour
        distortion = pow(2.0 * (xNonSmooth - 0.5), 6.0) - 0.25;
    } else if (glDistShape < 4.5) {       // cascade
        x = xNonSmooth;
        distortion = sin((x + 0.25) * 6.28318530718);
        shadows = 0.5 + 0.5 * asin(clamp(distortion, -1.0, 1.0)) / (0.5 * PI);
        distortion *= 0.5;
    } else {                              // flat
        distortion = (-pow(abs(x), 0.2) * x + 0.33) * 0.33;
        aa = max(0.1, aa) + mix(0.1, 0.0, glSize);
        fadeX = smoothstep(0.0, aa, xNonSmooth) * smoothstep(1.0, 1.0 - aa, xNonSmooth);
        distortion *= fadeX;
    }

    shadows = clamp(min(shadows, 1.0) * pow(clamp(glShadows, 0.0, 1.0), 2.0), 0.0, 1.0);
    distortion *= 3.0 * clamp(glDistortion, 0.0, 1.0);

    fractOrigUV.x += distortion;
    floorOrigUV = rotateAspect(floorOrigUV, -patternRotation, aspect);
    fractOrigUV = rotateAspect(fractOrigUV, -patternRotation, aspect);
    vec2 duv = (floorOrigUV + fractOrigUV) / patternSize + 0.5;

    // sample the refracted below-composite, with a small vertical glass blur
    vec3 base = composeUpto(duv, belowCount);
    float blur = clamp(glBlur, 0.0, 1.0) * 6.0;
    if (blur > 0.5) {
        vec2 texel = vec2(0.0, 1.0 / 900.0);
        float wsum = 1.0;
        for (int i = 1; i <= 6; i++) {
            if (float(i) > blur) break;
            float w = exp(-float(i) * float(i) / 8.0);
            base += (composeUpto(duv + texel * float(i), belowCount) +
                     composeUpto(duv - texel * float(i), belowCount)) * w;
            wsum += 2.0 * w;
        }
        base /= wsum;
    }

    // glass shading: dark valleys, bright edge strokes
    vec3 col = mix(base, vec3(0.0), 0.5 * shadows);
    col += vec3(1.0) * highlights;
    return clamp(col, 0.0, 1.0);
}

const int BAYER2[4] = int[4](0, 2, 3, 1);
const int BAYER4[16] = int[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
const int BAYER8[64] = int[64](
    0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
    12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
    3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
    15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21);
float bayer(vec2 cell, int size) {
    ivec2 p = ivec2(mod(cell, float(size)));
    int i = p.y * size + p.x;
    if (size == 2) return float(BAYER2[i]) / 4.0;
    if (size == 4) return float(BAYER4[i]) / 16.0;
    return float(BAYER8[i]) / 64.0;
}

// ordered-dither the composite of layers below through a pixel grid — keeps
// the design's colours, quantizes each channel with a Bayer/random threshold.
vec3 ditherFilter(vec2 uv, int belowCount) {
    float px = max(dPxSize, 0.5) / 1600.0;      // grid cell in UV
    vec2 cell = floor(uv / px);
    vec3 col = composeUpto((cell + 0.5) * px, belowCount);
    int t = int(dType + 0.5);
    float thr = (t <= 1) ? hash12(cell) : bayer(cell, t == 2 ? 2 : (t == 3 ? 4 : 8));
    float lv = max(dLevels, 2.0) - 1.0;
    col = floor(col * lv + (thr - 0.5) + 0.5) / lv;
    return clamp(col, 0.0, 1.0);
}

// pick a layer's contribution: glass/dither filter over what's below, else its texture
vec3 layerPick(int i, vec2 uv, vec3 below, bool isFirst) {
    if (glassIdx > -0.5 && int(floor(glassIdx + 0.5)) == i) return flutedGlass(uv, i);
    if (ditherIdx > -0.5 && int(floor(ditherIdx + 0.5)) == i) return ditherFilter(uv, i);
    vec3 tex = i == 0 ? texture(s0, uv).rgb : (i == 1 ? texture(s1, uv).rgb : (i == 2 ? texture(s2, uv).rgb : texture(s3, uv).rgb));
    float m = i == 1 ? modev.y : (i == 2 ? modev.z : modev.w);
    float o = i == 1 ? opac.y : (i == 2 ? opac.z : opac.w);
    return isFirst ? tex : blendOne(below, tex, m, o);
}

vec3 composeWithGlass(vec2 uv) {
    int n = int(count + 0.5);
    vec3 c = layerPick(0, uv, vec3(0.0), true);
    if (n > 1) c = layerPick(1, uv, c, false);
    if (n > 2) c = layerPick(2, uv, c, false);
    if (n > 3) c = layerPick(3, uv, c, false);
    return c;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 col;
    if (gBlur < 0.5) {
        col = composeWithGlass(uv);
    } else {
        float r = gBlur / 2200.0;
        vec2 D[12] = vec2[](
            vec2(-0.326, -0.406), vec2(-0.840, -0.074), vec2(-0.696, 0.457),
            vec2(-0.203, 0.621),  vec2(0.962, -0.195),  vec2(0.473, -0.480),
            vec2(0.519, 0.767),   vec2(0.185, -0.893),  vec2(0.507, 0.064),
            vec2(0.896, 0.412),   vec2(-0.322, -0.933), vec2(-0.792, -0.598));
        col = composeWithGlass(uv);
        for (int k = 0; k < 12; k++)
            col += composeWithGlass(uv + vec2(D[k].x / ASPECT, D[k].y) * r);
        col /= 13.0;
    }
    col = clamp(col + (hash12(uv * vec2(3840.0, 2400.0)) - 0.5) * gGrain, 0.0, 1.0);
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
