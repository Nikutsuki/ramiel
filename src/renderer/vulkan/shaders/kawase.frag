#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 2) uniform sampler2D textures[];

layout(push_constant) uniform PushConstants {
    vec2 half_pixel;
    uint input_tex_id;
    uint is_up;
} pc;

void main() {
    vec4 sum = vec4(0.0);
    uint id = nonuniformEXT(pc.input_tex_id);
    
    if (pc.is_up == 1) {
        // 4-Tap Upsample
        sum += texture(textures[id], fragUV + vec2(-pc.half_pixel.x * 2.0, 0.0));
        sum += texture(textures[id], fragUV + vec2(-pc.half_pixel.x, pc.half_pixel.y)) * 2.0;
        sum += texture(textures[id], fragUV + vec2(0.0, pc.half_pixel.y * 2.0));
        sum += texture(textures[id], fragUV + vec2(pc.half_pixel.x, pc.half_pixel.y)) * 2.0;
        sum += texture(textures[id], fragUV + vec2(pc.half_pixel.x * 2.0, 0.0));
        sum += texture(textures[id], fragUV + vec2(pc.half_pixel.x, -pc.half_pixel.y)) * 2.0;
        sum += texture(textures[id], fragUV + vec2(0.0, -pc.half_pixel.y * 2.0));
        sum += texture(textures[id], fragUV + vec2(-pc.half_pixel.x, -pc.half_pixel.y)) * 2.0;
        outColor = sum / 12.0;
    } else {
        // 4-Tap Downsample
        sum += texture(textures[id], fragUV) * 4.0;
        sum += texture(textures[id], fragUV - pc.half_pixel);
        sum += texture(textures[id], fragUV + pc.half_pixel);
        sum += texture(textures[id], fragUV + vec2(pc.half_pixel.x, -pc.half_pixel.y));
        sum += texture(textures[id], fragUV + vec2(-pc.half_pixel.x, pc.half_pixel.y));
        outColor = sum / 8.0;
    }
}