#version 450

layout(location = 0) in vec4 fragColor;
layout(location = 1) in vec2 fragUV;
layout(location = 4) in flat vec4 fragClipRect;
layout(location = 5) in flat vec4 fragClipRoundRect;
layout(location = 6) in flat vec4 fragClipRoundRadii;

layout(location = 0) out vec4 outColor;

layout(set = 1, binding = 0) uniform sampler2D tex_y;
layout(set = 1, binding = 1) uniform sampler2D tex_u;
layout(set = 1, binding = 2) uniform sampler2D tex_v;

void main() {
    if (gl_FragCoord.x < fragClipRect.x || gl_FragCoord.y < fragClipRect.y ||
        gl_FragCoord.x > fragClipRect.z || gl_FragCoord.y > fragClipRect.w) {
        discard;
    }

    float rounded_clip_cov = 1.0;
    float max_round_radius = max(
        max(fragClipRoundRadii.x, fragClipRoundRadii.y),
        max(fragClipRoundRadii.z, fragClipRoundRadii.w)
    );
    if (max_round_radius > 0.0) {
        vec2 clip_min = fragClipRoundRect.xy;
        vec2 clip_max = fragClipRoundRect.zw;
        vec2 half_size = max((clip_max - clip_min) * 0.5, vec2(0.0));
        if (half_size.x <= 0.0 || half_size.y <= 0.0) {
            discard;
        }

        float max_radius = max(0.0, min(half_size.x, half_size.y));
        vec4 clip_radii = clamp(fragClipRoundRadii, vec4(0.0), vec4(max_radius));
        vec2 clip_center = (clip_min + clip_max) * 0.5;
        vec2 clip_p = gl_FragCoord.xy - clip_center;

        float clip_radius;
        if (clip_p.x >= 0.0)
            clip_radius = (clip_p.y >= 0.0) ? clip_radii.z : clip_radii.y;
        else
            clip_radius = (clip_p.y >= 0.0) ? clip_radii.w : clip_radii.x;

        vec2 clip_b = half_size - vec2(clip_radius);
        vec2 clip_d = abs(clip_p) - clip_b;
        float clip_dist = length(max(clip_d, vec2(0.0))) + min(max(clip_d.x, clip_d.y), 0.0) - clip_radius;
        rounded_clip_cov = 1.0 - smoothstep(0.0, 1.0, clip_dist);
        if (rounded_clip_cov <= 0.0) {
            discard;
        }
    }

    float y = texture(tex_y, fragUV).r;
    float u = texture(tex_u, fragUV).r - 0.5;
    float v = texture(tex_v, fragUV).r - 0.5;

    vec3 rgb = vec3(
        y + 1.402 * v,
        y - 0.344 * u - 0.714 * v,
        y + 1.772 * u
    );

    vec4 baseColor = vec4(clamp(rgb, 0.0, 1.0), 1.0) * fragColor;
    baseColor.a *= rounded_clip_cov;
    outColor = baseColor;
}
