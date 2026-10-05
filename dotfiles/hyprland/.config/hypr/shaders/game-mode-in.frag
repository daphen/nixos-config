#version 300 es

precision highp float;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
uniform sampler2D tex;
uniform float time;

void main() {
    float opacity = smoothstep(0.0, 0.18, time);
    fragColor = vec4(texture(tex, v_texcoord).rgb * opacity, 1.0);
}
