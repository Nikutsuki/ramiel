#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 frag_color;
layout(set = 0, binding = 0) uniform Uniforms {
    vec2 resolution;
    float time;
    float delta;
    uint frame;
    vec4 user[8];
} u;

void main() {
    vec2 p = uv * 2.0 - 1.0;
    p.x *= u.resolution.x / u.resolution.y;
    float t = u.time * 0.4;

    float r = length(p);
    float a = atan(p.y, p.x);
    float v = sin(a * 3.0 + t * 2.5 + r * 6.0) * 0.5 + 0.5;
    v += 0.5 * sin(r * 10.0 - t * 3.0);

    vec3 col = 0.5 + 0.5 * cos(vec3(0.0, 2.094, 4.188) + v * 2.0 + t + r);
    col *= smoothstep(1.6, 0.1, r);
    col = mix(vec3(0.03, 0.04, 0.08), col, 0.9);

    frag_color = vec4(col, 1.0);
}
