#version 450

layout(location = 0) in vec2  inPosition;
layout(location = 1) in vec2  inUV;
layout(location = 2) in vec4  inColor;
layout(location = 3) in uint  inTexID;
layout(location = 4) in vec4  inCornerRadii;    // [TL, TR, BR, BL] or [weight,0,0,0] for MSDF
layout(location = 5) in vec4  inClipRect;
layout(location = 6) in vec4  inClipRoundRect;  // [min_x, min_y, max_x, max_y]
layout(location = 7) in vec4  inClipRoundRadii; // [TL, TR, BR, BL]
layout(location = 8) in vec4  inBorderWidths;   // [top, right, bottom, left]
layout(location = 9) in vec4  inOutlineWidths;  // [top, right, bottom, left]
layout(location = 10) in vec4 inSdfParams;      // [softness, logical_w, logical_h, sdf_padding]
layout(location = 11) in uvec4 inBorderColors;  // packed RGBA8 [top, right, bottom, left]
layout(location = 12) in uvec4 inOutlineColors; // packed RGBA8 [top, right, bottom, left]

layout(location = 0) out vec4        fragColor;
layout(location = 1) out vec2        fragUV;
layout(location = 2) out flat uint   fragTexID;
layout(location = 3) out flat vec4   fragCornerRadii;
layout(location = 4) out flat vec4   fragClipRect;
layout(location = 5) out flat vec4   fragClipRoundRect;
layout(location = 6) out flat vec4   fragClipRoundRadii;
layout(location = 7) out flat vec4   fragBorderWidths;
layout(location = 8) out flat vec4   fragOutlineWidths;
layout(location = 9) out flat vec4   fragSdfParams;
layout(location = 10) out flat uvec4 fragBorderColors;
layout(location = 11) out flat uvec4 fragOutlineColors;

layout(set = 0, binding = 0) uniform GlobalUBO {
    mat4 projection;
    float time;
    vec2 viewport_size;
} ubo;

void main() {
    gl_Position     = ubo.projection * vec4(inPosition, 0.0, 1.0);
    fragColor       = inColor;
    fragUV          = inUV;
    fragTexID       = inTexID;
    fragCornerRadii = inCornerRadii;
    fragClipRect    = inClipRect;
    fragClipRoundRect = inClipRoundRect;
    fragClipRoundRadii = inClipRoundRadii;
    fragBorderWidths  = inBorderWidths;
    fragOutlineWidths = inOutlineWidths;
    fragSdfParams   = inSdfParams;
    fragBorderColors  = inBorderColors;
    fragOutlineColors = inOutlineColors;
}
