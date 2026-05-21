const std = @import("std");

pub const tracy_impl = @import("tracy_impl");

pub const UIContext = @import("ui/context.zig").UIContext;
pub const Node = @import("ui/node.zig").Node;
pub const dupeMessageBinding = @import("ui/node.zig").dupeMessageBinding;
pub const InteractionMessage = @import("ui/types.zig").InteractionMessage;
pub const FontSource = @import("renderer/font/font_registry.zig").FontSource;
pub const FontData = @import("renderer/font/font_registry.zig").FontData;
pub const assets = @import("assets.zig");
pub const glfw = @import("glfw");
pub const Application = @import("app.zig").Application;
pub const ManagedApp = @import("managed_app.zig").ManagedApp;
pub const SinglePageApp = @import("managed_app.zig").SinglePageApp;
pub const AppBackendConfig = platform.AppBackendConfig;
pub const platform = @import("platform/backend.zig");
pub const SurfaceKind = platform.SurfaceKind;
pub const LayerShellOptions = platform.LayerShellOptions;
pub const PopupLauncherOptions = platform.PopupLauncherOptions;
pub const ActivationRequest = platform.ActivationRequest;
pub const WindowContext = @import("window/window.zig").WindowContext;
pub const HotkeyFn = @import("app.zig").HotkeyFn;
pub const win32 = @import("window/win32.zig");
pub const layout = @import("ui/layout.zig");
pub const components = @import("ui/components/root.zig");
pub const paint_context = @import("ui/paint_context.zig");
pub const PaintContext = paint_context.PaintContext;
pub const PaintFn = paint_context.PaintFn;
pub const types = @import("ui/types.zig");
pub const NodeId = @import("ui/types.zig").NodeId;
pub const GridTrack = layout.GridTrack;
pub const BoxSizing = layout.BoxSizing;
pub const UpdateAction = @import("app.zig").UpdateAction;
pub const animation = @import("animation/root.zig");
pub const EasingFunction = animation.EasingFunction;
pub const AnimationEntry = animation.AnimationEntry;
pub const AnimatedValue = animation.AnimatedValue;
pub const AnimatedProperty = animation.AnimatedProperty;
pub const TransitionStyle = layout.TransitionStyle;
pub const TransitionProperty = layout.TransitionProperty;
pub const Transform = layout.Transform;
pub const Color = @import("ui/color.zig");
pub const bench_prefetch = @import("ui/bench_prefetch.zig");
pub const ImageIngressBudget = @import("renderer/image_ingress.zig").ImageIngressBudget;
pub const Canvas = @import("renderer/canvas.zig").Canvas;
pub const PixelBuffer = @import("renderer/pixel_buffer.zig").PixelBuffer;
pub const ShaderCompiler = @import("renderer/shader_compiler.zig").Compiler;
pub const ShaderStage = @import("renderer/shader_compiler.zig").Stage;
pub const IconRegistry = @import("renderer/icon/registry.zig").IconRegistry;
pub const IconId = @import("renderer/icon/id.zig").IconId;
pub const hashIconId = @import("renderer/icon/id.zig").hashId;
pub const renderer = struct {
    pub const PixelBuffer = @import("renderer/pixel_buffer.zig").PixelBuffer;
    pub const VulkanEngine = @import("renderer/vulkan/engine.zig").Engine;
    pub const RenderSurface = @import("renderer/vulkan/surface.zig").RenderSurface;
};
pub const stb = @import("thirdparty/stb_image/stb_image.zig");
pub const VideoManager = @import("video/manager.zig").VideoManager;
pub const VideoPlayback = @import("video/playback.zig").VideoPlayback;
pub const audio_waveform = @import("audio/waveform.zig");
pub const audio_spectrum = @import("audio/spectrum.zig");
pub const audio_engine = @import("audio/audio_engine.zig");
pub const StreamSeekStatus = @import("audio/registry.zig").StreamSeekStatus;
pub const AdvanceEvent = @import("audio/registry.zig").AdvanceEvent;
pub const DevToolsTab = @import("devtools/state.zig").DevToolsTab;
pub const DevToolsState = @import("devtools/state.zig").DevToolsState;
pub const DevToolsTabModule = @import("devtools/modules.zig").TabModule;
pub const Style = @import("ui/layout.zig").Style;
pub const tw = @import("ui/tw.zig");
pub const uix = @import("ui/uix.zig");
pub const state = @import("state.zig");
pub const palette = @import("assets/palette.zig");
pub const theme = @import("ui/theme.zig");
pub const Theme = theme.Theme;
pub const SemanticTokens = theme.SemanticTokens;
pub const Palette = palette.Palette;

pub const Runtime = @import("runtime.zig").Runtime;
pub const FontSpec = @import("managed_app.zig").FontSpec;

pub const hotreload = struct {
    pub const abi = @import("hotreload/abi.zig");
    pub const abi_version = abi.abi_version;
    pub const abiHash = abi.abiHash;
    pub const Coordinator = @import("hotreload/coordinator.zig").Coordinator;
    pub const Watcher = @import("hotreload/watcher.zig").Watcher;
    pub const snapshot = @import("hotreload/snapshot.zig");
    pub const dynlib = @import("hotreload/dynlib.zig");
};

pub fn declareIds(comptime namespace: []const u8, comptime tags: anytype) type {
    if (namespace.len == 0) @compileError("declareIds namespace must not be empty");
    const tags_type_info = @typeInfo(@TypeOf(tags));
    if (tags_type_info != .@"struct" or !tags_type_info.@"struct".is_tuple) {
        @compileError("declareIds requires a namespace and tuple of string literals");
    }
    const len = tags_type_info.@"struct".fields.len;

    comptime var field_names: [len][]const u8 = undefined;
    comptime var field_types: [len]type = undefined;
    comptime var field_attrs: [len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (0..len) |i| {
        const name: []const u8 = tags[i];
        const Holder = struct {
            const v: NodeId = stableNodeId(namespace, name);
        };
        field_names[i] = name;
        field_types[i] = NodeId;
        field_attrs[i] = .{ .default_value_ptr = @ptrCast(&Holder.v) };
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

pub inline fn bindTag(
    comptime MessageT: type,
    comptime ValueT: type,
    comptime tag: anytype,
) *const fn (ValueT, ?*const anyopaque) MessageT {
    const tag_name = @tagName(tag);
    return struct {
        fn handler(value: ValueT, _: ?*const anyopaque) MessageT {
            return @unionInit(MessageT, tag_name, value);
        }
    }.handler;
}

pub inline fn bindStatic(
    comptime MessageT: type,
    comptime ValueT: type,
    comptime msg: MessageT,
) *const fn (ValueT, ?*const anyopaque) MessageT {
    return struct {
        fn handler(_: ValueT, _: ?*const anyopaque) MessageT {
            return msg;
        }
    }.handler;
}

fn stableNodeId(comptime namespace: []const u8, comptime name: []const u8) NodeId {
    var hasher = std.hash.Wyhash.init(0xdec1ec1d);
    hasher.update(namespace);
    hasher.update(&.{0});
    hasher.update(name);
    return @truncate(hasher.final());
}

pub fn For(comptime MessageT: type) type {
    return struct {
        pub const Message = MessageT;
        pub const UIContext = @import("ui/context.zig").UIContext(MessageT);
        pub const Node = @import("ui/node.zig").Node(MessageT);
        pub const InteractionMessage = @import("ui/types.zig").InteractionMessage(MessageT);
        pub const InteractionRegistry = @import("ui/interaction.zig").InteractionRegistry(MessageT);
        pub const EventBinding = @import("ui/types.zig").EventBinding(MessageT);
        pub const Uix = @import("ui/uix.zig").Builder(MessageT);
    };
}

test {
    _ = @import("ui/layout.zig");
    _ = @import("ui/node.zig");
    _ = @import("ui/context.zig");
    _ = @import("ui/tw.zig");
    _ = @import("ui/uix.zig");
    _ = @import("state.zig");
    _ = @import("managed_app.zig");
    _ = @import("runtime.zig");
    _ = @import("renderer/vulkan/surface.zig");
    _ = @import("platform/backend.zig");
    _ = @import("platform/glfw_backend.zig");
    _ = @import("platform/x11_backend.zig");
    _ = @import("platform/win32_backend.zig");
    _ = @import("ui/components/root.zig");
    _ = @import("ui/components/plot.zig");
    _ = @import("animation/easing.zig");
    _ = @import("audio/spectrum.zig");
    _ = @import("renderer/shader_compiler.zig");
}

test "declareIds scopes stable ids by namespace" {
    const A = declareIds("tests.a", .{ "root", "button" }){};
    const B = declareIds("tests.b", .{ "root", "button" }){};
    const A2 = declareIds("tests.a", .{ "root", "button" }){};

    try std.testing.expectEqual(A.root, A2.root);
    try std.testing.expect(A.root != B.root);
    try std.testing.expect(A.button != B.button);
}
