const std = @import("std");
const Node = @import("node.zig").Node;
const QuadBatcher = @import("../renderer/vulkan/batcher.zig").QuadBatcher;
const TextLayouter = @import("../renderer/font/text_layouter.zig").TextLayouter;
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const FontSystem = @import("../renderer/font/font_system.zig").FontSystem;
const FontVariant = @import("../renderer/font/font_registry.zig").FontVariant;
const weightAndStyleToVariant = @import("../renderer/font/font_system.zig").weightAndStyleToVariant;
const layout = @import("layout.zig");
const InteractionRegistry = @import("interaction.zig").InteractionRegistry;
const NodeId = @import("types.zig").NodeId;
const AnimationRegistry = @import("../animation/registry.zig").AnimationRegistry;
const ImageFallbackState = @import("node.zig").RenderPayload.ImageFallbackState;
const AnimatedState = @import("../renderer/image_animation.zig").AnimatedState;
const Canvas = @import("../renderer/canvas.zig").Canvas;
const paint_context_mod = @import("paint_context.zig");
const bench_prefetch = @import("bench_prefetch.zig");
const components_module = @import("components/root.zig");
const uix_module = @import("uix.zig");
const theme_lib = @import("../ui/theme.zig");
const freeEventPayloads = @import("node.zig").freeEventPayloads;
const RichTextSpan = @import("node.zig").RichTextSpan;

const types = @import("types.zig");

const Style = layout.Style;

pub const UpdateAction = enum {
    none,
    repaint,
    relayout,
    rebuild,
};

const FontCacheKey = struct {
    family_hash: u64,
    weight: layout.FontWeight,
    style: layout.FontStyle,
};

pub const ScrollAlignment = enum {
    nearest,
    top,
    bottom,
    center,
};

pub const ScrollOptions = struct {
    align_y: ScrollAlignment = .nearest,
    align_x: ScrollAlignment = .nearest,
    scroll_margin: f32 = 0.0,
};

pub fn UIContext(comptime MessageT: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        root: *Node(MessageT),

        active_theme: theme_lib.Theme,
        default_font: ?*FontData = null,
        font_system: ?*FontSystem = null,
        default_family: ?[]const u8 = null,
        needs_redraw: bool = true,

        id_map: std.AutoHashMap(NodeId, *Node(MessageT)),
        portal_list: std.ArrayList(*Node(MessageT)),

        interaction_registry: InteractionRegistry(MessageT),
        animation_registry: AnimationRegistry,

        post_layout_hooks: std.ArrayList(PostLayoutHook),

        layout_dirty: bool = true,
        paint_dirty: bool = true,

        view_zoom: f32 = 1.0,

        building: bool = false,

        current_time: f64 = 0.0,
        delta_time: f64 = 0.0,

        build_arena: std.heap.ArenaAllocator,
        post_layout_arena: std.heap.ArenaAllocator,

        use_arena: bool = false,

        image_resolver: ?ImageResolver = null,
        image_loader: ?ImageLoader = null,
        icon_resolver: ?IconResolver = null,

        has_animated_images: bool = false,
        min_animated_frame_ms: u32 = 0,

        continuous_render_requested: bool = false,

        font_cache: std.AutoHashMapUnmanaged(FontCacheKey, *FontData) = .empty,

        node_pool: std.heap.MemoryPool(Node(MessageT)) = .empty,

        traversal: std.ArrayList(*Node(MessageT)) = .empty,
        traversal_dirty: bool = true,

        on_node_destroyed: ?*const fn (*anyopaque, *Node(MessageT)) void = null,
        on_node_destroyed_ctx: *anyopaque = undefined,

        recon_scratch_pool: std.ArrayList(*Scratch) = .empty,

        const Scratch = struct {
            id_map: std.AutoHashMapUnmanaged(NodeId, usize) = .empty,
            children: std.ArrayList(*Node(MessageT)) = .empty,
        };

        const ScrollHookData = struct {
            container_id: NodeId,
            target_id: NodeId,
            options: ScrollOptions,
        };

        fn scrollIntoViewCallback(ctx: *Self, userdata: *anyopaque) bool {
            const data: *ScrollHookData = @ptrCast(@alignCast(userdata));

            const container = ctx.getById(data.container_id) orelse return false;
            const target = ctx.getById(data.target_id) orelse return false;

            return applyScrollIntoView(container, target, data.options);
        }

        fn applyScrollIntoView(container: *Node(MessageT), target: *Node(MessageT), options: ScrollOptions) bool {
            const rel_x = target.layout_result.x - container.layout_result.x + container.scroll_x;
            const rel_y = target.layout_result.y - container.layout_result.y + container.scroll_y;

            const viewport_w = container.layout_result.width;
            const viewport_h = container.layout_result.height;
            const m = options.scroll_margin;

            var changed = false;

            if (viewport_h > 0.0) {
                var next_y = container.scroll_y;
                const target_h = target.layout_result.height;

                switch (options.align_y) {
                    .nearest => {
                        if (rel_y < container.scroll_y + m) {
                            next_y = rel_y - m;
                        } else if (rel_y + target_h > container.scroll_y + viewport_h - m) {
                            next_y = rel_y + target_h - viewport_h + m;
                        }
                    },
                    .top => next_y = rel_y - m,
                    .bottom => next_y = rel_y + target_h - viewport_h + m,
                    .center => next_y = rel_y + (target_h * 0.5) - (viewport_h * 0.5),
                }

                const max_y = @max(0.0, container.layout_result.content_height - viewport_h);
                next_y = std.math.clamp(next_y, 0.0, max_y);
                if (@abs(next_y - container.scroll_y) > 0.5) {
                    container.scroll_y = next_y;
                    changed = true;
                }
            }

            if (viewport_w > 0.0) {
                var next_x = container.scroll_x;
                const target_w = target.layout_result.width;

                switch (options.align_x) {
                    .nearest => {
                        if (rel_x < container.scroll_x + m) {
                            next_x = rel_x - m;
                        } else if (rel_x + target_w > container.scroll_x + viewport_w - m) {
                            next_x = rel_x + target_w - viewport_w + m;
                        }
                    },
                    .top => next_x = rel_x - m,
                    .bottom => next_x = rel_x + target_w - viewport_w + m,
                    .center => next_x = rel_x + (target_w * 0.5) - (viewport_w * 0.5),
                }

                const max_x = @max(0.0, container.layout_result.content_width - viewport_w);
                next_x = std.math.clamp(next_x, 0.0, max_x);
                if (@abs(next_x - container.scroll_x) > 0.5) {
                    container.scroll_x = next_x;
                    changed = true;
                }
            }

            if (changed) {
                container.markPositionDirty();
            }
            return changed;
        }

        pub fn scrollIntoView(
            self: *Self,
            container_id: NodeId,
            target_id: NodeId,
            options: ScrollOptions,
        ) !void {
            const allocator = self.post_layout_arena.allocator();
            const data = try allocator.create(ScrollHookData);
            data.* = .{
                .container_id = container_id,
                .target_id = target_id,
                .options = options,
            };

            try self.registerPostLayoutHook(.{
                .userdata = data,
                .callback = scrollIntoViewCallback,
            });
        }

        fn acquireScratch(self: *@This()) !*Scratch {
            if (self.recon_scratch_pool.pop()) |s| {
                s.id_map.clearRetainingCapacity();
                s.children.clearRetainingCapacity();
                return s;
            }
            const s = try self.gpa.create(Scratch);
            s.* = .{};
            return s;
        }

        fn releaseScratch(self: *@This(), s: *Scratch) void {
            self.recon_scratch_pool.append(self.gpa, s) catch {
                s.id_map.deinit(self.gpa);
                s.children.deinit(self.gpa);
                self.gpa.destroy(s);
            };
        }

        pub const PostLayoutHook = struct {
            userdata: *anyopaque,
            callback: *const fn (ctx: *UIContext(MessageT), userdata: *anyopaque) bool,
        };

        pub const ImageResolver = struct {
            context: *anyopaque,
            getTexId: *const fn (ctx: *anyopaque, source: []const u8) u32,
            getResolvedState: *const fn (ctx: *anyopaque, source: []const u8) ImageFallbackState,
            getAnimation: *const fn (ctx: *anyopaque, source: []const u8) ?*const AnimatedState,
        };

        pub const ImageLoader = struct {
            context: *anyopaque,
            loadFromDisk: *const fn (ctx: *anyopaque, name: []const u8, path: []const u8, max_bytes: usize) void,
            getSize: *const fn (ctx: *anyopaque, name: []const u8) ?[2]u32,
        };

        pub const IconResolver = struct {
            context: *anyopaque,
            getTexId: *const fn (ctx: *anyopaque, icon_id: u32, scale: f32) ?u32,
        };

        pub fn init(child_allocator: std.mem.Allocator, initial_theme: theme_lib.Theme) !@This() {
            var node_pool: std.heap.MemoryPool(Node(MessageT)) = .empty;
            errdefer node_pool.deinit(child_allocator);
            const root = try node_pool.create(child_allocator);
            root.* = Node(MessageT).init();
            root.allocator = child_allocator;

            return @This(){
                .gpa = child_allocator,
                .root = root,
                .node_pool = node_pool,
                .active_theme = initial_theme,
                .needs_redraw = true,
                .id_map = std.AutoHashMap(NodeId, *Node(MessageT)).init(child_allocator),
                .portal_list = std.ArrayList(*Node(MessageT)).empty,
                .interaction_registry = InteractionRegistry(MessageT).init(child_allocator),
                .animation_registry = AnimationRegistry.init(child_allocator),
                .post_layout_hooks = std.ArrayList(PostLayoutHook).empty,
                .build_arena = std.heap.ArenaAllocator.init(child_allocator),
                .post_layout_arena = std.heap.ArenaAllocator.init(child_allocator),
            };
        }

        pub fn setTheme(self: *Self, new_theme: theme_lib.Theme) void {
            self.active_theme = new_theme;
            self.needs_redraw = true;
        }

        pub fn toggleDarkMode(self: *Self) void {
            self.active_theme.switchMode();
            self.needs_redraw = true;
        }

        pub fn components(self: *Self) components_module.Builder(MessageT) {
            return .{ .ui = self };
        }

        pub fn ux(self: *Self) uix_module.Builder(MessageT) {
            return uix_module.builder(MessageT, self);
        }

        pub fn scopedUx(self: *Self, comptime LocalMessageT: type, comptime parent_tag: anytype) uix_module.ScopedBuilder(MessageT, LocalMessageT, parent_tag) {
            return uix_module.scopedBuilder(MessageT, LocalMessageT, parent_tag, self);
        }

        pub fn setDefaultFont(self: *Self, font: *FontData) void {
            self.default_font = font;
        }

        pub fn getDefaultFont(self: *Self) ?*FontData {
            return self.default_font;
        }

        pub fn setFontSystem(self: *Self, fs: *FontSystem) void {
            self.font_system = fs;
            self.font_cache.clearRetainingCapacity();
        }

        pub fn setDefaultFamily(self: *Self, family_name: []const u8) void {
            self.default_family = family_name;
            self.font_cache.clearRetainingCapacity();
        }

        fn resolveDefaultFont(self: *Self) ?*FontData {
            if (self.font_system) |fs| {
                if (self.default_family) |family| {
                    if (fs.closestVariant(family, .regular)) |physical| {
                        if (fs.getFont(physical)) |font| return font;
                    }
                }
            }
            return self.default_font;
        }

        fn resolveFont(self: *Self, font: ?*FontData) !*FontData {
            return font orelse self.resolveDefaultFont() orelse error.DefaultFontMissing;
        }

        fn resolveFontFromStyle(self: *Self, font: ?*FontData, style: *const Style) !*FontData {
            if (font) |f| return f;
            const default = self.resolveDefaultFont() orelse return error.DefaultFontMissing;
            if (style.font_weight == .normal and style.font_style == .normal and style.font_family == null) {
                return default;
            }
            const key = FontCacheKey{
                .family_hash = if (style.font_family) |f| std.hash.Wyhash.hash(0, f) else 0,
                .weight = style.font_weight,
                .style = style.font_style,
            };
            if (self.font_cache.get(key)) |cached| return cached;
            const resolved = blk: {
                const fs = self.font_system orelse break :blk default;
                const family = style.font_family orelse self.default_family orelse break :blk default;
                const variant = weightAndStyleToVariant(style.font_weight, style.font_style);
                const physical = fs.closestVariant(family, variant) orelse break :blk default;
                break :blk fs.getFont(physical) orelse default;
            };
            self.font_cache.put(self.gpa, key, resolved) catch {};
            return resolved;
        }

        pub fn measureTextWidth(self: *Self, style: *const Style, content: []const u8) f32 {
            if (content.len == 0) return 0;
            const fs = self.font_system orelse return 0;
            const font = self.resolveFontFromStyle(null, style) catch return 0;
            const res = fs.text_layouter.measureTextCached(self.gpa, font, content, .{
                .font_size = style.font_size,
                .wrap = false,
            });
            self.gpa.free(res.metrics);
            return res.width;
        }

        fn registerNodeId(self: *@This(), node: *Node(MessageT), id: ?NodeId) !void {
            if (id) |stable_id| {
                node.id = stable_id;
                if (!self.building) {
                    try self.id_map.put(stable_id, node);
                }
            }
        }

        pub fn resetTreeDestructive(self: *@This()) !*Node(MessageT) {
            self.interaction_registry.resetForNewTree();
            self.id_map.clearRetainingCapacity();
            self.portal_list.clearRetainingCapacity();
            self.post_layout_hooks.clearRetainingCapacity();

            if (self.on_node_destroyed) |hook| hook(self.on_node_destroyed_ctx, self.root);
            self.destroyTree(self.root);

            const root = try self.node_pool.create(self.gpa);
            root.* = Node(MessageT).init();
            root.allocator = self.gpa;
            self.root = root;
            self.traversal_dirty = true;

            return self.root;
        }

        pub fn mountRoot(self: *@This(), new_root: *Node(MessageT)) !void {
            self.interaction_registry.resetForNewTree();
            self.portal_list.clearRetainingCapacity();

            if (self.on_node_destroyed) |hook| hook(self.on_node_destroyed_ctx, self.root);
            self.destroyTree(self.root);
            self.id_map.clearRetainingCapacity();

            self.root = promoteToGPA(MessageT, self, new_root) catch |err| {
                const empty = try self.node_pool.create(self.gpa);
                empty.* = Node(MessageT).init();
                empty.allocator = self.gpa;
                self.root = empty;
                return err;
            };
            self.root.parent = null;
            new_root.deinit();

            self.traversal_dirty = true;
            self.layout_dirty = true;
            self.paint_dirty = true;
        }

        pub fn createNode(self: *@This()) !*Node(MessageT) {
            const alloc = if (self.use_arena) self.build_arena.allocator() else self.gpa;
            const node = try alloc.create(Node(MessageT));
            node.* = Node(MessageT).init();
            node.allocator = alloc;
            return node;
        }

        pub const NodeDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            children: []const ?*Node(MessageT) = &.{},

            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const ImageDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            tex_id: u32,
            tint: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
            intrinsic_size: [2]f32 = .{ 0.0, 0.0 },
            custom_params: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
            alt_text: []const u8 = "",
            alt_font: ?*FontData = null,
            fallback_state: ImageFallbackState = .ready,
            animation: ?*const AnimatedState = null,
            start_time: f64 = 0.0,
            children: []const ?*Node(MessageT) = &.{},

            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const CustomPaintDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            paint_fn: paint_context_mod.PaintFn,
            // borrowed; must outlive the frame
            userdata: ?*const anyopaque = null,
            revision: u64 = 0,
            children: []const ?*Node(MessageT) = &.{},
            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const CanvasDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            target: *Canvas,
            tint: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
            custom_params: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
            pan_x: f32 = 0.0,
            pan_y: f32 = 0.0,
            zoom: f32 = 1.0,
            children: []const ?*Node(MessageT) = &.{},

            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const AsyncImageDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            source: []const u8,
            tint: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
            intrinsic_size: [2]f32 = .{ 0.0, 0.0 },

            custom_params: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
            alt_text: []const u8 = "",
            alt_font: ?*FontData = null,
            children: []const ?*Node(MessageT) = &.{},

            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const TextDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            content: []const u8,
            font: ?*FontData = null,
            max_width: f32 = 0.0,

            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const RichTextDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            content: []const u8,
            spans: []const RichTextSpan = &.{},
            font: ?*FontData = null,
            max_width: f32 = 0.0,
            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const ButtonDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            label: []const u8,
            font: ?*FontData = null,
            label_max_width: f32 = 0.0,
            label_style: Style = .{},

            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const TextInputDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            font: ?*FontData = null,
            max_width: f32 = 0.0,
            initial_text: []const u8 = "",
            placeholder: []const u8 = "",
            placeholder_color: ?layout.Color = null,

            events: []const types.EventBinding(MessageT) = &.{},
        };

        pub const TextAreaDescriptor = struct {
            id: ?NodeId = null,
            style: Style = .{},
            font: ?*FontData = null,
            max_width: f32 = 0.0,
            initial_text: []const u8 = "",

            events: []const types.EventBinding(MessageT) = &.{},
        };

        fn addDescriptorChildren(node: *Node(MessageT), children: []const ?*Node(MessageT)) !void {
            for (children) |maybe_child| {
                if (maybe_child) |child| {
                    try node.addChild(child);
                }
            }
        }

        pub fn div(self: *@This(), desc: NodeDescriptor) !*Node(MessageT) {
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .container;
            try addDescriptorChildren(node, desc.children);
            return node;
        }

        pub fn portal(self: *@This(), desc: NodeDescriptor) !*Node(MessageT) {
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            node.style.position = .absolute;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .portal;
            try addDescriptorChildren(node, desc.children);
            return node;
        }

        pub fn image(self: *@This(), desc: ImageDescriptor) !*Node(MessageT) {
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .{
                .image = .{
                    .tex_id = desc.tex_id,
                    .tint = desc.tint,
                    .intrinsic_size = desc.intrinsic_size,
                    .custom_params = desc.custom_params,
                    .alt_text = try node.allocator.dupe(u8, desc.alt_text),
                    .alt_font = desc.alt_font,
                    .fallback_state = desc.fallback_state,
                    .animation = desc.animation,
                    .start_time = desc.start_time,
                },
            };
            if (desc.animation) |anim| {
                self.has_animated_images = true;
                for (anim.frames) |frame| {
                    if (frame.delay_ms == 0) continue;
                    if (self.min_animated_frame_ms == 0 or frame.delay_ms < self.min_animated_frame_ms) {
                        self.min_animated_frame_ms = frame.delay_ms;
                    }
                }
            }
            try addDescriptorChildren(node, desc.children);
            return node;
        }

        pub fn customPaint(self: *@This(), desc: CustomPaintDescriptor) !*Node(MessageT) {
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .{
                .custom_paint = .{
                    .paint_fn = desc.paint_fn,
                    .userdata = desc.userdata,
                    .revision = desc.revision,
                },
            };
            try addDescriptorChildren(node, desc.children);
            return node;
        }

        pub fn canvas(self: *@This(), desc: CanvasDescriptor) !*Node(MessageT) {
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .{
                .canvas = .{
                    .target = desc.target,
                    .tint = desc.tint,
                    .custom_params = desc.custom_params,
                    .pan_x = desc.pan_x,
                    .pan_y = desc.pan_y,
                    .zoom = desc.zoom,
                },
            };
            try addDescriptorChildren(node, desc.children);
            return node;
        }

        pub fn asyncImage(self: *@This(), desc: AsyncImageDescriptor) !*Node(MessageT) {
            const resolver = self.image_resolver orelse
                return error.ImageResolverNotWired;

            const tex_id = resolver.getTexId(resolver.context, desc.source);
            const fallback = resolver.getResolvedState(resolver.context, desc.source);
            const animation = resolver.getAnimation(resolver.context, desc.source);

            return self.image(.{
                .id = desc.id,
                .style = desc.style,
                .tex_id = tex_id,
                .tint = desc.tint,
                .intrinsic_size = desc.intrinsic_size,
                .custom_params = desc.custom_params,
                .alt_text = desc.alt_text,
                .alt_font = desc.alt_font,
                .fallback_state = fallback,
                .animation = animation,
                .start_time = self.current_time,
                .children = desc.children,
                .events = desc.events,
            });
        }

        pub fn text(self: *@This(), desc: TextDescriptor) !*Node(MessageT) {
            const font = try self.resolveFontFromStyle(desc.font, &desc.style);
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .{
                .text = .{
                    .content = try node.allocator.dupe(u8, desc.content),
                    .font = font,
                    .max_width = desc.max_width,
                },
            };
            return node;
        }

        pub fn richText(self: *@This(), desc: RichTextDescriptor) !*Node(MessageT) {
            const font = try self.resolveFontFromStyle(desc.font, &desc.style);
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .{ .rich_text = .{
                .content = try node.allocator.dupe(u8, desc.content),
                .font = font,
                .max_width = desc.max_width,
                .spans = try node.allocator.dupe(RichTextSpan, desc.spans),
            } };
            return node;
        }

        pub fn fragment(self: *@This(), children: []const ?*Node(MessageT)) !*Node(MessageT) {
            const node = try self.createNode();
            node.payload = .fragment;
            try addDescriptorChildren(node, children);
            return node;
        }

        pub fn button(self: *@This(), desc: ButtonDescriptor) !*Node(MessageT) {
            const font = try self.resolveFontFromStyle(desc.font, &desc.label_style);
            var container_style = desc.style;

            if (container_style.background_color.a == 0) {
                container_style.background_color = self.active_theme.tokens.action_default;
                container_style.hover_color = self.active_theme.tokens.action_hover;
            }

            if (container_style.cursor == null) {
                container_style.cursor = .pointer;
            }

            var label_style = desc.label_style;
            label_style.pointer_events = .none;

            if (label_style.text_color.a == 0) {
                label_style.text_color = self.active_theme.tokens.text_inverse;
            }

            const label_node = try self.text(.{
                .style = label_style,
                .content = desc.label,
                .font = font,
                .max_width = desc.label_max_width,
            });

            const container = try self.createNode();
            try self.registerNodeId(container, desc.id);

            container.style = container_style;
            if (desc.events.len > 0) {
                container.events = try container.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            container.payload = .container;

            try container.addChild(label_node);

            return container;
        }

        pub fn textInput(self: *@This(), desc: TextInputDescriptor) !*Node(MessageT) {
            const font = try self.resolveFontFromStyle(desc.font, &desc.style);
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            node.is_focusable = true;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .{
                .text_input = .{
                    .buffer = std.ArrayList(u8).empty,
                    .cursor_index = 0,
                    .font = font,
                    .max_width = desc.max_width,
                    .placeholder = desc.placeholder,
                    .placeholder_color = desc.placeholder_color,
                },
            };

            if (desc.initial_text.len > 0) {
                try node.payload.text_input.buffer.appendSlice(node.allocator, desc.initial_text);
                node.payload.text_input.cursor_index = node.payload.text_input.buffer.items.len;
            }

            return node;
        }

        pub fn textArea(self: *@This(), desc: TextAreaDescriptor) !*Node(MessageT) {
            const font = try self.resolveFontFromStyle(desc.font, &desc.style);
            const node = try self.createNode();
            try self.registerNodeId(node, desc.id);
            node.style = desc.style;
            node.is_focusable = true;
            node.clip_children = true;
            if (desc.events.len > 0) {
                node.events = try node.allocator.dupe(types.EventBinding(MessageT), desc.events);
            }
            node.payload = .{
                .text_area = .{
                    .buffer = std.ArrayList(u8).empty,
                    .cursor_index = 0,
                    .font = font,
                    .max_width = desc.max_width,
                },
            };

            if (desc.initial_text.len > 0) {
                try node.payload.text_area.buffer.appendSlice(node.allocator, desc.initial_text);
                node.payload.text_area.cursor_index = node.payload.text_area.buffer.items.len;
            }

            return node;
        }

        pub fn render(
            self: *@This(),
            batcher: *QuadBatcher,
            text_layouter: *TextLayouter,
            time: f32,
        ) !void {
            try self.root.render(batcher, text_layouter, time);
            try batcher.resetScissorToRoot();
            for (self.portal_list.items) |portal_node| {
                try portal_node.renderPortal(batcher, text_layouter, time);
            }
        }

        pub fn calculateLayout(
            self: *@This(),
            text_layouter: *TextLayouter,
            viewport_width: f32,
            viewport_height: f32,
        ) !void {
            layout.active_zoom = self.view_zoom;
            try self.ensureTraversal();
            layout.measureNode(self.root, text_layouter, viewport_width, viewport_height, true);
            layout.arrangeNode(self.root, 0.0, 0.0);
            self.portal_list.clearRetainingCapacity();
            try self.collectPortals();
            self.interaction_registry.portals = self.portal_list.items;
            for (self.portal_list.items) |portal_node| {
                layout.measureNode(portal_node, text_layouter, viewport_width, viewport_height, true);
                layout.arrangeNode(portal_node, 0.0, 0.0);
            }
            self.resolveAnchors();

            var needs_second_pass = false;
            for (self.post_layout_hooks.items) |hook| {
                if (hook.callback(self, hook.userdata)) {
                    needs_second_pass = true;
                }
            }
            self.post_layout_hooks.clearRetainingCapacity();
            _ = self.post_layout_arena.reset(.retain_capacity);

            if (needs_second_pass) {
                self.layout_dirty = true;
                self.paint_dirty = true;
            }
        }

        pub fn registerPostLayoutHook(self: *@This(), hook: PostLayoutHook) !void {
            try self.post_layout_hooks.append(self.gpa, hook);
        }

        fn resolveAnchors(self: *@This()) void {
            for (self.portal_list.items) |portal_node| {
                self.resolveNodeAnchors(portal_node);
            }
        }

        fn resolveNodeAnchors(self: *@This(), node: *Node(MessageT)) void {
            if (node.style.position == .anchored) {
                if (node.style.anchor_id) |anchor_id| {
                    if (self.getById(anchor_id)) |anchor| {
                        if (node.style.anchor_match_width and node.layout_result.width != anchor.layout_result.width) {
                            node.layout_result.width = anchor.layout_result.width;
                            node.flags.position = true;
                            layout.arrangeNode(node, node.layout_result.x, node.layout_result.y);
                        }
                        const target_x = anchor.layout_result.x + (node.style.left orelse 0.0);
                        var target_y = anchor.layout_result.y + anchor.layout_result.height + (node.style.top orelse 0.0);
                        const viewport_h = self.root.layout_result.height;
                        if (target_y + node.layout_result.height > viewport_h) {
                            target_y = anchor.layout_result.y - node.layout_result.height - (node.style.bottom orelse 0.0);
                        }
                        const dx = target_x - node.layout_result.x;
                        const dy = target_y - node.layout_result.y;
                        if (dx != 0.0 or dy != 0.0) {
                            layout.translateSubTree(node, dx, dy);
                        }
                    }
                }
            }
            for (node.children.items) |child| {
                self.resolveNodeAnchors(child);
            }
        }

        fn collectPortals(self: *@This()) !void {
            for (self.traversal.items, 0..) |node, i| {
                prefetchNodeIfEnabled(MessageT, self.traversal.items, i);
                if (node.payload == .portal) {
                    try self.portal_list.append(self.gpa, node);
                }
            }
        }

        pub fn applyAnimations(self: *@This(), current_time: f64) void {
            self.ensureTraversal() catch {
                self.animation_registry.applyAnimatedValuesToTree(self.root, current_time);
                return;
            };
            self.animation_registry.applyAnimatedValuesFlat(self.traversal.items, current_time);
        }

        pub fn requestLayout(self: *@This()) void {
            self.layout_dirty = true;
            self.paint_dirty = true;
        }

        fn markSubtreeDirty(node: *Node(MessageT)) void {
            node.flags = .{ .position = true, .size = true, .content = true };
            for (node.children.items) |child| markSubtreeDirty(child);
        }

        pub fn setZoom(self: *@This(), zoom: f32) void {
            const clamped = @max(0.1, @min(zoom, 10.0));
            if (self.view_zoom == clamped) return;
            self.view_zoom = clamped;
            markSubtreeDirty(self.root);
            self.layout_dirty = true;
            self.paint_dirty = true;
        }

        pub fn requestPaint(self: *@This()) void {
            self.paint_dirty = true;
        }

        pub fn requestContinuousRender(self: *@This()) void {
            self.continuous_render_requested = true;
        }

        pub fn getById(self: *@This(), id: NodeId) ?*Node(MessageT) {
            return self.id_map.get(id);
        }

        pub fn requestFocus(self: *@This(), id: NodeId) void {
            self.interaction_registry.requestFocus(id);
        }

        pub fn isDragging(self: *const @This()) bool {
            return self.interaction_registry.is_dragging;
        }

        pub fn scrollChangedThisFrame(self: *const @This()) bool {
            return self.interaction_registry.scroll_changed;
        }

        /// Thread-safe; drained at the top of the next reducer pass.
        pub fn postExternalMessage(self: *@This(), msg: types.InteractionMessage(MessageT)) void {
            self.interaction_registry.postExternalMessage(msg);
        }

        /// Borrowed slice; valid until the next rebuild rewrites the buffer.
        pub fn getInputText(self: *@This(), id: NodeId) ?[]const u8 {
            const node = self.id_map.get(id) orelse return null;
            return switch (node.payload) {
                .text_input => |ti| ti.buffer.items,
                .text_area => |ta| ta.buffer.items,
                else => null,
            };
        }

        /// Cursor lands at end of new text.
        pub fn setInputText(self: *@This(), id: NodeId, content: []const u8) !void {
            const node = self.id_map.get(id) orelse return;
            switch (node.payload) {
                .text_input => |*ti| {
                    ti.buffer.clearRetainingCapacity();
                    try ti.buffer.appendSlice(node.allocator, content);
                    ti.cursor_index = ti.buffer.items.len;
                    ti.selection_anchor = null;
                    node.markDirty();
                    self.layout_dirty = true;
                    self.paint_dirty = true;
                },
                .text_area => |*ta| {
                    ta.buffer.clearRetainingCapacity();
                    try ta.buffer.appendSlice(node.allocator, content);
                    ta.cursor_index = ta.buffer.items.len;
                    ta.selection_anchor = null;
                    node.markDirty();
                    self.layout_dirty = true;
                    self.paint_dirty = true;
                },
                else => {},
            }
        }

        pub fn reconcile(self: *@This(), new_root: *Node(MessageT)) !void {
            try reconcileNode(MessageT, self, self.root, new_root);
            if (self.root.id) |id| try self.id_map.put(id, self.root);
            _ = self.build_arena.reset(.retain_capacity);
            self.layout_dirty = true;
            self.paint_dirty = true;
        }

        pub fn deinit(self: *@This()) void {
            self.animation_registry.deinit();
            self.interaction_registry.deinit();
            self.id_map.deinit();
            self.portal_list.deinit(self.gpa);
            self.post_layout_hooks.deinit(self.gpa);
            self.font_cache.deinit(self.gpa);
            for (self.recon_scratch_pool.items) |s| {
                s.id_map.deinit(self.gpa);
                s.children.deinit(self.gpa);
                self.gpa.destroy(s);
            }
            self.recon_scratch_pool.deinit(self.gpa);
            self.traversal.deinit(self.gpa);
            self.destroyTree(self.root);
            self.node_pool.deinit(self.gpa);
            self.build_arena.deinit();
            self.post_layout_arena.deinit();
        }

        fn destroyTree(self: *@This(), node: *Node(MessageT)) void {
            for (node.children.items) |child| {
                self.destroyTree(child);
            }
            node.freeOwn();
            node.children.deinit(node.allocator);
            self.node_pool.destroy(node);
        }

        fn ensureTraversal(self: *@This()) !void {
            if (!self.traversal_dirty) return;
            self.traversal.clearRetainingCapacity();
            try appendPreorder(MessageT, &self.traversal, self.gpa, self.root);
            self.traversal_dirty = false;
        }
    };
}

fn appendPreorder(comptime MessageT: type, list: *std.ArrayList(*Node(MessageT)), gpa: std.mem.Allocator, node: *Node(MessageT)) std.mem.Allocator.Error!void {
    try list.append(gpa, node);
    for (node.children.items) |child| {
        try appendPreorder(MessageT, list, gpa, child);
    }
}

fn promoteToGPA(comptime MessageT: type, ctx: *UIContext(MessageT), desc: *Node(MessageT)) std.mem.Allocator.Error!*Node(MessageT) {
    const node = try ctx.node_pool.create(ctx.gpa);
    node.* = Node(MessageT).init();
    node.allocator = ctx.gpa;
    ctx.traversal_dirty = true;

    node.style = desc.style;
    node.clip_children = desc.clip_children;
    node.id = desc.id;
    if (desc.id) |stable_id| {
        try ctx.id_map.put(stable_id, node);
    }
    node.child_memo_key = desc.child_memo_key;
    node.flags = .{};
    node.is_focusable = desc.is_focusable;
    node.lock_pointer_on_drag = desc.lock_pointer_on_drag;
    node.hit_byte_start = desc.hit_byte_start;
    node.hit_byte_end = desc.hit_byte_end;
    node.hit_test_kind = desc.hit_test_kind;
    node.scroll_x = desc.scroll_x;
    node.scroll_y = desc.scroll_y;
    node.prev_desc_scroll_x = desc.scroll_x;
    node.prev_desc_scroll_y = desc.scroll_y;

    if (desc.events.len > 0) {
        node.events = try ctx.gpa.dupe(types.EventBinding(MessageT), desc.events);
        for (@constCast(desc.events)) |*binding| binding.destroy_userdata = null;
    }

    switch (desc.payload) {
        .none => node.payload = .none,
        .fragment => node.payload = .fragment,
        .container => node.payload = .container,
        .portal => node.payload = .portal,
        .image => |img| node.payload = .{ .image = .{
            .tex_id = img.tex_id,
            .tint = img.tint,
            .intrinsic_size = img.intrinsic_size,
            .custom_params = img.custom_params,
            .alt_text = try ctx.gpa.dupe(u8, img.alt_text),
            .alt_font = img.alt_font,
            .fallback_state = img.fallback_state,
            .animation = img.animation,
            .start_time = img.start_time,
        } },
        .canvas => |canvas_payload| node.payload = .{ .canvas = .{
            .target = canvas_payload.target,
            .tint = canvas_payload.tint,
            .custom_params = canvas_payload.custom_params,
            .pan_x = canvas_payload.pan_x,
            .pan_y = canvas_payload.pan_y,
            .zoom = canvas_payload.zoom,
        } },
        .text => |t| node.payload = .{ .text = .{
            .content = try ctx.gpa.dupe(u8, t.content),
            .font = t.font,
            .max_width = t.max_width,
        } },
        .rich_text => |rt| node.payload = .{ .rich_text = .{
            .content = try ctx.gpa.dupe(u8, rt.content),
            .font = rt.font,
            .max_width = rt.max_width,
            .spans = try ctx.gpa.dupe(RichTextSpan, rt.spans),
        } },
        .text_input => |*ti| {
            node.payload = .{ .text_input = .{
                .buffer = std.ArrayList(u8).empty,
                .cursor_index = ti.cursor_index,
                .selection_anchor = ti.selection_anchor,
                .font = ti.font,
                .max_width = ti.max_width,
                .placeholder = ti.placeholder,
                .placeholder_color = ti.placeholder_color,
            } };
            if (ti.buffer.items.len > 0) {
                try node.payload.text_input.buffer.appendSlice(ctx.gpa, ti.buffer.items);
            }
            node.is_focusable = true;
        },
        .text_area => |*ta| {
            node.payload = .{ .text_area = .{
                .buffer = std.ArrayList(u8).empty,
                .cursor_index = ta.cursor_index,
                .selection_anchor = ta.selection_anchor,
                .font = ta.font,
                .max_width = ta.max_width,
                .scroll_y = ta.scroll_y,
                .target_nav_x = ta.target_nav_x,
            } };
            if (ta.buffer.items.len > 0) {
                try node.payload.text_area.buffer.appendSlice(ctx.gpa, ta.buffer.items);
            }
            node.is_focusable = true;
        },
        .video => |v| node.payload = .{ .video = .{
            .playback = v.playback,
            .tint = v.tint,
            .custom_params = v.custom_params,
        } },
        .custom_paint => |cp| node.payload = .{ .custom_paint = .{
            .paint_fn = cp.paint_fn,
            .userdata = cp.userdata,
            .revision = cp.revision,
        } },
    }

    for (desc.children.items) |desc_child| {
        const promoted = try promoteToGPA(MessageT, ctx, desc_child);
        promoted.parent = node;
        try node.children.append(ctx.gpa, promoted);
    }

    return node;
}

fn richTextSpansEqual(a: []const RichTextSpan, b: []const RichTextSpan) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (!std.meta.eql(lhs, rhs)) return false;
    }
    return true;
}

fn patchPayload(comptime MessageT: type, retained: *Node(MessageT), desc: *Node(MessageT)) std.mem.Allocator.Error!void {
    const retained_tag = std.meta.activeTag(retained.payload);
    const desc_tag = std.meta.activeTag(desc.payload);
    const type_changed = retained_tag != desc_tag;

    if (type_changed) {
        switch (retained.payload) {
            .text => |t| retained.allocator.free(t.content),
            .rich_text => |rt| {
                retained.allocator.free(rt.content);
                retained.allocator.free(rt.spans);
            },
            .image => |img| retained.allocator.free(img.alt_text),
            .text_input => |*ti| ti.buffer.deinit(retained.allocator),
            .text_area => |*ta| ta.buffer.deinit(retained.allocator),
            else => {},
        }
        retained.layout_result.text_cache.clear(retained.allocator);
        retained.markContentDirty();
    }

    switch (desc.payload) {
        .none => retained.payload = .none,
        .fragment => retained.payload = .fragment,
        .container => retained.payload = .container,
        .portal => retained.payload = .portal,
        .image => |img| {
            if (!type_changed) {
                const ri = &retained.payload.image;

                const size_changed = ri.intrinsic_size[0] != img.intrinsic_size[0] or
                    ri.intrinsic_size[1] != img.intrinsic_size[1];
                const state_changed = ri.fallback_state != img.fallback_state;

                if (ri.fallback_state == .ready and img.fallback_state != .ready) {} else {
                    ri.tex_id = img.tex_id;
                    ri.fallback_state = img.fallback_state;
                }

                ri.tex_id = img.tex_id;
                ri.tint = img.tint;
                ri.intrinsic_size = img.intrinsic_size;
                ri.custom_params = img.custom_params;
                ri.alt_font = img.alt_font;
                ri.fallback_state = img.fallback_state;

                if (size_changed or state_changed) {
                    retained.markSizeDirty();
                }

                const same_anim = ri.animation != null and ri.animation == img.animation;
                ri.animation = img.animation;
                if (!same_anim and img.animation != null) {
                    ri.start_time = img.start_time;
                }
                if (!std.mem.eql(u8, ri.alt_text, img.alt_text)) {
                    retained.allocator.free(ri.alt_text);
                    ri.alt_text = try retained.allocator.dupe(u8, img.alt_text);
                    retained.markContentDirty();
                }
            } else {
                retained.payload = .{ .image = .{
                    .tex_id = img.tex_id,
                    .tint = img.tint,
                    .intrinsic_size = img.intrinsic_size,
                    .custom_params = img.custom_params,
                    .alt_text = try retained.allocator.dupe(u8, img.alt_text),
                    .alt_font = img.alt_font,
                    .fallback_state = img.fallback_state,
                    .animation = img.animation,
                    .start_time = img.start_time,
                } };
            }
        },
        .canvas => |canvas_payload| {
            if (!type_changed) {
                const rc = &retained.payload.canvas;
                rc.target = canvas_payload.target;
                rc.tint = canvas_payload.tint;
                rc.custom_params = canvas_payload.custom_params;
                rc.pan_x = canvas_payload.pan_x;
                rc.pan_y = canvas_payload.pan_y;
                rc.zoom = canvas_payload.zoom;
            } else {
                retained.payload = .{ .canvas = .{
                    .target = canvas_payload.target,
                    .tint = canvas_payload.tint,
                    .custom_params = canvas_payload.custom_params,
                    .pan_x = canvas_payload.pan_x,
                    .pan_y = canvas_payload.pan_y,
                    .zoom = canvas_payload.zoom,
                } };
            }
        },
        .text => |*dt| {
            if (!type_changed) {
                const rt = &retained.payload.text;
                if (!std.mem.eql(u8, rt.content, dt.content)) {
                    retained.allocator.free(rt.content);
                    rt.content = try retained.allocator.dupe(u8, dt.content);
                    retained.markContentDirty();
                }
                if (rt.max_width != dt.max_width or rt.font != dt.font) {
                    retained.markSizeDirty();
                }
                rt.font = dt.font;
                rt.max_width = dt.max_width;
            } else {
                retained.payload = .{ .text = .{
                    .content = try retained.allocator.dupe(u8, dt.content),
                    .font = dt.font,
                    .max_width = dt.max_width,
                } };
            }
        },
        .rich_text => |*dt| {
            if (!type_changed) {
                const rt = &retained.payload.rich_text;
                if (!std.mem.eql(u8, rt.content, dt.content)) {
                    retained.allocator.free(rt.content);
                    rt.content = try retained.allocator.dupe(u8, dt.content);
                    retained.markContentDirty();
                }
                if (!richTextSpansEqual(rt.spans, dt.spans)) {
                    retained.allocator.free(rt.spans);
                    rt.spans = try retained.allocator.dupe(RichTextSpan, dt.spans);
                    retained.markContentDirty();
                }
                if (rt.max_width != dt.max_width or rt.font != dt.font) {
                    retained.markSizeDirty();
                }
                rt.font = dt.font;
                rt.max_width = dt.max_width;
            } else {
                retained.payload = .{ .rich_text = .{
                    .content = try retained.allocator.dupe(u8, dt.content),
                    .font = dt.font,
                    .max_width = dt.max_width,
                    .spans = try retained.allocator.dupe(RichTextSpan, dt.spans),
                } };
            }
        },
        .text_input => |*dti| {
            if (!type_changed) {
                const rti = &retained.payload.text_input;
                const font_changed = rti.font != dti.font;
                const max_width_changed = rti.max_width != dti.max_width;
                const placeholder_changed = !std.mem.eql(u8, rti.placeholder, dti.placeholder);
                rti.font = dti.font;
                rti.max_width = dti.max_width;
                rti.placeholder = dti.placeholder;
                rti.placeholder_color = dti.placeholder_color;
                if (font_changed or max_width_changed) {
                    retained.markSizeDirty();
                }
                // When the buffer is empty the layout cache holds the placeholder's
                // glyphs; if the placeholder text itself changed we must re-shape.
                if (placeholder_changed and rti.buffer.items.len == 0) {
                    retained.markContentDirty();
                }
            } else {
                retained.payload = .{ .text_input = .{
                    .buffer = std.ArrayList(u8).empty,
                    .cursor_index = 0,
                    .font = dti.font,
                    .max_width = dti.max_width,
                    .placeholder = dti.placeholder,
                    .placeholder_color = dti.placeholder_color,
                } };
                if (dti.buffer.items.len > 0) {
                    try retained.payload.text_input.buffer.appendSlice(
                        retained.allocator,
                        dti.buffer.items,
                    );
                    retained.payload.text_input.cursor_index = dti.buffer.items.len;
                }
                retained.is_focusable = true;
                retained.markContentDirty();
            }
        },
        .text_area => |*dta| {
            if (!type_changed) {
                const rta = &retained.payload.text_area;
                const font_changed = rta.font != dta.font;
                const max_width_changed = rta.max_width != dta.max_width;
                rta.font = dta.font;
                rta.max_width = dta.max_width;
                if (font_changed or max_width_changed) {
                    retained.markSizeDirty();
                }
            } else {
                retained.payload = .{ .text_area = .{
                    .buffer = std.ArrayList(u8).empty,
                    .cursor_index = 0,
                    .font = dta.font,
                    .max_width = dta.max_width,
                } };
                if (dta.buffer.items.len > 0) {
                    try retained.payload.text_area.buffer.appendSlice(
                        retained.allocator,
                        dta.buffer.items,
                    );
                    retained.payload.text_area.cursor_index = dta.buffer.items.len;
                }
                retained.is_focusable = true;
                retained.markContentDirty();
            }
        },
        .video => |v| {
            if (!type_changed) {
                const rv = &retained.payload.video;
                rv.playback = v.playback;
                rv.tint = v.tint;
                rv.custom_params = v.custom_params;
            } else {
                retained.payload = .{ .video = .{
                    .playback = v.playback,
                    .tint = v.tint,
                    .custom_params = v.custom_params,
                } };
            }
        },
        .custom_paint => |cp| {
            if (!type_changed) {
                const rcp = &retained.payload.custom_paint;
                if (rcp.revision != cp.revision) retained.markContentDirty();
                rcp.paint_fn = cp.paint_fn;
                rcp.userdata = cp.userdata;
                rcp.revision = cp.revision;
            } else {
                retained.payload = .{ .custom_paint = .{
                    .paint_fn = cp.paint_fn,
                    .userdata = cp.userdata,
                    .revision = cp.revision,
                } };
            }
        },
    }
}

fn cancelAnimationsInSubtree(comptime MessageT: type, ctx: *UIContext(MessageT), node: *Node(MessageT)) void {
    if (node.id) |id| ctx.animation_registry.cancelNode(id);
    for (node.children.items) |child| cancelAnimationsInSubtree(MessageT, ctx, child);
}

fn removeIdsInSubtree(comptime MessageT: type, ctx: *UIContext(MessageT), node: *Node(MessageT)) void {
    if (node.id) |id| {
        if (ctx.id_map.get(id)) |mapped| {
            if (mapped == node) _ = ctx.id_map.remove(id);
        }
    }
    for (node.children.items) |child| {
        removeIdsInSubtree(MessageT, ctx, child);
    }
}

fn clearInteractionRefsInSubtree(comptime MessageT: type, ctx: *UIContext(MessageT), node: *Node(MessageT)) void {
    if (ctx.interaction_registry.focused_node == node) {
        ctx.interaction_registry.focused_node = null;
    }
    if (ctx.interaction_registry.hovered_node == node) {
        ctx.interaction_registry.hovered_node = null;
    }
    if (ctx.interaction_registry.selection_anchor) |a| {
        if (a.node == node) ctx.interaction_registry.selection_anchor = null;
    }
    if (ctx.interaction_registry.selection_focus) |f| {
        if (f.node == node) ctx.interaction_registry.selection_focus = null;
    }
    if (ctx.interaction_registry.active_drag_node == node) {
        ctx.interaction_registry.active_drag_node = null;
        ctx.interaction_registry.active_drag_axis = .None;
    }
    if (ctx.interaction_registry.click_press_target == node) {
        ctx.interaction_registry.click_press_target = null;
    }
    removeFromChain(MessageT, &ctx.interaction_registry.prev_hover_chain, node);
    removeFromChain(MessageT, &ctx.interaction_registry.hover_chain, node);
    for (node.children.items) |child| {
        clearInteractionRefsInSubtree(MessageT, ctx, child);
    }
}

fn removeFromChain(comptime MessageT: type, chain: *std.ArrayList(*Node(MessageT)), node: *Node(MessageT)) void {
    var i: usize = 0;
    while (i < chain.items.len) {
        if (chain.items[i] == node) {
            _ = chain.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

inline fn prefetchNodeIfEnabled(comptime MessageT: type, nodes: []const *Node(MessageT), idx: usize) void {
    if (!bench_prefetch.isEnabled()) return;
    if (idx + 1 >= nodes.len) return;
    @prefetch(nodes[idx + 1], .{});
}

fn childListHasIds(comptime MessageT: type, nodes: []const *Node(MessageT)) bool {
    for (nodes) |node| {
        if (node.id != null) return true;
    }
    return false;
}

fn reconcileEqualAnonymousChildren(comptime MessageT: type, ctx: *UIContext(MessageT), retained: *Node(MessageT), desc: *Node(MessageT)) std.mem.Allocator.Error!bool {
    if (retained.children.items.len != desc.children.items.len) return false;
    if (childListHasIds(MessageT, retained.children.items) or childListHasIds(MessageT, desc.children.items)) return false;

    for (retained.children.items, desc.children.items) |ret_child, desc_child| {
        if (std.meta.activeTag(ret_child.payload) != std.meta.activeTag(desc_child.payload)) return false;
    }

    for (retained.children.items, desc.children.items, 0..) |ret_child, desc_child, i| {
        prefetchNodeIfEnabled(MessageT, desc.children.items, i);
        ret_child.parent = retained;
        try reconcileNode(MessageT, ctx, ret_child, desc_child);
    }
    return true;
}

fn reconcileChildren(comptime MessageT: type, ctx: *UIContext(MessageT), retained: *Node(MessageT), desc: *Node(MessageT)) std.mem.Allocator.Error!void {
    const ret_count = retained.children.items.len;

    if (try reconcileEqualAnonymousChildren(MessageT, ctx, retained, desc)) return;

    const scratch = try ctx.acquireScratch();
    defer ctx.releaseScratch(scratch);

    if (childListHasIds(MessageT, retained.children.items) or
        childListHasIds(MessageT, desc.children.items))
    {
        for (retained.children.items, 0..) |child, i| {
            if (child.id) |id| try scratch.id_map.put(ctx.gpa, id, i);
        }
    }

    var reused = try ctx.build_arena.allocator().alloc(bool, ret_count);
    @memset(reused, false);

    var children_changed = ret_count != desc.children.items.len;

    for (desc.children.items, 0..) |desc_child, desc_i| {
        prefetchNodeIfEnabled(MessageT, desc.children.items, desc_i);
        var matched_retained: ?*Node(MessageT) = null;
        var matched_idx: ?usize = null;

        if (desc_child.id) |desc_id| {
            if (scratch.id_map.get(desc_id)) |idx| {
                if (!reused[idx]) {
                    matched_retained = retained.children.items[idx];
                    matched_idx = idx;
                }
            }
        }

        if (matched_retained == null and desc_child.id == null and
            desc_i < ret_count and !reused[desc_i])
        {
            const candidate = retained.children.items[desc_i];
            if (candidate.id == null and
                std.meta.activeTag(candidate.payload) == std.meta.activeTag(desc_child.payload))
            {
                matched_retained = candidate;
                matched_idx = desc_i;
            }
        }

        if (matched_retained) |ret_child| {
            reused[matched_idx.?] = true;
            if (matched_idx.? != desc_i) children_changed = true;
            ret_child.parent = retained;
            try reconcileNode(MessageT, ctx, ret_child, desc_child);
            try scratch.children.append(ctx.gpa, ret_child);
        } else {
            children_changed = true;
            const adopted = try promoteToGPA(MessageT, ctx, desc_child);
            adopted.parent = retained;
            try scratch.children.append(ctx.gpa, adopted);
        }
    }

    try retained.children.ensureTotalCapacity(retained.allocator, scratch.children.items.len);

    for (retained.children.items, 0..) |child, i| {
        prefetchNodeIfEnabled(MessageT, retained.children.items, i);
        if (!reused[i]) {
            clearInteractionRefsInSubtree(MessageT, ctx, child);
            cancelAnimationsInSubtree(MessageT, ctx, child);
            removeIdsInSubtree(MessageT, ctx, child);
            if (ctx.on_node_destroyed) |hook| hook(ctx.on_node_destroyed_ctx, child);
            ctx.destroyTree(child);
            ctx.traversal_dirty = true;
        }
    }

    if (children_changed) {
        retained.markSizeDirty();
        retained.markPositionDirty();
    }

    retained.children.clearRetainingCapacity();
    retained.children.appendSliceAssumeCapacity(scratch.children.items);
}

fn reconcileNode(comptime MessageT: type, ctx: *UIContext(MessageT), retained: *Node(MessageT), desc: *Node(MessageT)) std.mem.Allocator.Error!void {
    patchStyle(MessageT, ctx, retained, &desc.style);

    retained.clip_children = desc.clip_children;
    retained.is_focusable = desc.is_focusable;
    retained.claims_input = desc.claims_input;
    retained.lock_pointer_on_drag = desc.lock_pointer_on_drag;
    retained.hit_byte_start = desc.hit_byte_start;
    retained.hit_byte_end = desc.hit_byte_end;
    retained.hit_test_kind = desc.hit_test_kind;
    // Only adopt scroll from descriptor when the build directive actually changed,
    // so runtime-driven scroll (overflow, scrollbar drag) survives rebuilds.
    if (desc.scroll_x != retained.prev_desc_scroll_x) {
        retained.scroll_x = desc.scroll_x;
        retained.prev_desc_scroll_x = desc.scroll_x;
        retained.markPositionDirty();
    }
    if (desc.scroll_y != retained.prev_desc_scroll_y) {
        retained.scroll_y = desc.scroll_y;
        retained.prev_desc_scroll_y = desc.scroll_y;
        retained.markPositionDirty();
    }

    if (retained != desc) {
        if (retained.events.len > 0) {
            freeEventPayloads(MessageT, retained.allocator, retained.events);
            retained.allocator.free(retained.events);
        }

        if (desc.events.len > 0) {
            retained.events = try retained.allocator.dupe(types.EventBinding(MessageT), desc.events);
        } else {
            retained.events = &.{};
        }
    }

    if (desc.child_memo_key != 0 and desc.child_memo_key == retained.child_memo_key) return;

    try patchPayload(MessageT, retained, desc);
    try reconcileChildren(MessageT, ctx, retained, desc);
    retained.child_memo_key = desc.child_memo_key;
}

fn borderWidthsChanged(a: layout.Border, b: layout.Border) bool {
    return a.top.width != b.top.width or
        a.right.width != b.right.width or
        a.bottom.width != b.bottom.width or
        a.left.width != b.left.width;
}

fn isAutoSize(size: layout.Size) bool {
    return switch (size) {
        .Auto => true,
        else => false,
    };
}

fn stretchedInsetAffectsSize(old: layout.Style, new: layout.Style) bool {
    const width_stretched = (isAutoSize(old.width) or isAutoSize(new.width)) and
        ((old.left != null and old.right != null) or (new.left != null and new.right != null));
    const height_stretched = (isAutoSize(old.height) or isAutoSize(new.height)) and
        ((old.top != null and old.bottom != null) or (new.top != null and new.bottom != null));

    return (width_stretched and (old.left != new.left or old.right != new.right)) or
        (height_stretched and (old.top != new.top or old.bottom != new.bottom));
}

fn styleChangeAffectsSize(old: layout.Style, new: layout.Style) bool {
    if (old.display != new.display) return true;
    if (old.position != new.position) return true;
    if (old.direction != new.direction) return true;
    if (old.flex_wrap != new.flex_wrap) return true;
    if (old.align_items != new.align_items) return true;
    if (old.align_self != new.align_self) return true;
    if (old.justify_content != new.justify_content) return true;
    if (old.flex_grow != new.flex_grow or old.flex_shrink != new.flex_shrink or old.gap != new.gap) return true;

    if (old.grid_columns != new.grid_columns) return true;
    if (!std.meta.eql(old.grid_template_columns, new.grid_template_columns)) return true;
    if (!std.meta.eql(old.grid_template_rows, new.grid_template_rows)) return true;
    if (!std.meta.eql(old.grid_auto_rows, new.grid_auto_rows)) return true;
    if (old.grid_column_start != new.grid_column_start or old.grid_row_start != new.grid_row_start) return true;
    if (old.grid_column_span != new.grid_column_span or old.grid_row_span != new.grid_row_span) return true;

    if (old.box_sizing != new.box_sizing) return true;
    if (!std.meta.eql(old.width, new.width) or !std.meta.eql(old.height, new.height)) return true;
    if (!std.meta.eql(old.min_width, new.min_width) or !std.meta.eql(old.max_width, new.max_width)) return true;
    if (!std.meta.eql(old.min_height, new.min_height) or !std.meta.eql(old.max_height, new.max_height)) return true;
    if (!std.meta.eql(old.padding, new.padding) or !std.meta.eql(old.margin, new.margin)) return true;
    if (old.overflow_x != new.overflow_x or old.overflow_y != new.overflow_y) return true;
    if (old.scrollbar_width != new.scrollbar_width or old.scrollbar_min_height != new.scrollbar_min_height) return true;
    if (borderWidthsChanged(old.border, new.border) or borderWidthsChanged(old.outline, new.outline)) return true;
    if (stretchedInsetAffectsSize(old, new)) return true;

    if (!std.meta.eql(old.font_family, new.font_family)) return true;
    if (old.font_weight != new.font_weight or old.font_style != new.font_style) return true;
    if (old.font_size != new.font_size or old.line_height != new.line_height) return true;
    if (old.white_space != new.white_space or old.text_overflow != new.text_overflow) return true;

    return false;
}

fn styleChangeAffectsPosition(old: layout.Style, new: layout.Style) bool {
    if (old.top != new.top or old.right != new.right or old.bottom != new.bottom or old.left != new.left) return true;
    if (!std.meta.eql(old.transform, new.transform)) return true;
    if (old.anchor_id != new.anchor_id) return true;
    return false;
}

fn markStyleDirty(comptime MessageT: type, ctx: *UIContext(MessageT), node: *Node(MessageT), old: layout.Style, new: layout.Style) void {
    if (styleChangeAffectsSize(old, new)) {
        node.markSizeDirty();
    } else if (styleChangeAffectsPosition(old, new)) {
        node.markPositionDirty();
    }
    ctx.requestPaint();
}

fn patchStyle(comptime MessageT: type, ctx: *UIContext(MessageT), node: *Node(MessageT), new_style: *const layout.Style) void {
    const preserved_hover_blend = node.style._hover_blend;
    node.style._hover_blend = new_style._hover_blend;
    if (std.meta.eql(node.style, new_style.*)) {
        node.style._hover_blend = preserved_hover_blend;
        return;
    }
    node.style._hover_blend = preserved_hover_blend;

    const old = node.style;
    const tr = new_style.transition;

    node.style = new_style.*;
    node.style._hover_blend = preserved_hover_blend;
    markStyleDirty(MessageT, ctx, node, old, node.style);

    const id = node.id orelse return;
    if (!tr.property.hasAny()) return; // No transitions defined.

    const ct = ctx.current_time;
    const dur = @as(f64, @floatFromInt(tr.duration_ms)) / 1000.0;
    const dly = @as(f64, @floatFromInt(tr.delay_ms)) / 1000.0;
    const tim = tr.timing;

    if (tr.property.background_color and colorChanged(old.background_color, new_style.background_color))
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .background_color = .{ .from = old.background_color, .to = new_style.background_color } } }, ct) catch {};

    if (tr.property.hover_color) {
        const old_hc = old.hover_color orelse old.background_color;
        const new_hc = new_style.hover_color orelse new_style.background_color;
        if (colorChanged(old_hc, new_hc))
            ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .hover_color = .{ .from = old_hc, .to = new_hc } } }, ct) catch {};
    }

    if (tr.property.text_color and colorChanged(old.text_color, new_style.text_color))
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .text_color = .{ .from = old.text_color, .to = new_style.text_color } } }, ct) catch {};

    if (tr.property.shadow_color and colorChanged(old.shadow_color, new_style.shadow_color))
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .shadow_color = .{ .from = old.shadow_color, .to = new_style.shadow_color } } }, ct) catch {};

    if (tr.property.text_decoration_color) {
        const old_dc = old.text_decoration.color orelse old.text_color;
        const new_dc = new_style.text_decoration.color orelse new_style.text_color;
        if (colorChanged(old_dc, new_dc))
            ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .text_decoration_color = .{ .from = old_dc, .to = new_dc } } }, ct) catch {};
    }

    if (tr.property.border_color and colorChanged(old.border.top.color, new_style.border.top.color))
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .border_color = .{ .from = old.border.top.color, .to = new_style.border.top.color } } }, ct) catch {};

    if (tr.property.outline_color and colorChanged(old.outline.top.color, new_style.outline.top.color))
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .outline_color = .{ .from = old.outline.top.color, .to = new_style.outline.top.color } } }, ct) catch {};

    if (tr.property.opacity and @abs(old.opacity - new_style.opacity) > 1e-6)
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .opacity = .{ .from = old.opacity, .to = new_style.opacity } } }, ct) catch {};

    if (tr.property.shadow_blur and @abs(old.shadow_blur - new_style.shadow_blur) > 1e-6)
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .shadow_blur = .{ .from = old.shadow_blur, .to = new_style.shadow_blur } } }, ct) catch {};

    if (tr.property.blur and @abs(old.blur - new_style.blur) > 1e-6)
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .blur = .{ .from = old.blur, .to = new_style.blur } } }, ct) catch {};

    if (tr.property.backdrop_blur and @abs(old.backdrop_blur - new_style.backdrop_blur) > 1e-6)
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .backdrop_blur = .{ .from = old.backdrop_blur, .to = new_style.backdrop_blur } } }, ct) catch {};

    if (tr.property.shadow_offset and vec2Changed(old.shadow_offset, new_style.shadow_offset))
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .shadow_offset = .{ .from = old.shadow_offset, .to = new_style.shadow_offset } } }, ct) catch {};

    if (tr.property.corner_radius) {
        const old_r = old.corner_radius.toArray();
        const new_r = new_style.corner_radius.toArray();
        if (radiiChanged(old_r, new_r))
            ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .corner_radius = .{ .from = old_r, .to = new_r } } }, ct) catch {};
    }

    if (tr.property.translate and vec2Changed(old.transform.translate, new_style.transform.translate))
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .translate = .{ .from = old.transform.translate, .to = new_style.transform.translate } } }, ct) catch {};

    if (tr.property.scale and @abs(old.transform.scale - new_style.transform.scale) > 1e-6)
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .scale = .{ .from = old.transform.scale, .to = new_style.transform.scale } } }, ct) catch {};

    if (tr.property.rotate and @abs(old.transform.rotate - new_style.transform.rotate) > 1e-6)
        ctx.animation_registry.register(.{ .node_id = id, .start_time = ct, .duration = dur, .delay = dly, .timing = tim, .value = .{ .rotate = .{ .from = old.transform.rotate, .to = new_style.transform.rotate } } }, ct) catch {};
}

const registry_mod = @import("../animation/registry.zig");
const AnimationEntry = registry_mod.AnimationEntry;
const AnimatedValue = registry_mod.AnimatedValue;

fn colorChanged(a: layout.Color, b: layout.Color) bool {
    return !a.eql(b);
}

fn vec2Changed(a: [2]f32, b: [2]f32) bool {
    return a[0] != b[0] or a[1] != b[1];
}

fn radiiChanged(a: [4]f32, b: [4]f32) bool {
    return a[0] != b[0] or a[1] != b[1] or a[2] != b[2] or a[3] != b[3];
}

test "text resolves explicit default font" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    try std.testing.expectError(error.DefaultFontMissing, ui.text(.{ .content = "missing" }));

    var font: FontData = undefined;
    ui.setDefaultFont(&font);
    const node = try ui.text(.{ .content = "ok" });
    defer node.deinit();

    try std.testing.expectEqual(&font, node.payload.text.font);
}

fn cleanStyleTestNode() Node(u32) {
    var node = Node(u32).init();
    node.allocator = std.testing.allocator;
    node.id = 1;
    node.flags = .{ .position = false, .size = false, .content = false };
    return node;
}

test "patchStyle keeps paint-only changes out of layout dirtiness" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();
    ui.paint_dirty = false;

    var node = cleanStyleTestNode();
    var next = node.style;
    next.text_color = layout.Color.from(.{ 0.2, 0.3, 0.4, 1.0 });

    patchStyle(u32, &ui, &node, &next);

    try std.testing.expect(!node.flags.content);
    try std.testing.expect(!node.flags.size);
    try std.testing.expect(!node.flags.position);
    try std.testing.expect(ui.paint_dirty);
}

test "patchStyle marks position-only changes without dirtying size" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    var node = cleanStyleTestNode();
    node.style.position = .absolute;
    var next = node.style;
    next.top = 12.0;

    patchStyle(u32, &ui, &node, &next);

    try std.testing.expect(!node.flags.content);
    try std.testing.expect(!node.flags.size);
    try std.testing.expect(node.flags.position);
}

test "patchStyle marks metric-affecting text style changes dirty" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    var node = cleanStyleTestNode();
    var next = node.style;
    next.font_size = 24.0;

    patchStyle(u32, &ui, &node, &next);

    try std.testing.expect(!node.flags.content);
    try std.testing.expect(node.flags.size);
    try std.testing.expect(node.flags.position);
}

fn reconcileTwoKeyed(ui: *UIContext(u32), id_left: u32, id_right: u32) !void {
    ui.building = true;
    ui.use_arena = true;
    const left = try ui.div(.{ .id = id_left });
    const right = try ui.div(.{ .id = id_right });
    const kids = [_]?*Node(u32){ left, right };
    const root = try ui.div(.{ .children = &kids });
    ui.use_arena = false;
    ui.building = false;
    try ui.reconcile(root);
}

test "reconcile maintains id_map incrementally across rebuilds" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    try reconcileTwoKeyed(&ui, 1, 2);
    try std.testing.expect(ui.getById(1) != null);
    try std.testing.expect(ui.getById(2) != null);
    const a_ptr = ui.getById(1).?;

    try reconcileTwoKeyed(&ui, 1, 3);
    try std.testing.expectEqual(a_ptr, ui.getById(1).?);
    try std.testing.expect(ui.getById(2) == null);
    try std.testing.expect(ui.getById(3) != null);

    try reconcileTwoKeyed(&ui, 3, 1);
    try std.testing.expectEqual(a_ptr, ui.getById(1).?);
    try std.testing.expect(ui.getById(3) != null);
    try std.testing.expect(ui.getById(2) == null);
}

fn reconcileIdList(ui: *UIContext(u32), ids: []const u32) !void {
    ui.building = true;
    ui.use_arena = true;
    var kids = std.ArrayList(?*Node(u32)).empty;
    defer kids.deinit(std.testing.allocator);
    for (ids) |id| try kids.append(std.testing.allocator, try ui.div(.{ .id = id }));
    const root = try ui.div(.{ .children = kids.items });
    ui.use_arena = false;
    ui.building = false;
    try ui.reconcile(root);
}

test "reconcile pool: drop and re-add subtrees is leak-free" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try reconcileIdList(&ui, &.{ 1, 2, 3 });
        try std.testing.expect(ui.getById(1) != null);
        try std.testing.expect(ui.getById(3) != null);
        try reconcileIdList(&ui, &.{});
        try std.testing.expect(ui.getById(1) == null);
        try std.testing.expectEqual(@as(usize, 0), ui.root.children.items.len);
    }
}

test "reconcile pool stress: random keyed lists stay consistent and leak-free" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    var prng = std.Random.DefaultPrng.init(0xBADC0FFEE);
    const rand = prng.random();

    var step: usize = 0;
    while (step < 300) : (step += 1) {
        var present = [_]bool{false} ** 13;
        var ids = std.ArrayList(u32).empty;
        defer ids.deinit(std.testing.allocator);
        const count = rand.uintAtMost(usize, 12);
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const id = rand.intRangeAtMost(u32, 1, 12);
            if (present[id]) continue;
            present[id] = true;
            try ids.append(std.testing.allocator, id);
        }

        try reconcileIdList(&ui, ids.items);

        try std.testing.expectEqual(ids.items.len, ui.root.children.items.len);
        for (ids.items) |id| try std.testing.expect(ui.getById(id) != null);
        var id: u32 = 1;
        while (id <= 12) : (id += 1) {
            if (!present[id]) try std.testing.expect(ui.getById(id) == null);
        }
        for (ui.root.children.items) |c| try std.testing.expectEqual(ui.root, c.parent.?);

        try ui.ensureTraversal();
        try std.testing.expectEqual(ui.root.children.items.len + 1, ui.traversal.items.len);
    }
}

test "reconcile pool: nested subtree destroy is leak-free, traversal is preorder" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    ui.building = true;
    ui.use_arena = true;
    const g = try ui.div(.{ .id = 10 });
    const gk = [_]?*Node(u32){g};
    const c = try ui.div(.{ .id = 11, .children = &gk });
    const ck = [_]?*Node(u32){c};
    const root = try ui.div(.{ .children = &ck });
    ui.use_arena = false;
    ui.building = false;
    try ui.reconcile(root);

    try ui.ensureTraversal();
    try std.testing.expectEqual(@as(usize, 3), ui.traversal.items.len);
    try std.testing.expectEqual(ui.root, ui.traversal.items[0]);
    try std.testing.expectEqual(ui.getById(11).?, ui.traversal.items[1]);
    try std.testing.expectEqual(ui.getById(10).?, ui.traversal.items[2]);

    try reconcileIdList(&ui, &.{});
    try std.testing.expect(ui.getById(10) == null);
    try std.testing.expect(ui.getById(11) == null);
}

test "mountRoot clones an external gpa tree into the pool" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    ui.building = true;
    ui.use_arena = false;
    const a = try ui.div(.{ .id = 100 });
    const ak = [_]?*Node(u32){a};
    const external = try ui.div(.{ .id = 200, .children = &ak });
    ui.building = false;
    try ui.mountRoot(external);

    try std.testing.expect(ui.getById(100) != null);
    try std.testing.expect(ui.getById(200) != null);

    try reconcileIdList(&ui, &.{ 5, 6 });
    try std.testing.expect(ui.getById(5) != null);
    try std.testing.expect(ui.getById(100) == null);
}

const HookHolder = struct {
    cached: ?*Node(u32) = null,
    saw: bool = false,
    fn onDestroy(ctx: *anyopaque, node: *Node(u32)) void {
        const self: *HookHolder = @ptrCast(@alignCast(ctx));
        if (self.cached == node) {
            self.cached = null;
            self.saw = true;
        }
    }
};

test "destroy hook clears external pointers before slot reuse" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    var holder = HookHolder{};
    ui.on_node_destroyed = &HookHolder.onDestroy;
    ui.on_node_destroyed_ctx = &holder;

    try reconcileTwoKeyed(&ui, 1, 2);
    holder.cached = ui.getById(2);
    try std.testing.expect(holder.cached != null);

    try reconcileTwoKeyed(&ui, 1, 3);
    try std.testing.expect(holder.saw);
    try std.testing.expect(holder.cached == null);
}

test "traversal array rebuilds on structural change, not on style-only" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme_lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    try reconcileTwoKeyed(&ui, 1, 2);
    try ui.ensureTraversal();
    try std.testing.expect(!ui.traversal_dirty);
    try std.testing.expectEqual(@as(usize, 3), ui.traversal.items.len);

    try reconcileTwoKeyed(&ui, 1, 2);
    try std.testing.expect(!ui.traversal_dirty);

    try reconcileTwoKeyed(&ui, 1, 9);
    try std.testing.expect(ui.traversal_dirty);
    try ui.ensureTraversal();
    try std.testing.expectEqual(@as(usize, 3), ui.traversal.items.len);
    try std.testing.expect(ui.getById(9) != null);
}
