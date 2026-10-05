#version 300 es

precision highp float;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
uniform sampler2D tex;
uniform float time;

void main() {
    float progress = clamp(time / 0.42, 0.0, 1.0);
    float scale = mix(0.90, 1.0, 1.0 - pow(1.0 - progress, 3.0));
    vec2 uv = (v_texcoord - 0.5) / scale + 0.5;
    float opacity = smoothstep(0.0, 0.18, time);
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    else
        fragColor = vec4(texture(tex, uv).rgb * opacity, 1.0);
}
