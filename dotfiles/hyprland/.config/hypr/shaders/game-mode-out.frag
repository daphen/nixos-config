precision highp float;
varying vec2 v_texcoord;
uniform sampler2D tex;
uniform float time;

void main() {
    float progress = clamp(time / 0.24, 0.0, 1.0);
    float scale = mix(1.0, 0.90, 1.0 - pow(1.0 - progress, 3.0));
    vec2 uv = (v_texcoord - 0.5) / scale + 0.5;
    float opacity = 1.0 - smoothstep(0.18, 0.40, time);
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
    else
        gl_FragColor = vec4(texture2D(tex, uv).rgb * opacity, 1.0);
}
