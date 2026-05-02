const Node = @import("../node.zig").Node;
const UIContext = @import("../context.zig").UIContext;
const Style = @import("../layout.zig").Style;
const ImageFallbackState = @import("../node.zig").RenderPayload.ImageFallbackState;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;
const NO_TEXTURE = @import("../../assets.zig").NO_TEXTURE;

pub const IconDescriptor = struct {
    icon_id: u32,
    scale: f32 = 1.0,
    intrinsic_size: [2]f32,
    style: Style = .{},
    tint: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    fallback_state: ImageFallbackState = .decoding,
    alt_text: []const u8 = "",
    alt_font: ?*FontData = null,
};

pub fn build(
    comptime MessageT: type,
    ui: *UIContext(MessageT),
    desc: IconDescriptor,
) !*Node(MessageT) {
    const resolver = ui.icon_resolver orelse return error.IconResolverNotWired;
    const tex_id = resolver.getTexId(resolver.context, desc.icon_id, desc.scale) orelse NO_TEXTURE;

    return ui.image(.{
        .style = desc.style,
        .tex_id = tex_id,
        .tint = desc.tint,
        .intrinsic_size = desc.intrinsic_size,
        .fallback_state = desc.fallback_state,
        .alt_text = desc.alt_text,
        .alt_font = desc.alt_font,
    });
}
