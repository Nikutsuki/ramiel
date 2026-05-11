const std = @import("std");
const Engine = @import("renderer/vulkan/engine.zig").Engine;
const QuadBatcher = @import("renderer/vulkan/batcher.zig").QuadBatcher;
const FontSystem = @import("renderer/font/font_system.zig").FontSystem;
const AudioEngine = @import("audio/audio_engine.zig").AudioEngine;
const StreamSeekStatus = @import("audio/registry.zig").StreamSeekStatus;
const UIContext = @import("ui/context.zig").UIContext;
pub const UpdateAction = @import("ui/context.zig").UpdateAction;
const Node = @import("ui/node.zig").Node;
pub const InteractionMessage = @import("ui/types.zig").InteractionMessage;
const DevToolsState = @import("devtools/state.zig").DevToolsState;
const DevToolsTab = @import("devtools/state.zig").DevToolsTab;
const buildDevToolsPanel = @import("devtools/ui.zig").buildDevToolsPanel;
const win_mod = @import("window/window.zig");
const WindowContext = win_mod.WindowContext;
pub const WindowConfig = win_mod.WindowConfig;
pub const HotkeyFn = win_mod.HotkeyFn;
const tracy = @import("tracy");
const VideoManager = @import("video/manager.zig").VideoManager;
const Theme = @import("ui/theme.zig").Theme;

const FontSource = @import("renderer/font/font_registry.zig").FontSource;
const FontData = @import("renderer/font/font_registry.zig").FontData;
const TextureId = @import("assets.zig").TextureId;
const TextureState = @import("renderer/vulkan/texture_registry.zig").TextureState;
const ImageIngressBudget = @import("renderer/image_ingress.zig").ImageIngressBudget;
const ImageFallbackState = @import("ui/node.zig").RenderPayload.ImageFallbackState;
const AnimatedState = @import("renderer/image_animation.zig").AnimatedState;
const Canvas = @import("renderer/canvas.zig").Canvas;
const PixelBuffer = @import("renderer/pixel_buffer.zig").PixelBuffer;
const IconRegistry = @import("renderer/icon/registry.zig").IconRegistry;
const IconId = @import("renderer/icon/id.zig").IconId;
const core_assets = @import("ui/core_assets.zig");
const nfd = @import("nfd");
const assets_mod = @import("assets.zig");

const glfw = @import("glfw");
const build_options = @import("build_options");

pub fn Application(comptime StateType: type, comptime MessageType: type) type {
    return struct {
        const Self = @This();

        parent_allocator: std.mem.Allocator,
        allocator: std.mem.Allocator,
        io: std.Io,
        tracy_allocator: ?*tracy.Allocator,
        window: WindowContext,
        engine: *Engine,
        font_system: FontSystem,
        audio_engine: AudioEngine,
        batcher: QuadBatcher,
        video_manager: VideoManager,
        icon_registry: IconRegistry,
        ui: UIContext(MessageType),
        devtools_state: DevToolsState(MessageType),
        devtools_missing_font_warned: bool = false,
        devtools_requires_builder_warned: bool = false,
        canvases: std.ArrayList(*Canvas),
        state: StateType,
        cross_thread_mutex: std.Io.Mutex = .init,
        cross_thread_queue: std.ArrayList(InteractionMessage(MessageType)),
        file_dialog_task: ?std.Io.Future(void) = null,
        file_dialog_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        video_poll_hz: f64 = 60.0,

        update_fn: *const fn (app: *Self, msg: InteractionMessage(MessageType)) UpdateAction,

        tick_fn: ?*const fn (app: *Self) UpdateAction = null,

        /// glfwWaitEventsTimeout cadence so tick_fn fires without input. null = wait indefinitely.
        tick_interval_s: ?f64 = null,

        last_frame_time: f64 = 0.0,
        initial_tree_mounted: bool = false,

        build_fn: ?*const fn (ui: *UIContext(MessageType), state: *const StateType) anyerror!*Node(MessageType) = null,

        pub const FileDialogCallback = *const fn (path: ?[]const u8) MessageType;

        const FileDialogTaskArgs = struct {
            self: *Self,
            filter_list: ?[:0]const u8,
            callback: FileDialogCallback,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            config: WindowConfig,
            initial_state: StateType,
            update_fn: *const fn (*Self, InteractionMessage(MessageType)) UpdateAction,
        ) !Self {
            var tracy_allocator: ?*tracy.Allocator = null;
            var effective_allocator = allocator;

            const default_theme = Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true);

            if (tracy.enabled) {
                const wrapped = try allocator.create(tracy.Allocator);
                wrapped.* = .{
                    .parent = allocator,
                    .pool_name = "Application",
                };
                effective_allocator = wrapped.allocator();
                tracy_allocator = wrapped;
            }
            errdefer if (tracy_allocator) |wrapped| allocator.destroy(wrapped);

            var win = try win_mod.initWindow(effective_allocator, config);
            errdefer win.deinit();
            const engine = try effective_allocator.create(Engine);
            errdefer effective_allocator.destroy(engine);
            engine.* = try Engine.init(
                effective_allocator,
                io,
                win.window,
                config.transparent,
                .{ .sample_count = .{ .@"16_bit" = true } },
            );
            errdefer engine.deinit();
            var font_system = try FontSystem.init(effective_allocator);
            errdefer font_system.deinit(&engine.core);
            var audio_engine = try AudioEngine.init(effective_allocator, io);
            errdefer audio_engine.deinit();
            audio_engine.registry.setWakeUpCallback(struct {
                fn wake() void {
                    glfw.postEmptyEvent();
                }
            }.wake);
            var batcher = try QuadBatcher.init(effective_allocator, engine.swapchain.extent);
            errdefer batcher.deinit();
            var icon_registry = IconRegistry.init(
                effective_allocator,
                &engine.core,
                &engine.resources.texture_registry,
            );
            errdefer icon_registry.deinit();
            try core_assets.initCoreIcons(&icon_registry);
            var ui = try UIContext(MessageType).init(effective_allocator, default_theme);
            errdefer ui.deinit();
            var video_manager = VideoManager.init(
                effective_allocator,
                io,
                &engine.core,
                &engine.resources.texture_registry,
                engine.video_descriptor_set_layout,
                audio_engine.engine,
                engine.frames.frames.len,
            );
            errdefer video_manager.deinit();

            var video_poll_hz: f64 = 60.0;
            const monitor = glfw.getPrimaryMonitor();
            if (glfw.getVideoMode(monitor)) |mode| {
                const hz = @as(f64, @floatFromInt(mode.refreshRate));
                video_poll_hz = std.math.clamp(hz, 1.0, 1000.0);
            }
            var devtools_state = DevToolsState(MessageType).init();
            if (build_options.devtools) {
                devtools_state.setActive(true);
            }

            return Self{
                .parent_allocator = allocator,
                .allocator = effective_allocator,
                .io = io,
                .tracy_allocator = tracy_allocator,
                .window = win,
                .engine = engine,
                .font_system = font_system,
                .audio_engine = audio_engine,
                .batcher = batcher,
                .ui = ui,
                .canvases = .empty,
                .state = initial_state,
                .update_fn = update_fn,
                .cross_thread_queue = .empty,
                .video_manager = video_manager,
                .icon_registry = icon_registry,
                .video_poll_hz = video_poll_hz,
                .devtools_state = devtools_state,
                .devtools_missing_font_warned = false,
                .devtools_requires_builder_warned = false,
            };
        }

        pub fn createCanvas(self: *Self, width: u32, height: u32) !*Canvas {
            const frame_slots = self.engine.frames.frames.len;
            const canvas = try Canvas.init(
                self.allocator,
                &self.engine.core,
                &self.engine.resources.texture_registry,
                width,
                height,
                frame_slots,
            );
            errdefer canvas.deinit(&self.engine.core, &self.engine.resources.texture_registry);

            try self.canvases.append(self.allocator, canvas);
            return canvas;
        }

        pub fn createCanvasFromBuffer(self: *Self, buffer: PixelBuffer) !*Canvas {
            const frame_slots = self.engine.frames.frames.len;
            const canvas = try Canvas.initFromBuffer(
                self.allocator,
                &self.engine.core,
                &self.engine.resources.texture_registry,
                buffer,
                frame_slots,
            );
            errdefer canvas.deinit(&self.engine.core, &self.engine.resources.texture_registry);

            try self.canvases.append(self.allocator, canvas);
            return canvas;
        }

        pub fn updateTheme(self: *Self, theme: Theme) void {
            self.ui.setTheme(theme);
        }

        pub fn destroyCanvas(self: *Self, canvas: *Canvas) void {
            for (self.canvases.items, 0..) |item, i| {
                if (item != canvas) continue;

                const detached = detachCanvasPayloads(self.ui.root, canvas);
                if (detached) {
                    self.ui.requestLayout();
                }

                _ = self.engine.core.vkd.deviceWaitIdle(self.engine.core.logical_device) catch |err| {
                    std.log.warn("destroyCanvas: deviceWaitIdle failed: {s}", .{@errorName(err)});
                };

                _ = self.canvases.swapRemove(i);
                canvas.deinit(&self.engine.core, &self.engine.resources.texture_registry);
                return;
            }
        }

        pub fn openFileDialog(self: *Self, filter_list: ?[:0]const u8, callback: FileDialogCallback) void {
            // Reap a finished prior task if one is sitting around.
            self.reapFileDialogIfDone();
            if (self.file_dialog_task != null) {
                std.log.warn("File dialog task already in progress.", .{});
                return;
            }

            self.file_dialog_done.store(false, .release);
            self.file_dialog_task = self.io.concurrent(fileDialogWorker, .{.{
                .self = self,
                .filter_list = filter_list,
                .callback = callback,
            }}) catch |err| {
                std.log.err("Failed to spawn concurrent file dialog task: {s}", .{@errorName(err)});
                self.postMessageId(callback(null));
                return;
            };
        }

        pub fn openFolderDialog(self: *Self, callback: FileDialogCallback) void {
            self.reapFileDialogIfDone();
            if (self.file_dialog_task != null) {
                std.log.warn("File dialog task already in progress.", .{});
                return;
            }
            self.file_dialog_done.store(false, .release);
            self.file_dialog_task = self.io.concurrent(folderDialogWorker, .{.{
                .self = self,
                .filter_list = null,
                .callback = callback,
            }}) catch |err| {
                std.log.err("Failed to spawn concurrent folder dialog task: {s}", .{@errorName(err)});
                self.postMessageId(callback(null));
                return;
            };
        }

        fn reapFileDialogIfDone(self: *Self) void {
            if (self.file_dialog_task == null) return;
            if (!self.file_dialog_done.load(.acquire)) return;
            if (self.file_dialog_task) |*task| {
                _ = task.await(self.io);
                self.file_dialog_task = null;
            }
        }

        fn fileDialogWorker(args: FileDialogTaskArgs) void {
            const self = args.self;

            const maybe_raw_path = nfd.openFileDialog(args.filter_list, null) catch |err| {
                std.log.err("NFD openFileDialog failed: {s}", .{@errorName(err)});
                self.postMessageId(args.callback(null));
                self.file_dialog_done.store(true, .release);
                return;
            };

            var final_path: ?[]const u8 = null;
            if (maybe_raw_path) |raw_path| {
                defer nfd.freePath(raw_path);
                final_path = self.allocator.dupe(u8, raw_path) catch |err| blk: {
                    std.log.err("Failed to duplicate selected file path: {s}", .{@errorName(err)});
                    break :blk null;
                };
            }

            self.postMessageId(args.callback(final_path));
            self.file_dialog_done.store(true, .release);
        }

        fn folderDialogWorker(args: FileDialogTaskArgs) void {
            const self = args.self;
            const maybe_raw_path = nfd.openFolderDialog(null) catch |err| {
                std.log.err("NFD openFolderDialog failed: {s}", .{@errorName(err)});
                self.postMessageId(args.callback(null));
                self.file_dialog_done.store(true, .release);
                return;
            };
            var final_path: ?[]const u8 = null;
            if (maybe_raw_path) |raw_path| {
                defer nfd.freePath(raw_path);
                final_path = self.allocator.dupe(u8, raw_path) catch |err| blk: {
                    std.log.err("Failed to duplicate selected folder path: {s}", .{@errorName(err)});
                    break :blk null;
                };
            }
            self.postMessageId(args.callback(final_path));
            self.file_dialog_done.store(true, .release);
        }

        pub fn finalizeFileDialog(self: *Self) void {
            if (self.file_dialog_task) |*task| {
                task.await(self.io);
                self.file_dialog_task = null;
            }
        }

        pub fn loadFont(self: *Self, name: []const u8, source: FontSource, base_resolution: u32) !*FontData {
            return self.font_system.loadFont(&self.engine.core, &self.engine.resources.texture_registry, name, source, base_resolution);
        }

        pub fn setDefaultFont(self: *Self, font: *FontData) void {
            self.ui.setDefaultFont(font);
        }

        pub fn loadDefaultFont(self: *Self, name: []const u8, source: FontSource, base_resolution: u32) !*FontData {
            const font = try self.loadFont(name, source, base_resolution);
            self.setDefaultFont(font);
            return font;
        }

        pub fn setDefaultFallbackChain(self: *Self, names: []const []const u8) !void {
            try self.font_system.setDefaultFallbackChain(names);
        }

        pub fn getFont(self: *Self, name: []const u8) ?*FontData {
            return self.font_system.getFont(name);
        }

        pub fn requireFont(self: *Self, name: []const u8) *FontData {
            return self.font_system.getFont(name) orelse {
                std.debug.panic("requireFont: '{s}' not loaded — call app.loadFont(\"{s}\", ...) first", .{ name, name });
            };
        }

        pub fn loadAndPlaySound(self: *Self, name: []const u8, path: [:0]const u8) ?u64 {
            return self.audio_engine.registry.loadAndPlay(name, path);
        }

        pub fn getSoundId(self: *Self, name: []const u8, path: [:0]const u8) !u32 {
            return self.audio_engine.registry.getSoundId(name, path);
        }

        pub fn playSoundById(self: *Self, sound_id: u32) ?u64 {
            return self.audio_engine.registry.play(sound_id);
        }

        pub fn playAudioStream(self: *Self, path: [:0]const u8) ?u64 {
            return self.audio_engine.registry.playStream(path);
        }

        pub fn stopSound(self: *Self, playback_id: u64) void {
            self.audio_engine.registry.stopById(playback_id);
        }

        pub fn setSoundVolume(self: *Self, playback_id: u64, volume: f32) void {
            self.audio_engine.registry.setVolumeById(playback_id, volume);
        }

        pub fn seekStream(self: *Self, playback_id: u64, seconds: f32) void {
            self.audio_engine.registry.seekStreamSeconds(playback_id, seconds);
        }

        pub fn seekStreamImmediate(self: *Self, playback_id: u64, seconds: f32) void {
            self.audio_engine.registry.seekStreamSecondsImmediate(playback_id, seconds);
        }

        pub fn getStreamSeekStatus(self: *Self) StreamSeekStatus {
            return self.audio_engine.registry.getStreamSeekStatus();
        }

        pub fn isStreamSeeking(self: *Self, playback_id: u64) bool {
            return self.audio_engine.registry.isStreamSeeking(playback_id);
        }

        pub fn isStreamSeekActive(self: *Self, playback_id: u64) bool {
            return self.audio_engine.registry.isStreamSeekActive(playback_id);
        }

        pub fn pauseStream(self: *Self, playback_id: u64) void {
            self.audio_engine.registry.pauseStream(playback_id);
        }

        pub fn resumeStream(self: *Self, playback_id: u64) void {
            self.audio_engine.registry.resumeStream(playback_id);
        }

        pub fn isStreamPlaying(self: *Self, playback_id: u64) bool {
            return self.audio_engine.registry.isStreamPlaying(playback_id);
        }

        pub fn getStreamCursorSeconds(self: *Self, playback_id: u64) f32 {
            return self.audio_engine.registry.getStreamCursorSeconds(playback_id);
        }

        pub fn getStreamDurationSeconds(self: *Self, playback_id: u64) f32 {
            return self.audio_engine.registry.getStreamDurationSeconds(playback_id);
        }

        pub fn unloadSound(self: *Self, name: []const u8) void {
            self.audio_engine.registry.unload(name);
        }

        pub fn enqueueAfter(self: *Self, current_id: u64, next_path: [:0]const u8) !void {
            try self.audio_engine.registry.enqueueAfter(current_id, next_path);
        }

        pub fn clearQueuedAfter(self: *Self, current_id: u64) void {
            self.audio_engine.registry.clearQueuedAfter(current_id);
        }

        pub fn startCrossfade(self: *Self, out_id: u64, in_path: [:0]const u8, fade_ms: u32) !u64 {
            return self.audio_engine.registry.startCrossfade(out_id, in_path, fade_ms);
        }

        pub fn takeAdvanceEvents(self: *Self, allocator: std.mem.Allocator) ![]@import("audio/registry.zig").AdvanceEvent {
            return self.audio_engine.registry.takeAdvanceEvents(allocator);
        }

        pub fn setEQ(self: *Self, cfg: @import("audio/audio_engine.zig").EQConfig) !void {
            try self.audio_engine.setEQ(cfg);
        }

        pub fn getEQ(self: *Self) @import("audio/audio_engine.zig").EQConfig {
            return self.audio_engine.getEQ();
        }

        pub fn getTextureIndex(self: *const Self, id: TextureId) u32 {
            return self.engine.getTextureIndex(id);
        }

        pub fn loadIconSvg(
            self: *Self,
            icon_id: u32,
            path: []const u8,
            width: u32,
            height: u32,
            scale: f32,
        ) !void {
            try self.icon_registry.loadStaticSvg(icon_id, path, width, height, scale);
        }

        pub fn loadIconPng(self: *Self, icon_id: u32, path: []const u8, scale: f32) !void {
            try self.icon_registry.loadStaticPng(icon_id, path, scale);
        }

        pub fn loadRuntimeIconPng(self: *Self, path: []const u8, scale: f32) !IconId {
            return self.icon_registry.loadRuntimePng(path, scale);
        }

        pub fn freeRuntimeIcon(self: *Self, icon_id: IconId) void {
            self.icon_registry.free(icon_id);
        }

        pub fn loadIconSvgFromMemory(
            self: *Self,
            icon_id: u32,
            svg_data: []const u8,
            width: u32,
            height: u32,
            scale: f32,
        ) !void {
            try self.icon_registry.loadStaticSvgFromMemory(icon_id, svg_data, width, height, scale);
        }

        pub fn loadIconPngFromMemory(
            self: *Self,
            icon_id: u32,
            png_data: []const u8,
            scale: f32,
        ) !void {
            try self.icon_registry.loadStaticPngFromMemory(icon_id, png_data, scale);
        }

        pub fn getIconTextureId(self: *Self, icon_id: u32, scale: f32) ?u32 {
            return self.icon_registry.get(icon_id, scale);
        }

        pub fn getImageId(self: *Self, name: []const u8) u32 {
            return self.engine.resources.texture_registry.getImageId(name);
        }

        pub fn pushImageData(self: *Self, name: []const u8, compressed_bytes: []const u8) !void {
            try self.engine.resources.texture_registry.pushImageData(name, compressed_bytes);
        }

        pub fn getImageState(self: *Self, name: []const u8) TextureState {
            return self.engine.getImageState(name);
        }

        pub fn getResolvedImageState(self: *Self, name: []const u8) TextureState {
            const state = self.engine.getImageState(name);
            if (state == .ready) {
                const tex_id = self.engine.resources.texture_registry.getImageId(name);
                if (tex_id == self.engine.resources.texture_registry.fallback_tex_id) {
                    return .decoding;
                }
            }
            return state;
        }

        pub fn loadImageFromDiskAsync(self: *Self, name: []const u8, path: []const u8, max_bytes: usize) !void {
            try self.engine.loadImageFromDiskAsync(name, path, max_bytes);
        }

        pub fn loadImageFromDiskAsyncSized(
            self: *Self,
            name: []const u8,
            path: []const u8,
            target_width: u32,
            target_height: u32,
        ) !void {
            try self.engine.loadImageFromDiskAsyncSized(name, path, target_width, target_height);
        }

        pub fn loadImageFromUrlAsync(self: *Self, name: []const u8, url: []const u8, max_bytes: usize) !void {
            try self.engine.loadImageFromUrlAsync(name, url, max_bytes);
        }

        pub fn loadImageFromUrlAsyncSized(
            self: *Self,
            name: []const u8,
            url: []const u8,
            target_width: u32,
            target_height: u32,
        ) !void {
            try self.engine.loadImageFromUrlAsyncSized(name, url, target_width, target_height);
        }

        pub fn setImageIngressBudget(self: *Self, budget: ImageIngressBudget) void {
            self.engine.setImageIngressBudget(budget);
        }

        /// Call after setRootBuilder so stable-ID nodes exist.
        pub fn registerAnimation(self: *Self, entry: @import("animation/registry.zig").AnimationEntry) !void {
            try self.ui.animation_registry.register(entry, glfw.getTime());
        }

        pub fn loadStaticAssets(
            self: *Self,
            comptime AssetEnum: type,
            manifest: std.EnumArray(AssetEnum, assets_mod.StaticAsset),
        ) !void {
            if (@typeInfo(AssetEnum) != .@"enum") {
                @compileError("loadStaticAssets requires an enum type.");
            }

            for (std.enums.values(AssetEnum)) |id| {
                const asset = manifest.get(id);
                switch (asset.payload) {
                    .image => |bytes| try self.pushImageData(asset.name, bytes),
                    .font => |data| _ = try self.loadFont(asset.name, .{ .memory = data.bytes }, data.size),
                    .audio => |bytes| {
                        _ = self.audio_engine.registry.loadMemory(asset.name, bytes) catch |err| {
                            std.log.err("Failed to load static audio {s}: {s}", .{ asset.name, @errorName(err) });
                        };
                    },
                    .icon_svg => |data| try self.loadIconSvgFromMemory(@intFromEnum(id), data.bytes, data.width, data.height, data.scale),
                    .icon_png => |data| try self.loadIconPngFromMemory(@intFromEnum(id), data.bytes, data.scale),
                }
            }
        }

        pub fn setRootBuilder(
            self: *Self,
            build: *const fn (*UIContext(MessageType), *const StateType) anyerror!*Node(MessageType),
        ) !void {
            self.wireImageResolver();
            self.wireIconResolver();
            self.build_fn = build;
        }

        pub fn mountRoot(self: *Self) !void {
            if (self.initial_tree_mounted) return;
            const build = self.build_fn orelse return error.NoRootBuilder;
            self.ui.building = true;
            self.ui.has_animated_images = false;
            self.ui.min_animated_frame_ms = 0;
            const root = try build(&self.ui, &self.state);
            self.ui.building = false;
            try self.appendDevToolsOverlay(root);
            try self.ui.mountRoot(root);
            self.initial_tree_mounted = true;
        }

        pub fn setDevToolsActive(self: *Self, active: bool) void {
            self.devtools_state.setActive(active);
        }

        pub fn toggleDevTools(self: *Self) void {
            self.devtools_state.toggle();
        }

        pub fn setDevToolsTab(self: *Self, tab: DevToolsTab) void {
            self.devtools_state.setTab(tab);
        }

        pub fn getDevToolsState(self: *Self) *DevToolsState(MessageType) {
            return &self.devtools_state;
        }

        fn appendDevToolsOverlay(self: *Self, root: *Node(MessageType)) !void {
            const font = self.font_system.getFont("JetBrains Mono") orelse {
                if (!self.devtools_missing_font_warned) {
                    self.devtools_missing_font_warned = true;
                    std.log.err("DevTools: required font 'JetBrains Mono' is not loaded; overlay mount skipped", .{});
                }
                return;
            };
            self.devtools_missing_font_warned = false;
            const overlay_allocator = if (self.ui.use_arena) self.ui.build_arena.allocator() else self.allocator;
            const devtools_root = try buildDevToolsPanel(
                MessageType,
                overlay_allocator,
                &self.devtools_state,
                font,
                self.ui.root,
            );
            try root.addChild(devtools_root);
        }

        fn wireImageResolver(self: *Self) void {
            self.ui.image_resolver = .{
                .context = @ptrCast(self),
                .getTexId = @ptrCast(&resolveTexId),
                .getResolvedState = @ptrCast(&resolveImageState),
                .getAnimation = @ptrCast(&resolveAnimation),
            };
        }

        fn wireIconResolver(self: *Self) void {
            self.ui.icon_resolver = .{
                .context = @ptrCast(self),
                .getTexId = resolveIconTexIdWrapper,
            };
        }

        fn computeWaitTimeoutSeconds(self: *Self) ?f64 {
            var timeout: ?f64 = null;

            if (self.ui.has_animated_images and self.ui.min_animated_frame_ms > 0) {
                const frame_s = @as(f64, @floatFromInt(self.ui.min_animated_frame_ms)) / 1000.0;
                timeout = std.math.clamp(frame_s, 0.001, 0.25);
            }

            if (!self.ui.animation_registry.isEmpty() or self.ui.interaction_registry.hover_anim_active) {
                const ui_timeout = 1.0 / 120.0;
                timeout = if (timeout) |t| @min(t, ui_timeout) else ui_timeout;
            }

            if (self.video_manager.getMinWaitTimeS()) |video_wait| {
                const precise_timeout = @max(0.0, video_wait - 0.000);
                timeout = if (timeout) |t| @min(t, precise_timeout) else precise_timeout;
            }

            if (self.tick_interval_s) |interval| {
                timeout = if (timeout) |t| @min(t, interval) else interval;
            }

            if (self.ui.interaction_registry.rebuild_requested) {
                timeout = 0.0;
            }

            return timeout;
        }
        fn resolveTexId(self: *Self, source: []const u8) u32 {
            return self.engine.resources.texture_registry.getImageId(source);
        }

        fn resolveAnimation(
            self: *Self,
            source: []const u8,
        ) ?*const AnimatedState {
            return self.engine.resources.texture_registry.getImageAnimation(source);
        }

        fn resolveImageState(self: *Self, source: []const u8) ImageFallbackState {
            const state = self.engine.getImageState(source);
            if (state == .ready) {
                const tex_id = self.engine.resources.texture_registry.getImageId(source);
                if (tex_id == self.engine.resources.texture_registry.fallback_tex_id) {
                    return .decoding;
                }
            }
            return switch (state) {
                .missing => .missing,
                .decoding => .decoding,
                .ready => .ready,
            };
        }

        fn resolveIconTexId(self: *Self, icon_id: u32, scale: f32) ?u32 {
            return self.icon_registry.get(icon_id, scale);
        }

        fn resolveIconTexIdWrapper(ctx: *anyopaque, icon_id: u32, scale: f32) ?u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.resolveIconTexId(icon_id, scale);
        }

        pub fn setShortcutHandler(
            self: *Self,
            comptime CtxT: type,
            ctx: *CtxT,
            comptime handler: *const fn (
                ctx: *CtxT,
                ir: *@import("ui/interaction.zig").InteractionRegistry(MessageType),
                key: i32,
                action: i32,
                win: *const WindowContext,
            ) bool,
        ) void {
            const Trampoline = struct {
                fn call(
                    opaque_ctx: ?*anyopaque,
                    ir: *@import("ui/interaction.zig").InteractionRegistry(MessageType),
                    key: i32,
                    action: i32,
                    win: *const WindowContext,
                ) bool {
                    const typed: *CtxT = @ptrCast(@alignCast(opaque_ctx.?));
                    return handler(typed, ir, key, action, win);
                }
            };
            self.ui.interaction_registry.shortcut_context = ctx;
            self.ui.interaction_registry.shortcut_handler = Trampoline.call;
        }

        pub fn postMessage(self: *Self, msg: InteractionMessage(MessageType)) void {
            self.cross_thread_mutex.lockUncancelable(self.io);
            defer self.cross_thread_mutex.unlock(self.io);
            self.cross_thread_queue.append(self.allocator, msg) catch |err| {
                std.log.err("postMessage: failed to append to cross_thread_queue: {s}", .{@errorName(err)});
            };
            glfw.postEmptyEvent();
        }

        pub fn postMessageId(self: *Self, msg_id: MessageType) void {
            self.postMessage(.{ .id = msg_id });
        }

        pub fn cancelAndAwaitFutures(self: *Self, futures: anytype) void {
            inline for (futures) |slot| {
                if (slot.*) |*future| {
                    future.cancel(self.io);
                    future.await(self.io);
                }
                slot.* = null;
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.file_dialog_task) |*task| {
                _ = task.await(self.io);
                self.file_dialog_task = null;
            }

            @import("ui/interaction.zig").destroyResidualMessages(
                MessageType,
                self.allocator,
                self.cross_thread_queue.items,
            );
            self.cross_thread_queue.deinit(self.allocator);
            self.ui.deinit();
            self.batcher.deinit();
            self.video_manager.deinit();
            self.icon_registry.deinit();
            self.audio_engine.deinit();

            _ = self.engine.core.vkd.deviceWaitIdle(self.engine.core.logical_device) catch |err| {
                std.log.warn("Application.deinit: deviceWaitIdle failed: {s}", .{@errorName(err)});
            };

            for (self.canvases.items) |canvas| {
                canvas.deinit(&self.engine.core, &self.engine.resources.texture_registry);
            }
            self.canvases.deinit(self.allocator);

            self.font_system.deinit(&self.engine.core);
            self.engine.deinit();
            self.allocator.destroy(self.engine);
            self.window.deinit();

            if (self.tracy_allocator) |wrapped| {
                self.parent_allocator.destroy(wrapped);
                self.tracy_allocator = null;
            }
        }

        pub fn setVisibility(self: *Self, visible: bool) void {
            if (visible) {
                self.window.show();
                self.ui.requestLayout();
            } else {
                self.window.hide();
                self.ui.interaction_registry.resetForNewTree();
            }
        }

        /// callback's user_ptr is the Application. modifier: win32.MOD_*; key: VK_* code.
        pub fn registerGlobalHotkey(self: *Self, modifier: u32, key: u32, callback: HotkeyFn) !void {
            try self.window.registerGlobalHotkey(modifier, key, self, callback);
        }

        pub fn run(self: *Self) !void {
            self.window.registerCallbacks(self, onKey, onChar, onResize);
            try self.mountRoot();

            const initial_fb = self.window.getFramebufferSize();
            try self.ui.calculateLayout(&self.font_system.text_layouter, @floatFromInt(initial_fb.width), @floatFromInt(initial_fb.height));
            var last_fb = initial_fb;
            self.last_frame_time = glfw.getTime();
            // Wayland: waitEvents() blocks until the first surface commit.
            self.ui.requestPaint();
            var first_iteration = true;

            while (!self.window.shouldClose()) {
                self.audio_engine.registry.processAudioCleanup();

                if (glfw.getWindowAttrib(self.window.window, glfw.Visible) == 0) {
                    glfw.waitEvents();
                    continue;
                }

                if (first_iteration) {
                    glfw.pollEvents();
                    first_iteration = false;
                } else if (self.computeWaitTimeoutSeconds()) |timeout_s| {
                    glfw.waitEventsTimeout(timeout_s);
                } else {
                    glfw.waitEvents();
                }

                const video_frame_ready = try self.video_manager.tick(
                    self.engine.frames.current_frame_index,
                );

                if (video_frame_ready) {
                    self.ui.requestPaint();
                }

                if (self.ui.has_animated_images) self.ui.requestPaint();

                const current_time = glfw.getTime();
                const delta_time = current_time - self.last_frame_time;
                self.last_frame_time = current_time;
                self.ui.current_time = current_time;
                self.ui.delta_time = delta_time;
                self.devtools_state.pushFrameTime(@as(f32, @floatCast(delta_time * 1000.0)));

                const current_fb = self.window.getFramebufferSize();
                if (current_fb.width != last_fb.width or current_fb.height != last_fb.height) {
                    self.ui.root.markDirty();
                    self.ui.requestLayout();
                    last_fb = current_fb;
                }

                self.ui.interaction_registry.updateInput(&self.window);
                self.ui.interaction_registry.processInteractions(self.ui.root, &self.window, current_time);
                self.ui.interaction_registry.drainExternalMessages();
                self.devtools_state.syncInteractionTargets(
                    self.ui.interaction_registry.hovered_node,
                    self.ui.interaction_registry.focused_node,
                );

                self.cross_thread_mutex.lockUncancelable(self.io);
                for (self.cross_thread_queue.items) |msg| {
                    self.ui.interaction_registry.message_queue.append(self.allocator, msg) catch |err| {
                        std.log.err("run: failed to append to UI message_queue: {s}", .{@errorName(err)});
                    };
                }
                self.cross_thread_queue.clearRetainingCapacity();
                self.cross_thread_mutex.unlock(self.io);

                var needs_rebuild = false;
                const uploaded_count = try self.engine.processPendingTextureUploads();
                if (uploaded_count > 0) {
                    self.ui.requestPaint();
                    if (self.build_fn != null) {
                        needs_rebuild = true;
                    }
                }

                if (self.tick_fn) |tick| {
                    self.applyUpdateAction(tick(self), &needs_rebuild);
                }

                for (self.ui.interaction_registry.message_queue.items) |msg| {
                    self.applyUpdateAction(self.update_fn(self, msg), &needs_rebuild);
                }
                self.ui.interaction_registry.message_queue.clearRetainingCapacity();

                if (self.devtools_state.consumeRebuildRequest() and self.build_fn != null) {
                    needs_rebuild = true;
                }
                if (self.ui.interaction_registry.rebuild_requested) {
                    needs_rebuild = true;
                    self.ui.interaction_registry.rebuild_requested = false;
                }

                if (!self.ui.paint_dirty) {
                    for (self.canvases.items) |canvas| {
                        if (canvas.is_dirty) {
                            self.ui.requestPaint();
                            break;
                        }
                    }
                }

                if (needs_rebuild) {
                    if (self.build_fn) |build| {
                        self.ui.building = true;
                        self.ui.use_arena = true;
                        self.ui.has_animated_images = false;
                        self.ui.min_animated_frame_ms = 0;
                        const new_root = try build(&self.ui, &self.state);
                        try self.appendDevToolsOverlay(new_root);
                        self.ui.use_arena = false;
                        self.ui.building = false;
                        try self.ui.reconcile(new_root);
                    }
                }

                if (self.ui.interaction_registry.layout_requested) {
                    self.ui.requestLayout();
                    self.ui.interaction_registry.layout_requested = false;
                }

                if (self.ui.interaction_registry.paint_requested) {
                    self.ui.requestPaint();
                    self.ui.interaction_registry.paint_requested = false;
                }

                if (self.ui.animation_registry.tick(current_time)) {
                    if (self.ui.animation_registry.hasLayoutAnimations()) {
                        self.ui.requestLayout();
                    } else {
                        self.ui.requestPaint();
                    }
                }

                if (self.ui.interaction_registry.hover_anim_active) {
                    const still_running = self.ui.root.tickHoverAnims(current_time);
                    self.ui.interaction_registry.hover_anim_active = still_running;
                    self.ui.requestPaint();
                }

                if (self.ui.layout_dirty) {
                    if (current_fb.width > 0 and current_fb.height > 0) {
                        var layout_passes: u8 = 0;
                        while (self.ui.layout_dirty and layout_passes < 2) {
                            self.ui.layout_dirty = false;
                            self.ui.animation_registry.applyAnimatedValuesToTree(self.ui.root, current_time);
                            try self.ui.calculateLayout(&self.font_system.text_layouter, @floatFromInt(current_fb.width), @floatFromInt(current_fb.height));
                            layout_passes += 1;
                        }
                    }
                }

                if (self.ui.paint_dirty) {
                    self.ui.animation_registry.applyAnimatedValuesToTree(self.ui.root, current_time);

                    const current_time_f32 = @as(f32, @floatCast(current_time));
                    try self.batcher.clear(self.engine.swapchain.extent);
                    try self.batcher.pushScissor(
                        0.0,
                        0.0,
                        @floatFromInt(self.engine.swapchain.extent.width),
                        @floatFromInt(self.engine.swapchain.extent.height),
                        .{ 0.0, 0.0, 0.0, 0.0 },
                    );
                    try self.ui.render(&self.batcher, &self.font_system.text_layouter, current_time_f32);
                    if (self.devtools_state.is_active) {
                        try self.devtools_state.renderHighlights(&self.batcher, self.ui.root);
                    }

                    const frame_rendered = try self.engine.draw(&self.batcher, self.canvases.items, &self.video_manager, &self.font_system.font_registry);
                    if (frame_rendered) {
                        self.ui.paint_dirty = false;
                    }
                }
            }
        }

        fn detachCanvasPayloads(node: *Node(MessageType), canvas: *Canvas) bool {
            var detached_any = false;

            if (node.payload == .canvas and node.payload.canvas.target == canvas) {
                node.payload = .none;
                node.markDirtyWithAncestors();
                detached_any = true;
            }

            for (node.children.items) |child| {
                if (detachCanvasPayloads(child, canvas)) {
                    detached_any = true;
                }
            }

            return detached_any;
        }

        fn applyUpdateAction(self: *Self, action: UpdateAction, needs_rebuild: *bool) void {
            switch (action) {
                .rebuild => needs_rebuild.* = true,
                .relayout => self.ui.requestLayout(),
                .repaint => self.ui.requestPaint(),
                .none => {},
            }
        }

        fn onKey(ptr: *anyopaque, key: i32, action: i32) void {
            const app: *Self = @ptrCast(@alignCast(ptr));
            if (key == glfw.KeyF12 and action == glfw.Press) {
                app.toggleDevTools();
            }
            app.ui.interaction_registry.pushKey(app.ui.root, key, action, &app.window);
        }

        fn onChar(ptr: *anyopaque, codepoint: u21) void {
            const app: *Self = @ptrCast(@alignCast(ptr));
            app.ui.interaction_registry.pushChar(codepoint);
        }

        fn onResize(ptr: *anyopaque) void {
            const app: *Self = @ptrCast(@alignCast(ptr));
            app.ui.root.markDirty();
            app.ui.requestLayout();
        }
    };
}
