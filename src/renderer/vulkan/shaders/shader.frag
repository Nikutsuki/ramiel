#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec4       fragColor;
layout(location = 1) in vec2       fragUV;
layout(location = 2) in flat uint  fragTexID;
/// [TL, TR, BR, BL] corner radii — or font weight in .x for MSDF text.
layout(location = 3) in flat vec4  fragCornerRadii;
layout(location = 4) in flat vec4  fragClipRect;
/// Active rounded clip rect [min_x, min_y, max_x, max_y].
layout(location = 5) in flat vec4  fragClipRoundRect;
/// Active rounded clip radii [TL, TR, BR, BL].
layout(location = 6) in flat vec4  fragClipRoundRadii;
/// [top, right, bottom, left] border widths (inside).
layout(location = 7) in flat vec4  fragBorderWidths;
/// [top, right, bottom, left] outline widths (outside).
layout(location = 8) in flat vec4  fragOutlineWidths;
/// [softness, logical_w, logical_h, sdf_padding]
layout(location = 9) in flat vec4  fragSdfParams;
/// Packed RGBA8 per side [top, right, bottom, left].
layout(location = 10) in flat uvec4 fragBorderColors;
layout(location = 11) in flat uvec4 fragOutlineColors;

layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform GlobalUBO {
    mat4 projection;
    float time;
    vec2 viewport_size;
} ubo;

layout(set = 0, binding = 1) uniform sampler2D backgroundScene;
layout(set = 0, binding = 2) uniform sampler2D textures[];

layout(push_constant) uniform PushConstants {
    vec4 params;
} pc;

float median3(float a, float b, float c) {
    return max(min(a, b), min(max(a, b), c));
}

void main() {
    // Scissor clip.
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
            clip_radius = (clip_p.y >= 0.0) ? clip_radii.z : clip_radii.y; // BR : TR
        else
            clip_radius = (clip_p.y >= 0.0) ? clip_radii.w : clip_radii.x; // BL : TL

        vec2 clip_b = half_size - vec2(clip_radius);
        vec2 clip_d = abs(clip_p) - clip_b;
        float clip_dist = length(max(clip_d, vec2(0.0))) + min(max(clip_d.x, clip_d.y), 0.0) - clip_radius;
        rounded_clip_cov = 1.0 - smoothstep(0.0, 1.0, clip_dist);
        if (rounded_clip_cov <= 0.0) {
            discard;
        }
    }

    uint flags  = fragTexID >> 16;
    uint texIdx = fragTexID & 0xFFFFu;
    vec4 baseColor = fragColor;
    bool has_backdrop_blur = (flags & (1u << 1)) != 0u; // EFFECT_BACKDROP_BLUR
    bool has_element_blur  = (flags & (1u << 3)) != 0u; // EFFECT_ELEMENT_BLUR
    int  element_mode      = int(pc.params.w + 0.5);    // 0=normal, 1=capture, 2=composite

    // Element blur – composite pass: sample the pre-blurred background.
    if (has_element_blur && element_mode == 2) {
        vec2 screenUV = gl_FragCoord.xy / ubo.viewport_size;
        outColor = texture(backgroundScene, screenUV) * fragColor;
        outColor.a *= rounded_clip_cov;
        return;
    }
    // Capture pass: suppress backdrop blur so we record raw source content.
    if (has_element_blur && element_mode == 1) has_backdrop_blur = false;

    // Backdrop blur base.
    if (has_backdrop_blur) {
        vec2 screenUV = gl_FragCoord.xy / ubo.viewport_size;
        vec4 bg = texture(backgroundScene, screenUV);
        baseColor.rgb = mix(bg.rgb, baseColor.rgb, baseColor.a);
        baseColor.a   = 1.0;
    }

    // Foreground texture (skip for MSDF/bitmap text – handled below).
    if (texIdx != 0xFFFFu && (flags & (1u << 2)) == 0u && (flags & (1u << 4)) == 0u) {
        baseColor *= texture(textures[nonuniformEXT(texIdx)], fragUV);
    }

    // Hinted bitmap text alpha. Atlas stores coverage replicated to RGBA.
    // fragCornerRadii.x = font_weight (0..1+). Lower weight => thinner; higher => heavier.
    // Gamma-based stem darkening: at default weight 0.7 -> exp 0.55 (moderate thickening)
    // to roughly match MSDF visual weight at the crossover.
    if ((flags & (1u << 4)) != 0u) { // EFFECT_BITMAP_TEXT
        float cov = texture(textures[nonuniformEXT(texIdx)], fragUV).r;
        float bw = fragCornerRadii.x;
        if (bw <= 0.0) bw = 0.7;
        float gamma_exp = clamp(1.0 - bw, 0.2, 2.0);
        cov = pow(cov, gamma_exp);
        baseColor.a *= cov;
        baseColor.rgb *= cov;
    }

    // MSDF text alpha.
    // fragCornerRadii.x = weight, fragCornerRadii.y = pxRange used at generation.
    if ((flags & (1u << 2)) != 0u) { // EFFECT_MSDF_TEXT
        float weight    = 0.6 + (fragCornerRadii.x - 0.6) * 0.2;
        float threshold = 1.0 - weight;
        float pxRange   = max(fragCornerRadii.y, 1.0);
        vec3 msd        = texture(textures[nonuniformEXT(texIdx)], fragUV).rgb;
        float sd        = median3(msd.r, msd.g, msd.b);

        vec2 unitRange = vec2(pxRange) / vec2(textureSize(textures[nonuniformEXT(texIdx)], 0));
        vec2 uvFwidth = max(fwidth(fragUV), vec2(1e-5));
        vec2 screenTexSize = vec2(1.0) / uvFwidth;
        float screenPxRange = max(0.5 * dot(unitRange, screenTexSize), 1.0);

        const float MSDF_DERIVATIVE_SCALE = 0.90;
        const float MSDF_DERIVATIVE_MIN = 1.0;
        screenPxRange = max(screenPxRange * MSDF_DERIVATIVE_SCALE, MSDF_DERIVATIVE_MIN);

        float opacity = clamp(screenPxRange * (sd - threshold) + 0.5, 0.0, 1.0);
        baseColor.a *= opacity;
        baseColor.rgb *= opacity;
    }

    // SDF: per-corner rounding, per-side border, per-side outline
    if ((flags & (1u << 0)) != 0u) { // EFFECT_SDF_ROUNDED
        float softness    = fragSdfParams.x;
        vec2  logical     = fragSdfParams.yz;
        float sdf_padding = fragSdfParams.w;
        float sm = max(softness, 1.0);

        // Reconstruct world-space position relative to element centre.
        vec2 expanded = logical + vec2(sdf_padding * 2.0);
        vec2 p    = (fragUV - 0.5) * expanded;
        vec2 half_size = logical * 0.5;

        // Per-corner radius
        // Quadrant: p.x >= 0 = right side (TR/BR); p.y >= 0 = bottom (BL/BR).
        float radius;
        if (p.x >= 0.0)
            radius = (p.y >= 0.0) ? fragCornerRadii.z : fragCornerRadii.y; // BR : TR
        else
            radius = (p.y >= 0.0) ? fragCornerRadii.w : fragCornerRadii.x; // BL : TL

        // Rounded-box SDF.
        vec2 b    = half_size - vec2(radius);
        vec2 d    = abs(p) - b;
        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;

        // Outer shape coverage (handles anti-aliased edge).
        float shape_cov = 1.0 - smoothstep(0.0, sm, dist);

        // Use distances to the four box lines to smoothly pick side width/colour,
        // then apply those widths in SDF-space so border/outline follow corner arcs.
        const float eps = 1e-4;
        vec4 line_dist = vec4(
            abs(p.y + half_size.y), // top
            abs(p.x - half_size.x), // right
            abs(p.y - half_size.y), // bottom
            abs(p.x + half_size.x)  // left
        );
        // Softer side falloff so border/outline carry around corners more naturally.
        vec4 side_raw = 1.0 / (line_dist + vec4(eps));
        vec4 side_w = side_raw / max(dot(side_raw, vec4(1.0)), eps);

        // Per-side border (inside the shape, constant thickness on curves)
        vec4 bw = max(fragBorderWidths, vec4(0.0));
        vec4 bw_mix = side_w * bw;
        float bw_mix_sum = dot(bw_mix, vec4(1.0));
        float border_w = dot(side_w, bw);

        float inner_cov = 1.0 - smoothstep(0.0, sm, dist + border_w);
        float border_cov = (border_w > 0.0) ? clamp(shape_cov - inner_cov, 0.0, 1.0) : 0.0;
        vec4 border_col = (bw_mix_sum > eps)
                ? (unpackUnorm4x8(fragBorderColors.x) * bw_mix.x +
                    unpackUnorm4x8(fragBorderColors.y) * bw_mix.y +
                    unpackUnorm4x8(fragBorderColors.z) * bw_mix.z +
                    unpackUnorm4x8(fragBorderColors.w) * bw_mix.w) / bw_mix_sum
            : vec4(0.0);

        // Per-side outline (outside the shape, constant thickness on curves)
        vec4 ow = max(fragOutlineWidths, vec4(0.0));
        vec4 ow_mix = side_w * ow;
        float ow_mix_sum = dot(ow_mix, vec4(1.0));
        float outline_w = dot(side_w, ow);

        float outer_cov = 1.0 - smoothstep(0.0, sm, dist - outline_w);
        float outline_cov = (outline_w > 0.0) ? clamp(outer_cov - shape_cov, 0.0, 1.0) : 0.0;
        vec4 outline_col = (ow_mix_sum > eps)
                ? (unpackUnorm4x8(fragOutlineColors.x) * ow_mix.x +
                    unpackUnorm4x8(fragOutlineColors.y) * ow_mix.y +
                    unpackUnorm4x8(fragOutlineColors.z) * ow_mix.z +
                    unpackUnorm4x8(fragOutlineColors.w) * ow_mix.w) / ow_mix_sum
            : vec4(0.0);

        // CSS box-model compositing (background-clip: border-box):
        //   - background fills the entire SHAPE (inner_cov + border_cov region)
        //   - border draws ON TOP of the background in the border zone
        //   - outline draws OUTSIDE the shape; no background under it
        // The fragment is partitioned spatially by SDF coverage; per-region
        // colours are then mosaic-composited so AA bands don't double-count.
        vec3 border_zone_rgb;
        float border_zone_a;
        {
            // Effective colour in the border region: bg with border composited over.
            float ba = border_col.a;
            border_zone_a = baseColor.a + ba * (1.0 - baseColor.a);
            if (border_zone_a > eps) {
                border_zone_rgb = (baseColor.rgb * baseColor.a * (1.0 - ba) + border_col.rgb * ba) / border_zone_a;
            } else {
                border_zone_rgb = vec3(0.0);
            }
        }

        float ia = baseColor.a * inner_cov;
        float ba_w = border_zone_a * border_cov;
        float oa_w = outline_col.a * outline_cov;
        float total_a = ia + ba_w + oa_w;
        if (total_a > eps) {
            baseColor.rgb = (baseColor.rgb * ia + border_zone_rgb * ba_w + outline_col.rgb * oa_w) / total_a;
        }
        baseColor.a = total_a;
    }

    baseColor.a *= rounded_clip_cov;
    outColor = baseColor;
}
