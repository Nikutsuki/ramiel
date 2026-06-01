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
const devtools_tree_scroll_id = @import("devtools/state.zig").tree_scroll_id;
const buildDevToolsPanel = @import("devtools/ui.zig").buildDevToolsPanel;
const win_mod = @import("window/window.zig");
const platform = @import("platform/backend.zig");
const app_backend = @import("platform/app_backend.zig");
pub const HotkeyFn = win_mod.HotkeyFn;
const tracy = @import("tracy");
const VideoManager = @import("video/manager.zig").VideoManager;
const Theme = @import("ui/theme.zig").Theme;
const layout = @import("ui/layout.zig");

const FontSource = @import("renderer/font/font_registry.zig").FontSource;
const FontData = @import("renderer/font/font_registry.zig").FontData;
const font_registry_mod = @import("renderer/font/font_registry.zig");
const font_system_mod = @import("renderer/font/font_system.zig");
const TextureId = @import("assets.zig").TextureId;
const TextureState = @import("renderer/vulkan/texture_registry.zig").TextureState;
const ImageIngressBudget = @import("renderer/image_ingress.zig").ImageIngressBudget;
const ImageFallbackState = @import("ui/node.zig").RenderPayload.ImageFallbackState;
const AnimatedState = @import("renderer/image_animation.zig").AnimatedState;
const Canvas = @import("renderer/canvas.zig").Canvas;
const PixelBuffer = @import("renderer/pixel_buffer.zig").PixelBuffer;
const shader_compiler = @import("renderer/shader_compiler.zig");
const compute_canvas = @import("renderer/vulkan/compute_canvas.zig");
const fragment_canvas = @import("renderer/vulkan/fragment_canvas.zig");
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
        backend: app_backend.Backend,
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
        input_region_rects: std.ArrayList(platform.InputRegionRect),
        state: StateType,
        cross_thread_mutex: std.Io.Mutex = .init,
        cross_thread_queue: std.ArrayList(InteractionMessage(MessageType)),
        file_dialog_task: ?std.Io.Future(void) = null,
        file_dialog_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        file_dialog_result_mutex: std.Io.Mutex = .init,
        file_dialog_result: ?[]const u8 = null,
        video_poll_hz: f64 = 60.0,
        backend_key_handler: ?*const fn (key: u32, state: u32) void = null,

        update_fn: *const fn (app: *Self, msg: InteractionMessage(MessageType)) UpdateAction,

        tick_fn: ?*const fn (app: *Self) UpdateAction = null,

        /// glfwWaitEventsTimeout cadence so tick_fn fires without input. null = wait indefinitely.
        tick_interval_s: ?f64 = null,

        last_frame_time: f64 = 0.0,
        initial_tree_mounted: bool = false,

        build_fn: ?*const fn (ui: *UIContext(MessageType), state: *const StateType) anyerror!*Node(MessageType) = null,

        reload_hook: ?*const ReloadHook = null,
        reload_error: ?[]u8 = null,
        reload_error_version: u32 = 0,

        pub const ReloadHook = struct {
            ctx: *anyopaque,
            pending_fn: *const fn (*anyopaque) bool,
            perform_fn: *const fn (*anyopaque, *Self, *bool) anyerror!void,
            request_fn: *const fn (*anyopaque) void,
            error_version_fn: *const fn (*anyopaque) u32,
            copy_error_fn: *const fn (*anyopaque, std.mem.Allocator) ?[]u8,

            pub fn pending(self: *const ReloadHook) bool {
                return self.pending_fn(self.ctx);
            }
            pub fn perform(self: *const ReloadHook, app: *Self, needs_rebuild: *bool) anyerror!void {
                return self.perform_fn(self.ctx, app, needs_rebuild);
            }
            pub fn request(self: *const ReloadHook) void {
                self.request_fn(self.ctx);
            }
            pub fn errorVersion(self: *const ReloadHook) u32 {
                return self.error_version_fn(self.ctx);
            }
            pub fn copyError(self: *const ReloadHook, allocator: std.mem.Allocator) ?[]u8 {
                return self.copy_error_fn(self.ctx, allocator);
            }
        };

        pub const FileDialogCallback = *const fn (path: ?[]const u8) MessageType;

        const FileDialogCompletion = union(enum) {
            callback: FileDialogCallback,
            message: MessageType,
        };

        const FileDialogKind = enum { file, folder, save };

        const FileDialogTaskArgs = struct {
            self: *Self,
            kind: FileDialogKind,
            filter_list: ?[:0]const u8,
            completion: FileDialogCompletion,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            config: platform.AppBackendConfig,
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

            var win = try app_backend.Backend.init(effective_allocator, config);
            errdefer win.deinit();
            const engine = try effective_allocator.create(Engine);
            errdefer effective_allocator.destroy(engine);
            engine.* = try Engine.initWithSurface(
                effective_allocator,
                io,
                win.renderSurface(),
                win.nativeGlfwWindow(),
                config.transparent,
                .{ .sample_count = .{ .@"16_bit" = true } },
            );
            errdefer engine.deinit();

            switch (config.surface_kind) {
                .overlay, .popup_launcher => win.configureAsOverlay(),
                else => {},
            }
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
            if (win.primaryRefreshRateHz()) |hz| {
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
                .backend = win,
                .engine = engine,
                .font_system = font_system,
                .audio_engine = audio_engine,
                .batcher = batcher,
                .ui = ui,
                .canvases = .empty,
                .input_region_rects = .empty,
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

        pub const ComputeInputImage = @import("renderer/canvas.zig").ComputeInputImage;

        pub fn createComputeCanvasSpirv(self: *Self, width: u32, height: u32, spirv: []const u32, input_image: ?ComputeInputImage) !*Canvas {
            const canvas = try Canvas.initCompute(
                self.allocator,
                &self.engine.core,
                &self.engine.resources.texture_registry,
                width,
                height,
                spirv,
                input_image,
            );
            errdefer canvas.deinit(&self.engine.core, &self.engine.resources.texture_registry);

            try self.canvases.append(self.allocator, canvas);
            return canvas;
        }

        pub fn createComputeCanvas(self: *Self, width: u32, height: u32, glsl_source: []const u8, input_image: ?ComputeInputImage) !*Canvas {
            var compiler = try shader_compiler.Compiler.init();
            defer compiler.deinit();

            var diagnostic: []u8 = &.{};
            const spirv = compiler.compile(self.allocator, glsl_source, .compute, "compute_canvas", &diagnostic) catch |err| {
                if (diagnostic.len > 0) {
                    std.log.err("compute canvas shader compilation failed:\n{s}", .{diagnostic});
                    self.allocator.free(diagnostic);
                }
                return err;
            };
            defer self.allocator.free(spirv);

            return self.createComputeCanvasSpirv(width, height, spirv, input_image);
        }

        pub fn createShaderCanvas(self: *Self, width: u32, height: u32, fragment_glsl: []const u8, input_image: ?ComputeInputImage) !*Canvas {
            var compiler = try shader_compiler.Compiler.init();
            defer compiler.deinit();

            var diagnostic: []u8 = &.{};
            const vert_spirv = compiler.compile(self.allocator, fragment_canvas.fullscreen_vertex_glsl, .vertex, "fullscreen.vert", null) catch |err| return err;
            defer self.allocator.free(vert_spirv);

            const frag_spirv = compiler.compile(self.allocator, fragment_glsl, .fragment, "shader_canvas", &diagnostic) catch |err| {
                if (diagnostic.len > 0) {
                    std.log.err("shader canvas fragment compilation failed:\n{s}", .{diagnostic});
                    self.allocator.free(diagnostic);
                }
                return err;
            };
            defer self.allocator.free(frag_spirv);

            const canvas = try Canvas.initFragment(
                self.allocator,
                &self.engine.core,
                &self.engine.resources.texture_registry,
                width,
                height,
                vert_spirv,
                frag_spirv,
                input_image,
            );
            errdefer canvas.deinit(&self.engine.core, &self.engine.resources.texture_registry);

            try self.canvases.append(self.allocator, canvas);
            return canvas;
        }

        pub fn resizeShaderCanvas(self: *Self, canvas: *Canvas, width: u32, height: u32) !void {
            const backing = canvas.fragment orelse return;
            if (width == backing.width and height == backing.height) return;
            self.engine.core.vkd.deviceWaitIdle(self.engine.core.logical_device) catch {};
            try backing.resize(&self.engine.core, &self.engine.resources.texture_registry, width, height);
            canvas.width = width;
            canvas.height = height;
        }

        pub fn runComputeFilter(self: *Self, glsl_source: []const u8, width: u32, height: u32, input_pixels: []const u8, output_pixels: []u8, params: []const [4]f32) !void {
            var compiler = try shader_compiler.Compiler.init();
            defer compiler.deinit();

            var diagnostic: []u8 = &.{};
            const spirv = compiler.compile(self.allocator, glsl_source, .compute, "compute_filter", &diagnostic) catch |err| {
                if (diagnostic.len > 0) {
                    std.log.err("compute filter shader compilation failed:\n{s}", .{diagnostic});
                    self.allocator.free(diagnostic);
                }
                return err;
            };
            defer self.allocator.free(spirv);

            var uniforms = compute_canvas.Uniforms{};
            const n = @min(params.len, uniforms.user.len);
            for (0..n) |i| uniforms.user[i] = params[i];

            try compute_canvas.runFilterOnce(&self.engine.core, spirv, width, height, input_pixels, output_pixels, uniforms);
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

        fn beginFileDialog(
            self: *Self,
            kind: FileDialogKind,
            filter_list: ?[:0]const u8,
            completion: FileDialogCompletion,
        ) void {
            // Reap a finished prior task if one is sitting around.
            self.reapFileDialogIfDone();
            if (self.file_dialog_task != null) {
                std.log.warn("File dialog task already in progress.", .{});
                return;
            }

            self.file_dialog_done.store(false, .release);
            self.file_dialog_task = self.io.concurrent(fileDialogWorker, .{.{
                .self = self,
                .kind = kind,
                .filter_list = filter_list,
                .completion = completion,
            }}) catch |err| {
                std.log.err("Failed to spawn file dialog task: {s}", .{@errorName(err)});
                self.completeFileDialog(completion, null);
                self.file_dialog_done.store(true, .release);
                return;
            };
        }

        pub fn openFileDialog(self: *Self, filter_list: ?[:0]const u8, callback: FileDialogCallback) void {
            self.beginFileDialog(.file, filter_list, .{ .callback = callback });
        }

        /// Opens a native file dialog and posts `completion_msg` when it closes.
        /// The selected path is stored on the app; consume it with
        /// `takeFileDialogResult()` in the reducer that handles `completion_msg`.
        /// This avoids storing a result callback pointer in hot-reloadable app code.
        pub fn openFileDialogMessage(self: *Self, filter_list: ?[:0]const u8, completion_msg: MessageType) void {
            self.beginFileDialog(.file, filter_list, .{ .message = completion_msg });
        }

        pub fn openSaveFileDialogMessage(self: *Self, filter_list: ?[:0]const u8, completion_msg: MessageType) void {
            self.beginFileDialog(.save, filter_list, .{ .message = completion_msg });
        }

        pub fn openFolderDialog(self: *Self, callback: FileDialogCallback) void {
            self.beginFileDialog(.folder, null, .{ .callback = callback });
        }

        /// Opens a native folder dialog and posts `completion_msg` when it closes.
        /// The selected path is stored on the app; consume it with
        /// `takeFileDialogResult()` in the reducer that handles `completion_msg`.
        pub fn openFolderDialogMessage(self: *Self, completion_msg: MessageType) void {
            self.beginFileDialog(.folder, null, .{ .message = completion_msg });
        }

        fn reapFileDialogIfDone(self: *Self) void {
            if (self.file_dialog_task == null) return;
            if (!self.file_dialog_done.load(.acquire)) return;
            if (self.file_dialog_task) |*task| {
                _ = task.await(self.io);
                self.file_dialog_task = null;
            }
        }

        pub fn fileDialogPending(self: *Self) bool {
            self.reapFileDialogIfDone();
            return self.file_dialog_task != null;
        }

        fn setFileDialogResult(self: *Self, path: ?[]const u8) void {
            self.file_dialog_result_mutex.lockUncancelable(self.io);
            defer self.file_dialog_result_mutex.unlock(self.io);
            if (self.file_dialog_result) |old| self.allocator.free(old);
            self.file_dialog_result = path;
        }

        /// Takes ownership of the last path produced by `openFileDialogMessage` or
        /// `openFolderDialogMessage`. The caller must free the returned slice with
        /// the app allocator, or transfer ownership into app state.
        pub fn takeFileDialogResult(self: *Self) ?[]const u8 {
            self.file_dialog_result_mutex.lockUncancelable(self.io);
            defer self.file_dialog_result_mutex.unlock(self.io);
            const result = self.file_dialog_result;
            self.file_dialog_result = null;
            return result;
        }

        fn completeFileDialog(self: *Self, completion: FileDialogCompletion, path: ?[]const u8) void {
            switch (completion) {
                .callback => |callback| self.postMessageId(callback(path)),
                .message => |message| {
                    self.setFileDialogResult(path);
                    self.postMessageId(message);
                },
            }
        }

        fn fileDialogWorker(args: FileDialogTaskArgs) void {
            const self = args.self;

            const maybe_raw_path = switch (args.kind) {
                .file => nfd.openFileDialog(args.filter_list, null) catch |err| {
                    std.log.err("NFD openFileDialog failed: {s}", .{@errorName(err)});
                    self.completeFileDialog(args.completion, null);
                    self.file_dialog_done.store(true, .release);
                    return;
                },
                .folder => nfd.openFolderDialog(null) catch |err| {
                    std.log.err("NFD openFolderDialog failed: {s}", .{@errorName(err)});
                    self.completeFileDialog(args.completion, null);
                    self.file_dialog_done.store(true, .release);
                    return;
                },
                .save => nfd.saveFileDialog(args.filter_list, null) catch |err| {
                    std.log.err("NFD saveFileDialog failed: {s}", .{@errorName(err)});
                    self.completeFileDialog(args.completion, null);
                    self.file_dialog_done.store(true, .release);
                    return;
                },
            };

            var final_path: ?[]const u8 = null;
            if (maybe_raw_path) |raw_path| {
                defer nfd.freePath(raw_path);
                final_path = self.allocator.dupe(u8, raw_path) catch |err| blk: {
                    std.log.err("Failed to duplicate selected dialog path: {s}", .{@errorName(err)});
                    break :blk null;
                };
            }

            self.completeFileDialog(args.completion, final_path);
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
            self.ui.setFontSystem(&self.font_system);
        }

        pub fn setDefaultFontFamily(self: *Self, family_name: []const u8) void {
            self.ui.setDefaultFamily(family_name);
            self.ui.setFontSystem(&self.font_system);
        }

        pub fn loadDefaultFont(self: *Self, name: []const u8, source: FontSource, base_resolution: u32) !*FontData {
            const font = try self.loadFont(name, source, base_resolution);
            self.setDefaultFont(font);
            self.setDefaultFontFamily(name);
            return font;
        }

        pub fn loadFontVariant(
            self: *Self,
            family_name: []const u8,
            variant: font_registry_mod.FontVariant,
            physical_name: []const u8,
            source: FontSource,
            base_resolution: u32,
        ) !*FontData {
            return self.font_system.loadFontVariant(
                &self.engine.core,
                &self.engine.resources.texture_registry,
                family_name,
                variant,
                physical_name,
                source,
                base_resolution,
            );
        }

        pub fn loadFontFamily(
            self: *Self,
            family_name: []const u8,
            sources: font_system_mod.FamilySources,
            base_resolution: u32,
        ) !*FontData {
            return self.font_system.loadFontFamily(
                &self.engine.core,
                &self.engine.resources.texture_registry,
                family_name,
                sources,
                base_resolution,
            );
        }

        pub fn loadDefaultFontFamily(
            self: *Self,
            family_name: []const u8,
            sources: font_system_mod.FamilySources,
            base_resolution: u32,
        ) !*FontData {
            const font = try self.loadFontFamily(family_name, sources, base_resolution);
            self.setDefaultFont(font);
            self.setDefaultFontFamily(family_name);
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
                std.debug.panic("requireFont: '{s}' not loaded - call app.loadFont(\"{s}\", ...) first", .{ name, name });
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
            try self.ui.animation_registry.register(entry, self.backend.timeSeconds());
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
            try self.appendReloadErrorOverlay(root);
            try self.ui.mountRoot(root);
            self.initial_tree_mounted = true;
        }

        pub fn wireResolvers(self: *Self) void {
            self.wireImageResolver();
            self.wireIconResolver();
        }

        pub fn forceRemount(self: *Self) !void {
            self.initial_tree_mounted = false;
            try self.mountRoot();
        }

        pub fn setReloadHook(self: *Self, hook: *const ReloadHook) void {
            self.reload_hook = hook;
        }

        /// Only needed for an app that overrode the clipboard fns with `.so` code.
        pub fn resetClipboardToBackend(self: *Self) void {
            self.ui.interaction_registry.clipboard_ctx = &self.backend;
            self.ui.interaction_registry.clipboard_get_fn = clipboardGet;
            self.ui.interaction_registry.clipboard_set_fn = clipboardSet;
        }

        pub fn setDevToolsActive(self: *Self, active: bool) void {
            if (!build_options.devtools) return;
            self.devtools_state.setActive(active);
        }

        pub fn toggleDevTools(self: *Self) void {
            if (!build_options.devtools) return;
            self.devtools_state.toggle();
        }

        pub fn setDevToolsTab(self: *Self, tab: DevToolsTab) void {
            if (!build_options.devtools) return;
            self.devtools_state.setTab(tab);
        }

        pub fn getDevToolsState(self: *Self) *DevToolsState(MessageType) {
            return &self.devtools_state;
        }

        fn appendDevToolsOverlay(self: *Self, root: *Node(MessageType)) !void {
            if (!build_options.devtools) return;
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

        fn appendReloadErrorOverlay(self: *Self, root: *Node(MessageType)) !void {
            const err = self.reload_error orelse return;
            const font = self.ui.getDefaultFont() orelse self.font_system.getFont("JetBrains Mono") orelse return;
            const alloc = if (self.ui.use_arena) self.ui.build_arena.allocator() else self.allocator;

            const clean = try sanitizeForDisplay(alloc, err);
            defer alloc.free(clean);
            const max_len: usize = 1800;
            const shown = if (clean.len > max_len) clean[0..max_len] else clean;
            const msg = try std.fmt.allocPrint(alloc, "hot reload: build failed\n\n{s}", .{shown});
            defer alloc.free(msg);

            const fb = self.backend.getFramebufferSize();
            const wrap_w = @max(120.0, @as(f32, @floatFromInt(fb.width)) - 32.0);

            var text_style: layout.Style = .{};
            text_style.text_color = .{ 1.0, 0.86, 0.86, 1.0 };
            text_style.font_size = 13.0;
            const text_node = try self.ui.text(.{ .content = msg, .font = font, .style = text_style, .max_width = wrap_w });

            var banner_style: layout.Style = .{};
            banner_style.position = .absolute;
            banner_style.left = 0.0;
            banner_style.top = 0.0;
            banner_style.right = 0.0;
            banner_style.background_color = .{ 0.16, 0.02, 0.03, 0.95 };
            banner_style.padding = .{ .top = 12.0, .bottom = 12.0, .left = 16.0, .right = 16.0 };
            banner_style.direction = .Column;
            const banner = try self.ui.div(.{ .style = banner_style, .children = &.{text_node} });
            try root.addChild(banner);
        }

        /// Drop ANSI escape sequences and stray control bytes so the text renderer
        /// only sees printable characters, newlines, and tabs-as-spaces.
        fn sanitizeForDisplay(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
            const buf = try alloc.alloc(u8, raw.len);
            defer alloc.free(buf);
            var j: usize = 0;
            var i: usize = 0;
            while (i < raw.len) {
                const c = raw[i];
                if (c == 0x1b) {
                    i += 1;
                    if (i < raw.len and raw[i] == '[') {
                        i += 1;
                        while (i < raw.len and !(raw[i] >= 0x40 and raw[i] <= 0x7e)) i += 1;
                        if (i < raw.len) i += 1;
                    }
                    continue;
                }
                if (c == '\t') {
                    buf[j] = ' ';
                    j += 1;
                } else if (c == '\n' or c >= 0x20) {
                    buf[j] = c;
                    j += 1;
                }
                i += 1;
            }
            return alloc.dupe(u8, buf[0..j]);
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

            if (self.devtools_state.is_active and self.devtools_state.active_tab == .profiler) {
                const devtools_timeout = 1.0 / 60.0;
                timeout = if (timeout) |t| @min(t, devtools_timeout) else devtools_timeout;
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
                is_ctrl: bool,
                is_shift: bool,
            ) bool,
        ) void {
            const Trampoline = struct {
                fn call(
                    opaque_ctx: ?*anyopaque,
                    ir: *@import("ui/interaction.zig").InteractionRegistry(MessageType),
                    key: i32,
                    action: i32,
                    is_ctrl: bool,
                    is_shift: bool,
                ) bool {
                    const typed: *CtxT = @ptrCast(@alignCast(opaque_ctx.?));
                    return handler(typed, ir, key, action, is_ctrl, is_shift);
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
            self.backend.postEmptyEvent();
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
            if (self.file_dialog_result) |path| self.allocator.free(path);
            if (self.reload_error) |e| self.allocator.free(e);
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
            self.input_region_rects.deinit(self.allocator);

            self.font_system.deinit(&self.engine.core);
            self.engine.deinit();
            self.allocator.destroy(self.engine);
            self.backend.deinit();

            if (self.tracy_allocator) |wrapped| {
                self.parent_allocator.destroy(wrapped);
                self.tracy_allocator = null;
            }
        }

        pub fn setTickFn(self: *Self, tick: *const fn (*Self) UpdateAction, interval_s: f64) void {
            self.tick_fn = tick;
            self.tick_interval_s = interval_s;
        }

        pub fn setBackendKeyHandler(self: *Self, handler: *const fn (key: u32, state: u32) void) void {
            self.backend_key_handler = handler;
        }

        pub fn isVisible(self: *const Self) bool {
            return self.backend.isVisible();
        }

        pub fn getFramebufferSize(self: *const Self) platform.FramebufferSize {
            return self.backend.getFramebufferSize();
        }

        pub fn getCursorPos(self: *const Self) platform.CursorPosition {
            return self.backend.getCursorPos();
        }

        pub fn isMouseButtonDown(self: *const Self, button: i32) bool {
            return self.backend.isMouseButtonDown(button);
        }

        pub fn isKeyDown(self: *const Self, key: i32) bool {
            return self.backend.isKeyDown(key);
        }

        pub fn postEmptyEvent(self: *Self) void {
            self.backend.postEmptyEvent();
        }

        pub fn setVisibility(self: *Self, visible: bool) void {
            if (visible == self.isVisible()) return;
            const needs_surface_cycle = self.backend.kind() == .wayland;
            if (visible) {
                self.backend.show();
                if (needs_surface_cycle) {
                    self.engine.resumeSurface(self.backend.renderSurface()) catch |err| {
                        std.log.err("setVisibility: resumeSurface failed: {s}", .{@errorName(err)});
                    };
                }
                self.ui.requestLayout();
                self.ui.requestPaint();
            } else {
                if (needs_surface_cycle) {
                    self.engine.suspendSurface() catch |err| {
                        std.log.err("setVisibility: suspendSurface failed: {s}", .{@errorName(err)});
                    };
                }
                self.backend.hide();
                self.ui.interaction_registry.resetForNewTree();
            }
        }

        /// Grab or release keyboard focus at runtime (layer-shell only). Lets a
        /// normally non-interactive surface (e.g. a bar) take exclusive keyboard
        /// while an overlay like a launcher is open.
        pub fn setKeyboardInteractivity(self: *Self, mode: platform.KeyboardInteractivity) void {
            self.backend.setKeyboardInteractivity(mode);
        }

        fn syncAutoInputRegion(self: *Self) void {
            if (self.backend.inputRegionMode() != .auto_interactive) return;

            self.input_region_rects.clearRetainingCapacity();
            const fb = self.backend.getFramebufferSize();
            self.collectInputRegionRects(self.ui.root, fb) catch |err| {
                std.log.warn("syncAutoInputRegion: failed to collect regions: {s}", .{@errorName(err)});
                return;
            };
            self.backend.setInputRegion(self.input_region_rects.items);
        }

        fn collectInputRegionRects(self: *Self, node: *Node(MessageType), fb: platform.FramebufferSize) !void {
            if (node.style.pointer_events == .none) return;

            if (nodeNeedsInput(node)) {
                try self.appendInputRegionRect(node.getTransformedRect(), fb);
            }

            for (node.children.items) |child| {
                try self.collectInputRegionRects(child, fb);
            }
        }

        fn appendInputRegionRect(self: *Self, rect: Node(MessageType).TransformedRect, fb: platform.FramebufferSize) !void {
            if (rect.width <= 0.0 or rect.height <= 0.0 or fb.width <= 0 or fb.height <= 0) return;

            const x0: i32 = @intFromFloat(@floor(rect.x));
            const y0: i32 = @intFromFloat(@floor(rect.y));
            const x1: i32 = @intFromFloat(@ceil(rect.x + rect.width));
            const y1: i32 = @intFromFloat(@ceil(rect.y + rect.height));

            const left = std.math.clamp(x0, 0, fb.width);
            const top = std.math.clamp(y0, 0, fb.height);
            const right = std.math.clamp(x1, 0, fb.width);
            const bottom = std.math.clamp(y1, 0, fb.height);
            if (right <= left or bottom <= top) return;

            try self.input_region_rects.append(self.allocator, .{
                .x = left,
                .y = top,
                .width = right - left,
                .height = bottom - top,
            });
        }

        fn nodeNeedsInput(node: *const Node(MessageType)) bool {
            if (node.is_focusable) return true;
            if (node.style.overflow_x == .scroll or node.style.overflow_y == .scroll) return true;
            return switch (node.payload) {
                .text_input, .text_area => true,
                else => hasPointerEvent(node),
            };
        }

        fn hasPointerEvent(node: *const Node(MessageType)) bool {
            return node.hasEventBinding(.click) or
                node.hasEventBinding(.pointer_down) or
                node.hasEventBinding(.pointer_up) or
                node.hasEventBinding(.drag) or
                node.hasEventBinding(.hover_enter) or
                node.hasEventBinding(.hover_exit) or
                node.hasEventBinding(.scroll) or
                node.hasEventBinding(.pointer_move) or
                node.hasEventBinding(.context_menu);
        }

        /// callback's user_ptr is the Application. modifier: win32.MOD_*; key: VK_* code.
        pub fn registerGlobalHotkey(self: *Self, modifier: u32, key: u32, callback: HotkeyFn) !void {
            try self.backend.registerGlobalHotkey(modifier, key, self, callback);
        }

        pub fn run(self: *Self) !void {
            self.backend.rebindListeners();
            self.backend.registerCallbacks(self, onKey, onChar, onResize);
            self.ui.interaction_registry.clipboard_ctx = &self.backend;
            self.ui.interaction_registry.clipboard_get_fn = clipboardGet;
            self.ui.interaction_registry.clipboard_set_fn = clipboardSet;
            try self.mountRoot();

            const initial_fb = self.backend.getFramebufferSize();
            try self.ui.calculateLayout(&self.font_system.text_layouter, @floatFromInt(initial_fb.width), @floatFromInt(initial_fb.height));
            var last_fb = initial_fb;
            self.last_frame_time = self.backend.timeSeconds();
            // Wayland: waitEvents() blocks until the first surface commit.
            self.ui.requestPaint();
            var first_iteration = true;

            while (!self.backend.shouldClose()) {
                self.audio_engine.registry.processAudioCleanup();

                if (!self.backend.isVisible()) {
                    self.backend.waitEvents();

                    // Drain cross-thread messages even while hidden so that
                    // IPC activation requests (show/toggle) are processed.
                    self.cross_thread_mutex.lockUncancelable(self.io);
                    for (self.cross_thread_queue.items) |msg| {
                        self.ui.interaction_registry.message_queue.append(self.allocator, msg) catch |err| {
                            std.log.err("run: failed to append to UI message_queue: {s}", .{@errorName(err)});
                        };
                    }
                    self.cross_thread_queue.clearRetainingCapacity();
                    self.cross_thread_mutex.unlock(self.io);

                    for (self.ui.interaction_registry.message_queue.items) |msg| {
                        var needs_rebuild_hidden = false;
                        self.applyUpdateAction(self.update_fn(self, msg), &needs_rebuild_hidden);
                    }
                    self.ui.interaction_registry.message_queue.clearRetainingCapacity();

                    if (self.reload_hook) |hook| {
                        if (hook.pending()) {
                            var nr_hidden = false;
                            hook.perform(self, &nr_hidden) catch |err| {
                                std.log.err("hotreload: reload failed: {s}; continuing with current code", .{@errorName(err)});
                            };
                        }
                    }

                    continue;
                }

                if (first_iteration) {
                    self.backend.pollEvents();
                    first_iteration = false;
                } else if (self.computeWaitTimeoutSeconds()) |timeout_s| {
                    self.backend.waitEventsTimeout(timeout_s);
                } else {
                    self.backend.waitEvents();
                }

                const video_frame_ready = try self.video_manager.tick(
                    self.engine.frames.current_frame_index,
                );

                if (video_frame_ready) {
                    self.ui.requestPaint();
                }

                if (self.ui.has_animated_images) self.ui.requestPaint();

                const current_time = self.backend.timeSeconds();
                const delta_time = current_time - self.last_frame_time;
                self.last_frame_time = current_time;
                self.ui.current_time = current_time;
                self.ui.delta_time = delta_time;
                self.devtools_state.pushFrameTime(@as(f32, @floatCast(delta_time * 1000.0)));

                const current_fb = self.backend.getFramebufferSize();
                if (current_fb.width != last_fb.width or current_fb.height != last_fb.height) {
                    self.ui.root.markDirty();
                    self.ui.requestLayout();
                    self.ui.interaction_registry.rebuild_requested = true;
                    last_fb = current_fb;
                }

                self.ui.interaction_registry.picking = self.devtools_state.pick_mode;
                self.ui.interaction_registry.updateInputSnapshot(self.backend.pointerInputSnapshot());
                self.ui.interaction_registry.processInteractionsWithBackend(self.ui.root, &self.backend, current_time);
                self.backend.drainQueuedInputEvents(MessageType, self.ui.root, &self.ui.interaction_registry, self.backend_key_handler);
                self.ui.interaction_registry.drainExternalMessages();
                if (self.devtools_state.pick_mode) {
                    self.devtools_state.pickHover(self.ui.interaction_registry.hovered_node);
                    if (self.ui.interaction_registry.mouse_just_pressed) {
                        self.devtools_state.commitPick(self.ui.interaction_registry.hovered_node);
                    }
                    self.ui.requestPaint();
                } else {
                    self.devtools_state.syncInteractionTargets(
                        self.ui.interaction_registry.hovered_node,
                        self.ui.interaction_registry.focused_node,
                    );
                }

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

                if (self.reload_hook) |hook| {
                    if (hook.pending()) {
                        hook.perform(self, &needs_rebuild) catch |err| {
                            std.log.err("hotreload: reload failed: {s}; continuing with current code", .{@errorName(err)});
                        };
                    }
                    const ev = hook.errorVersion();
                    if (ev != self.reload_error_version) {
                        self.reload_error_version = ev;
                        if (self.reload_error) |e| self.allocator.free(e);
                        self.reload_error = hook.copyError(self.allocator);
                        needs_rebuild = true;
                    }
                }

                if (self.devtools_state.consumeRebuildRequest() and self.build_fn != null) {
                    needs_rebuild = true;
                }
                if (self.devtools_state.is_active) {
                    self.devtools_state.captureTreeMetrics(self.ui.root);
                    if (self.devtools_state.consumeHighlightChange()) self.ui.requestPaint();
                    // Only the Profiler tab needs a steady cadence (live FPS graph).
                    // Other tabs stay event-driven so an idle window does not render.
                    if (self.devtools_state.active_tab == .profiler) {
                        self.ui.requestPaint();
                        if (self.build_fn != null) needs_rebuild = true;
                    }
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
                        // Apply overrides to the live tree first so the DevTools
                        // overlay (Computed panel) reads the just-edited style this
                        // frame instead of lagging one edit behind.
                        if (self.devtools_state.is_active) {
                            self.devtools_state.applyOverrides(self.ui.root);
                        }
                        self.ui.building = true;
                        self.ui.use_arena = true;
                        self.ui.has_animated_images = false;
                        self.ui.min_animated_frame_ms = 0;
                        const new_root = try build(&self.ui, &self.state);
                        try self.appendDevToolsOverlay(new_root);
                        try self.appendReloadErrorOverlay(new_root);
                        self.ui.use_arena = false;
                        self.ui.building = false;
                        try self.ui.reconcile(new_root);
                        if (self.devtools_state.is_active) {
                            self.devtools_state.applyOverrides(self.ui.root);
                            self.ui.requestLayout();
                            self.ui.requestPaint();
                            if (self.devtools_state.scroll_to_selected) {
                                if (self.ui.getById(devtools_tree_scroll_id)) |scroll_node| {
                                    if (self.devtools_state.computeTreeScroll(self.ui.root)) |y| {
                                        scroll_node.scroll_y = y;
                                    }
                                }
                                self.devtools_state.scroll_to_selected = false;
                            }
                        }
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
                    self.syncAutoInputRegion();

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
                        self.devtools_state.captureGraphicsMetrics(&self.batcher);
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
            if (key == glfw.KeyEscape and action == glfw.Press and app.devtools_state.pick_mode) {
                app.devtools_state.togglePickMode();
            }
            if (key == glfw.KeyF5 and action == glfw.Press) {
                if (app.reload_hook) |hook| hook.request();
            }
            const is_ctrl = app.backend.isKeyDown(glfw.KeyLeftControl) or app.backend.isKeyDown(glfw.KeyRightControl);
            const is_shift = app.backend.isKeyDown(glfw.KeyLeftShift) or app.backend.isKeyDown(glfw.KeyRightShift);
            app.ui.interaction_registry.pushKey(app.ui.root, key, action, is_ctrl, is_shift);
        }

        fn onChar(ptr: *anyopaque, codepoint: u21) void {
            const app: *Self = @ptrCast(@alignCast(ptr));
            const ctrl_down = app.backend.isKeyDown(glfw.KeyLeftControl) or app.backend.isKeyDown(glfw.KeyRightControl);
            const alt_down = app.backend.isKeyDown(glfw.KeyLeftAlt) or app.backend.isKeyDown(glfw.KeyRightAlt);
            const super_down = app.backend.isKeyDown(glfw.KeyLeftSuper) or app.backend.isKeyDown(glfw.KeyRightSuper);
            const altgr = ctrl_down and alt_down;
            if (super_down or ((ctrl_down or alt_down) and !altgr)) return;
            app.ui.interaction_registry.pushChar(codepoint);
        }

        fn onResize(ptr: *anyopaque) void {
            const app: *Self = @ptrCast(@alignCast(ptr));
            app.ui.root.markDirty();
            app.ui.requestLayout();
        }

        fn clipboardGet(ctx: ?*anyopaque) ?[:0]const u8 {
            const backend: *app_backend.Backend = @ptrCast(@alignCast(ctx.?));
            return backend.getClipboardString();
        }

        fn clipboardSet(ctx: ?*anyopaque, str: [:0]const u8) void {
            const backend: *app_backend.Backend = @ptrCast(@alignCast(ctx.?));
            backend.setClipboardString(str);
        }
    };
}
