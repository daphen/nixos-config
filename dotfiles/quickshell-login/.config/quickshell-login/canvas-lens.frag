#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;
    float edgeBlur;
    float edgeBlurStart;
    float vignette;
    float chromatic;
    vec2 fullSize;
};

layout(binding = 1) uniform sampler2D source;

vec3 lensSample(vec2 uv, vec2 fringe) {
    if (fringe.x == 0.0 && fringe.y == 0.0)
        return texture(source, clamp(uv, 0.0, 1.0)).rgb;
    return vec3(texture(source, clamp(uv + fringe, 0.0, 1.0)).r,
                texture(source, clamp(uv, 0.0, 1.0)).g,
                texture(source, clamp(uv - fringe, 0.0, 1.0)).b);
}

void main() {
    float distort = 0.14 * progress;
    float contrast = 1.0 + (1.08 - 1.0) * progress;
    float brightness = 0.025 * progress;
    vec2 centered = qt_TexCoord0 * 2.0 - 1.0;
    float radius2 = dot(centered, centered);
    vec2 uv = centered * (1.0 + distort * radius2) / max(contrast, 0.001) * 0.5 + 0.5;
    vec2 edgeDistance = min(uv, 1.0 - uv);
    float edgeAlpha = brightness <= 0.0 ? 1.0 : smoothstep(0.0, brightness, min(edgeDistance.x, edgeDistance.y));
    float radius = sqrt(radius2) * 0.70710678;
    float ramp = smoothstep(min(edgeBlurStart, 0.99), 1.0, radius);
    vec2 outward = radius > 0.0001 ? centered / sqrt(radius2) : vec2(0.0);
    float fringeRamp = smoothstep(0.1, 1.0, radius);
    vec2 fringe = outward * chromatic * progress * fringeRamp * fringeRamp * 0.014;
    float blur = edgeBlur * progress * ramp;
    vec3 color;
    if (blur > 0.001) {
        float radiusPx = blur * 0.02 * fullSize.y;
        vec2 texel = 1.0 / max(fullSize, vec2(1.0));
        color = vec3(0.0);
        for (int i = 0; i < 24; ++i) {
            float t = (float(i) + 0.5) / 24.0;
            float angle = float(i) * 2.39996323;
            color += lensSample(uv + vec2(cos(angle), sin(angle)) * sqrt(t) * radiusPx * texel, fringe);
        }
        color /= 24.0;
    } else {
        color = lensSample(uv, fringe);
    }
    color *= 1.0 - vignette * progress * smoothstep(0.2, 1.0, radius);
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) - 0.5;
    float activeVignette = vignette * progress;
    float alpha = texture(source, clamp(uv, 0.0, 1.0)).a;
    fragColor = vec4(clamp(color * edgeAlpha + noise * (activeVignette / 255.0), 0.0, 1.0), alpha) * qt_Opacity;
}
