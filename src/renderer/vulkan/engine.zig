const std = @import("std");
const builtin = @import("builtin");
const vk = @import("../../vk.zig");
const glfw = @import("glfw");

const Core = @import("core.zig").Core;
const Swapchain = @import("swapchain.zig").Swapchain;
const RenderPass = @import("render_pass.zig").VulkanRenderPass;
const Pipeline = @import("pipeline.zig").Pipeline;
const Vertex = @import("vertex.zig").Vertex;
const Mat4 = @import("math.zig").Mat4;
const QuadBatcher = @import("batcher.zig").QuadBatcher;
const LayerEntry = @import("batcher.zig").LayerEntry;
const DrawCommand = @import("batcher.zig").DrawCommand;
const Buffer = @import("buffer.zig").Buffer;
const RenderTexture = @import("render_texture.zig").RenderTexture;
const YuvTexture = @import("yuv_texture.zig").YuvTexture;
const vk_common = @import("vk_common.zig");
const c = vk_common.c;
const assets = @import("../../assets.zig");
const DxgiOverlay = @import("../../window/dxgi_overlay.zig").DxgiOverlay;

const FrameManager = @import("frame_manager.zig").FrameManager;
const FrameContext = @import("frame_manager.zig").FrameContext;
const ResourceManager = @import("resource_manager.zig").ResourceManager;
const GlobalUniforms = @import("resource_manager.zig").GlobalUniforms;
const BlurEffect = @import("post_process.zig").BlurEffect;
const TextureState = @import("texture_registry.zig").TextureState;
const ImageIngress = @import("../image_ingress.zig").ImageIngress;
const ImageIngressBudget = @import("../image_ingress.zig").ImageIngressBudget;
const Canvas = @import("../canvas.zig").Canvas;
const VideoManager = @import("../../video/manager.zig").VideoManager;
const FontRegistry = @import("../font/font_registry.zig").FontRegistry;

const render_graph_module = @import("render_graph.zig");
const RenderGraph = render_graph_module.RenderGraph;
const ResourceHandle = render_graph_module.ResourceHandle;
const ResourceUsage = render_graph_module.ResourceUsage;
const ResourceState = render_graph_module.ResourceState;

const INITIAL_MAX_VERTICES: usize = 65536;
const INITIAL_MAX_INDICES: usize = 98304; // 65536 * 1.5 - exact quad mesh ratio
const KAWASE_HANDLE_BASE: u32 = 10;
const MAX_BINDLESS = Pipeline.MAX_BINDLESS_TEXTURES;
const MAX_RENDER_PASSES = 128;
const MAX_UI_CONTEXTS = MAX_RENDER_PASSES;
const MAX_COPY_CONTEXTS = MAX_RENDER_PASSES;
const MAX_KAWASE_CONTEXTS = MAX_RENDER_PASSES * 2;

pub const Engine = struct {
    pub const RendererConfig = struct {
        sample_count: vk.SampleCountFlags = .{ .@"1_bit" = true },
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    core: Core,
    swapchain: Swapchain,

    render_pass: RenderPass,
    render_pass_load: RenderPass,
    pipeline: Pipeline,
    video_pipeline: Pipeline,
    video_descriptor_set_layout: vk.DescriptorSetLayout,

    frames: FrameManager,
    resources: ResourceManager,
    blur_effect: BlurEffect,

    render_graph: RenderGraph,
    resource_map: std.AutoHashMap(ResourceHandle, vk.Image),
    framebuffers: []vk.Framebuffer,
    msaa_target: ?RenderTexture,
    sample_count: vk.SampleCountFlags,

    last_topology_hash: u64,
    topology_cached: bool,
    ui_ctxs: []UISliceContext,
    copy_ctxs: []BlurEffect.CopyContext,
    kawase_ctxs: []BlurEffect.KawaseContext,
    ui_ctx_count: usize,
    copy_ctx_count: usize,
    kawase_ctx_count: usize,

    window: *glfw.Window,
    use_dxgi_transparent_present: bool,
    dxgi_overlay: ?DxgiOverlay,
    readback_buffer: ?Buffer,
    dxgi_blur_warned: bool,
    image_ingress: ImageIngress,
    frame_counter: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        window: *glfw.Window,
        transparent: bool,
        renderer_config: RendererConfig,
    ) !Engine {
        var core = try Core.init(allocator, window);
        var init_w: i32 = 0;
        var init_h: i32 = 0;
        glfw.getFramebufferSize(window, &init_w, &init_h);
        const init_fallback = vk.Extent2D{
            .width = if (init_w > 0) @intCast(init_w) else 800,
            .height = if (init_h > 0) @intCast(init_h) else 600,
        };
        const swapchain = try Swapchain.init(&core, .null_handle, transparent, init_fallback);
        const sample_count = pickSupportedSampleCount(&core, renderer_config.sample_count);

        const use_dxgi_transparent_present = builtin.os.tag == .windows and transparent and
            !swapchain.has_alpha_compositing;

        const render_pass = try RenderPass.init(core.vkd, core.logical_device, swapchain.format.format, .undefined, .color_attachment_optimal, .clear, sample_count);
        const render_pass_load = try RenderPass.init(core.vkd, core.logical_device, swapchain.format.format, .color_attachment_optimal, .color_attachment_optimal, .load, sample_count);
        const pipeline = try Pipeline.init(&core, render_pass.handle, swapchain.extent, sample_count);
        const video_descriptor_set_layout = try YuvTexture.createDescriptorSetLayout(&core);
        const video_pipeline = try Pipeline.initVideo(
            &core,
            render_pass.handle,
            swapchain.extent,
            sample_count,
            pipeline.descriptor_set_layout,
            video_descriptor_set_layout,
        );

        var resources = try ResourceManager.init(allocator, io, &core, pipeline.descriptor_set_layout, INITIAL_MAX_VERTICES, INITIAL_MAX_INDICES);
        const frames = try FrameManager.init(allocator, &core, &swapchain);
        const blur_effect = try BlurEffect.init(&core, &resources, swapchain.extent, swapchain.format.format, &pipeline);

        var msaa_target: ?RenderTexture = null;
        if (sample_count.toInt() > (@as(vk.Flags, 1))) {
            msaa_target = try RenderTexture.init(&core, swapchain.extent, swapchain.format.format, sample_count, false);
        }

        const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.image_views.len);
        try createSwapchainFramebuffers(
            &core,
            framebuffers,
            swapchain.image_views,
            render_pass.handle,
            swapchain.extent,
            msaa_target,
        );

        const render_graph = RenderGraph.init(allocator);

        const ui_ctxs = try allocator.alloc(UISliceContext, MAX_UI_CONTEXTS);
        errdefer allocator.free(ui_ctxs);

        const copy_ctxs = try allocator.alloc(BlurEffect.CopyContext, MAX_COPY_CONTEXTS);
        errdefer allocator.free(copy_ctxs);

        const kawase_ctxs = try allocator.alloc(BlurEffect.KawaseContext, MAX_KAWASE_CONTEXTS);
        errdefer allocator.free(kawase_ctxs);

        var dxgi_overlay: ?DxgiOverlay = null;
        var readback_buffer: ?Buffer = null;
        if (use_dxgi_transparent_present) {
            dxgi_overlay = try DxgiOverlay.init(window, @intCast(swapchain.extent.width), @intCast(swapchain.extent.height));
            errdefer if (dxgi_overlay) |*ov| ov.deinit();

            const bytes: vk.DeviceSize = @as(vk.DeviceSize, swapchain.extent.width) *
                @as(vk.DeviceSize, swapchain.extent.height) * 4;
            readback_buffer = try Buffer.init(
                &core,
                bytes,
                .{ .transfer_dst_bit = true },
                c.VMA_MEMORY_USAGE_CPU_ONLY,
                @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT),
            );
            errdefer if (readback_buffer) |*buf| buf.deinit(&core);

            std.log.info("transparent backend: DXGI composition (Windows)", .{});
        }

        var self = Engine{
            .allocator = allocator,
            .io = io,
            .core = core,
            .swapchain = swapchain,

            .render_pass = render_pass,
            .render_pass_load = render_pass_load,
            .pipeline = pipeline,
            .video_pipeline = video_pipeline,
            .video_descriptor_set_layout = video_descriptor_set_layout,

            .frames = frames,
            .resources = resources,
            .blur_effect = blur_effect,

            .render_graph = render_graph,
            .resource_map = std.AutoHashMap(ResourceHandle, vk.Image).init(allocator),
            .framebuffers = framebuffers,
            .msaa_target = msaa_target,
            .sample_count = sample_count,

            .last_topology_hash = 0,
            .topology_cached = false,
            .ui_ctxs = ui_ctxs,
            .copy_ctxs = copy_ctxs,
            .kawase_ctxs = kawase_ctxs,
            .ui_ctx_count = 0,
            .copy_ctx_count = 0,
            .kawase_ctx_count = 0,

            .window = window,
            .use_dxgi_transparent_present = use_dxgi_transparent_present,
            .dxgi_overlay = dxgi_overlay,
            .readback_buffer = readback_buffer,
            .dxgi_blur_warned = false,
            .image_ingress = undefined,
            .frame_counter = 0,
        };
        self.image_ingress = ImageIngress.init(
            allocator,
            io,
            .{},
        );
        self.resources.texture_registry.setDynamicBudgetBytes(self.image_ingress.budget.max_pending_upload_bytes);
        try self.populateStableResourceMap();
        return self;
    }

    fn populateStableResourceMap(self: *Engine) !void {
        try self.resource_map.put(.scene_base, self.blur_effect.scene_texture.image);
        for (self.blur_effect.kawase_textures, 0..) |tex, i| {
            try self.resource_map.put(ResourceHandle.fromInt(KAWASE_HANDLE_BASE + @as(u32, @intCast(i))), tex.image);
        }
    }

    fn pickSupportedSampleCount(core: *const Core, requested: vk.SampleCountFlags) vk.SampleCountFlags {
        const props = core.vki.getPhysicalDeviceProperties(core.physical_device);
        const supported = props.limits.framebuffer_color_sample_counts;
        if (requested.toInt() != 0 and supported.contains(requested)) {
            return requested;
        }
        return .{ .@"1_bit" = true };
    }

    fn createSwapchainFramebuffers(
        core: *const Core,
        framebuffers: []vk.Framebuffer,
        image_views: []const vk.ImageView,
        render_pass: vk.RenderPass,
        extent: vk.Extent2D,
        msaa_target: ?RenderTexture,
    ) !void {
        for (image_views, 0..) |image_view, i| {
            var attachments: [2]vk.ImageView = undefined;
            var attachment_count: u32 = 1;

            if (msaa_target) |target| {
                attachments[0] = target.view;
                attachments[1] = image_view;
                attachment_count = 2;
            } else {
                attachments[0] = image_view;
            }

            const fb_info = vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = render_pass,
                .attachment_count = attachment_count,
                .p_attachments = @ptrCast(&attachments),
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
            };
            framebuffers[i] = try core.vkd.createFramebuffer(core.logical_device, &fb_info, null);
        }
    }

    pub fn getTextureIndex(self: *const Engine, id: @import("../../assets.zig").TextureId) u32 {
        return self.resources.texture_registry.getIndex(id);
    }

    pub fn getImageState(self: *Engine, name: []const u8) TextureState {
        return self.resources.texture_registry.getImageState(name);
    }

    pub fn setImageIngressBudget(self: *Engine, budget: ImageIngressBudget) void {
        self.image_ingress.budget = budget;
        self.resources.texture_registry.setDynamicBudgetBytes(budget.max_pending_upload_bytes);
    }

    pub fn loadImageFromDiskAsync(self: *Engine, name: []const u8, path: []const u8, max_bytes: usize) !void {
        _ = max_bytes;
        std.log.debug("engine: async disk image request name='{s}' path='{s}'", .{ name, path });
        try self.image_ingress.loadImageFromDiskAsync(&self.resources.texture_registry, name, path, 0, 0);
    }

    pub fn loadImageFromDiskAsyncSized(
        self: *Engine,
        name: []const u8,
        path: []const u8,
        target_width: u32,
        target_height: u32,
    ) !void {
        std.log.debug(
            "engine: async disk image request name='{s}' path='{s}' target={d}x{d}",
            .{ name, path, target_width, target_height },
        );
        try self.image_ingress.loadImageFromDiskAsync(
            &self.resources.texture_registry,
            name,
            path,
            target_width,
            target_height,
        );
    }

    pub fn loadImageFromUrlAsync(self: *Engine, name: []const u8, url: []const u8, max_bytes: usize) !void {
        _ = max_bytes;
        try self.image_ingress.loadImageFromUrlAsync(&self.resources.texture_registry, name, url, 0, 0);
    }

    pub fn loadImageFromUrlAsyncSized(
        self: *Engine,
        name: []const u8,
        url: []const u8,
        target_width: u32,
        target_height: u32,
    ) !void {
        try self.image_ingress.loadImageFromUrlAsync(
            &self.resources.texture_registry,
            name,
            url,
            target_width,
            target_height,
        );
    }

    pub fn processPendingTextureUploads(self: *Engine) !usize {
        self.frame_counter +%= 1;
        self.resources.texture_registry.setFrameIndex(self.frame_counter);
        return self.resources.texture_registry.processPendingUploads(&self.core);
    }

    fn ensureDxgiRenderTargets(self: *Engine) !void {
        if (!self.use_dxgi_transparent_present) return;

        var w: i32 = 0;
        var h: i32 = 0;
        glfw.getFramebufferSize(self.window, &w, &h);
        if (w <= 0 or h <= 0) return;

        const target_w: u32 = @intCast(w);
        const target_h: u32 = @intCast(h);
        if (target_w == self.swapchain.extent.width and target_h == self.swapchain.extent.height) return;

        try self.recreateSwapchain();
    }

    fn resizeReadbackBuffer(self: *Engine, width: u32, height: u32) !void {
        const bytes: vk.DeviceSize = @as(vk.DeviceSize, width) * @as(vk.DeviceSize, height) * 4;
        if (self.readback_buffer) |*buf| {
            if (buf.size == bytes) return;
            buf.deinit(&self.core);
        }

        self.readback_buffer = try Buffer.init(
            &self.core,
            bytes,
            .{ .transfer_dst_bit = true },
            c.VMA_MEMORY_USAGE_CPU_ONLY,
            @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT),
        );
    }

    // Call after frame-fence wait; persistently mapped buffer races CPU/GPU otherwise.
    fn uploadFrameData(self: *Engine, batcher: *QuadBatcher, frame_index: usize) void {
        const frame_v_byte_start = frame_index * self.resources.max_vertices * @sizeOf(Vertex);
        const frame_i_byte_start = frame_index * self.resources.max_indices * @sizeOf(u32);

        var v_byte_offset: usize = 0;
        var i_byte_offset: usize = 0;

        for (batcher.layers.items) |layer_entry| {
            const layer = layer_entry.data;
            if (layer.vertices.items.len == 0) continue;

            const v_bytes = std.mem.sliceAsBytes(layer.vertices.items);
            const i_bytes = std.mem.sliceAsBytes(layer.indices.items);

            @memcpy(self.resources.vertex_buffer.mapped_ptr.?[frame_v_byte_start + v_byte_offset ..][0..v_bytes.len], v_bytes);
            @memcpy(self.resources.index_buffer.mapped_ptr.?[frame_i_byte_start + i_byte_offset ..][0..i_bytes.len], i_bytes);

            v_byte_offset += v_bytes.len;
            i_byte_offset += i_bytes.len;
        }

        const width = @as(f32, @floatFromInt(self.swapchain.extent.width));
        const height = @as(f32, @floatFromInt(self.swapchain.extent.height));

        self.resources.updateGlobalUbo(frame_index, .{
            .projection = Mat4.ortho(0.0, width, 0.0, height),
            .time = @as(f32, @floatCast(glfw.getTime())),
            ._pad = 0,
            .viewport_size = .{ width, height },
        });
    }

    fn recordCanvasUploads(self: *Engine, cb: vk.CommandBuffer, frame_index: usize, canvases: []const *Canvas) !void {
        for (canvases) |canvas| {
            if (!canvas.is_dirty) continue;

            try canvas.gpu_texture.copyShadowToStaging(frame_index, canvas.getRawPixels());
            canvas.gpu_texture.recordUpload(frame_index, self.core.vkd, cb);
            canvas.is_dirty = false;
        }
    }

    fn drawViaDxgiTransparent(self: *Engine, batcher: *QuadBatcher, canvases: []const *Canvas, video_manager: *VideoManager, font_registry: *FontRegistry) !bool {
        try self.ensureDxgiRenderTargets();

        const ctx = try self.frames.beginFrameNoPresent(&self.core);
        const cb = ctx.command_buffer;

        self.uploadFrameData(batcher, ctx.frame_index);
        try self.resources.flushDescriptorUpdates(&self.core, ctx.frame_index);
        try self.recordCanvasUploads(cb, ctx.frame_index, canvases);
        video_manager.recordUploads(ctx.frame_index, self.core.vkd, cb);

        try font_registry.flushUploads(&self.core, cb);

        var has_blur = false;
        for (batcher.layers.items) |layer_entry| {
            if (layer_entry.data.has_blur) {
                has_blur = true;
                break;
            }
        }
        if (has_blur and !self.dxgi_blur_warned) {
            std.log.warn("DXGI transparent path does not support backdrop/element blur yet; rendering without blur passes", .{});
            self.dxgi_blur_warned = true;
        }

        const clear_value = vk.ClearValue{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } } };
        const pass_begin_info = vk.RenderPassBeginInfo{
            .render_pass = self.blur_effect.render_pass.handle,
            .framebuffer = self.blur_effect.framebuffer,
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear_value),
        };

        self.core.vkd.cmdBeginRenderPass(cb, &pass_begin_info, .@"inline");
        var ui_ctx = UISliceContext{
            .engine = self,
            .batcher = batcher,
            .layers = batcher.layers.items,
            .start_layer = 0,
            .start_command = 0,
            .end_layer = batcher.layers.items.len,
            .end_command = 0,
            .base_v_offset = 0,
            .base_i_offset = 0,
            .mode = .normal,
        };
        executeUISlice(@ptrCast(&ui_ctx), cb);
        self.core.vkd.cmdEndRenderPass(cb);

        self.insertImageBarrier(
            cb,
            self.blur_effect.scene_texture.image,
            .color_attachment_optimal,
            .transfer_src_optimal,
            .{ .color_attachment_write_bit = true },
            .{ .transfer_read_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .transfer_bit = true },
        );

        try self.resizeReadbackBuffer(self.swapchain.extent.width, self.swapchain.extent.height);
        const readback = self.readback_buffer orelse return error.ReadbackBufferMissing;

        const copy_region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{
                .width = self.swapchain.extent.width,
                .height = self.swapchain.extent.height,
                .depth = 1,
            },
        };

        self.core.vkd.cmdCopyImageToBuffer(
            cb,
            self.blur_effect.scene_texture.image,
            .transfer_src_optimal,
            readback.handle,
            &[_]vk.BufferImageCopy{copy_region},
        );

        self.insertImageBarrier(
            cb,
            self.blur_effect.scene_texture.image,
            .transfer_src_optimal,
            .shader_read_only_optimal,
            .{ .transfer_read_bit = true },
            .{ .shader_read_bit = true },
            .{ .transfer_bit = true },
            .{ .fragment_shader_bit = true },
        );

        try self.core.vkd.endCommandBuffer(cb);
        try self.frames.endFrameNoPresent(ctx, &self.core);

        const pixels = readback.mapped_ptr orelse return error.ReadbackBufferNotMapped;
        if (self.dxgi_overlay) |*overlay| {
            try overlay.presentBgraStraight(
                pixels,
                @intCast(self.swapchain.extent.width),
                @intCast(self.swapchain.extent.height),
                @intCast(self.swapchain.extent.width * 4),
            );
        } else {
            return error.DxgiOverlayMissing;
        }

        return true;
    }

    pub fn draw(self: *Engine, batcher: *QuadBatcher, canvases: []const *Canvas, video_manager: *VideoManager, font_registry: *FontRegistry) !bool {
        try batcher.finalizeCurrentCommand();

        {
            var total_v: usize = 0;
            var total_i: usize = 0;
            for (batcher.layers.items) |layer_entry| {
                total_v += layer_entry.data.vertices.items.len;
                total_i += layer_entry.data.indices.items.len;
            }
            if (total_v > self.resources.max_vertices or total_i > self.resources.max_indices) {
                var new_v = self.resources.max_vertices;
                var new_i = self.resources.max_indices;
                while (new_v < total_v) new_v *= 2;
                while (new_i < total_i) new_i *= 2;
                std.log.info("geometry buffers grown: {d}→{d} vertices, {d}→{d} indices", .{ self.resources.max_vertices, new_v, self.resources.max_indices, new_i });
                try self.resources.resizeBuffers(&self.core, new_v, new_i);
            }
        }

        if (self.use_dxgi_transparent_present) {
            return try self.drawViaDxgiTransparent(batcher, canvases, video_manager, font_registry);
        }

        // Wayland WSI never returns OUT_OF_DATE_KHR / SUBOPTIMAL_KHR; poll FB size manually.
        {
            var fb_w: i32 = 0;
            var fb_h: i32 = 0;
            glfw.getFramebufferSize(self.window, &fb_w, &fb_h);
            if (fb_w > 0 and fb_h > 0) {
                const cur_w: i32 = @intCast(self.swapchain.extent.width);
                const cur_h: i32 = @intCast(self.swapchain.extent.height);
                if (fb_w != cur_w or fb_h != cur_h) {
                    try self.recreateSwapchain();
                    return false;
                }
            }
        }

        const ctx = self.frames.beginFrame(self.swapchain.handle, &self.core) catch |err| switch (err) {
            error.OutOfDateKHR => {
                try self.recreateSwapchain();
                return false;
            },
            error.SuboptimalKHR => {
                try self.recreateSwapchain();
                return false;
            },
            else => return err,
        };

        self.uploadFrameData(batcher, ctx.frame_index);

        try self.recordCommands(ctx, batcher, batcher.layers.items, canvases, video_manager, font_registry);

        self.frames.endFrame(ctx, self.swapchain.handle, &self.core) catch |err| switch (err) {
            error.OutOfDateKHR => {
                try self.recreateSwapchain();
                return false;
            },
            error.SuboptimalKHR => {
                try self.recreateSwapchain();
                return false;
            },
            else => return err,
        };
        return true;
    }

    fn recreateSwapchain(self: *Engine) !void {
        var width: i32 = 0;
        var height: i32 = 0;
        glfw.getFramebufferSize(self.window, &width, &height);
        while (width == 0 or height == 0) {
            glfw.getFramebufferSize(self.window, &width, &height);
            glfw.waitEvents();
        }

        try self.core.vkd.deviceWaitIdle(self.core.logical_device);

        const fallback = vk.Extent2D{ .width = @intCast(width), .height = @intCast(height) };
        try self.swapchain.recreate(&self.core, fallback);

        try self.frames.resize(self.core.allocator, self.swapchain.image_views.len, &self.core);

        for (self.framebuffers) |fb| self.core.vkd.destroyFramebuffer(self.core.logical_device, fb, null);
        self.core.allocator.free(self.framebuffers);

        if (self.msaa_target) |*target| {
            target.deinit(&self.core);
            self.msaa_target = null;
        }
        if (self.sample_count.toInt() > (@as(vk.Flags, 1))) {
            self.msaa_target = try RenderTexture.init(
                &self.core,
                self.swapchain.extent,
                self.swapchain.format.format,
                self.sample_count,
                false,
            );
        }

        self.framebuffers = try self.core.allocator.alloc(vk.Framebuffer, self.swapchain.image_views.len);
        try createSwapchainFramebuffers(
            &self.core,
            self.framebuffers,
            self.swapchain.image_views,
            self.render_pass.handle,
            self.swapchain.extent,
            self.msaa_target,
        );

        try self.blur_effect.resize(&self.resources, self.swapchain.extent, self.swapchain.format.format, &self.core);

        try self.populateStableResourceMap();

        if (self.use_dxgi_transparent_present) {
            try self.resizeReadbackBuffer(self.swapchain.extent.width, self.swapchain.extent.height);
            if (self.dxgi_overlay) |*overlay| {
                try overlay.resize(@intCast(self.swapchain.extent.width), @intCast(self.swapchain.extent.height));
            }
        }

        self.topology_cached = false;
    }

    const LayerBlurInfo = struct {
        has_blur: bool,
        full_levels: usize,
        fractional_level: f32,
        clamped_iter: usize,
    };

    fn collectLayerBlurInfo(layer: anytype) LayerBlurInfo {
        if (!layer.has_blur) {
            return .{ .has_blur = false, .full_levels = 0, .fractional_level = 0.0, .clamped_iter = 0 };
        }

        const max_levels: usize = 3;
        const raw_strength: f32 = if (layer.commands.items.len > 0) @max(layer.commands.items[0].params[0], 0.0) else 0.0;
        const clamped_strength = @min(raw_strength, @as(f32, @floatFromInt(max_levels)));
        const full_levels: usize = @intFromFloat(@floor(clamped_strength));
        const fractional_level = clamped_strength - @as(f32, @floatFromInt(full_levels));
        const has_fractional = fractional_level > 0.0001 and full_levels < max_levels;
        const clamped_iter: usize = full_levels + (if (has_fractional) @as(usize, 1) else @as(usize, 0));

        return .{
            .has_blur = true,
            .full_levels = full_levels,
            .fractional_level = fractional_level,
            .clamped_iter = clamped_iter,
        };
    }

    fn commandHasBackdropBlur(layer: anytype, cmd: DrawCommand) bool {
        if (cmd.index_count == 0 or cmd.index_offset >= layer.indices.items.len) return false;

        const first_index = layer.indices.items[cmd.index_offset];
        if (first_index >= layer.vertices.items.len) return false;

        const tex_id = layer.vertices.items[first_index].tex_id;
        return (tex_id & assets.EFFECT_BACKDROP_BLUR) != 0;
    }

    fn commandHasElementBlur(layer: anytype, cmd: DrawCommand) bool {
        if (cmd.index_count == 0 or cmd.index_offset >= layer.indices.items.len) return false;

        const first_index = layer.indices.items[cmd.index_offset];
        if (first_index >= layer.vertices.items.len) return false;

        const tex_id = layer.vertices.items[first_index].tex_id;
        return (tex_id & assets.EFFECT_ELEMENT_BLUR) != 0;
    }

    fn collectCommandBlurInfoForParam(cmd: DrawCommand, param_index: usize, has_blur: bool) LayerBlurInfo {
        if (!has_blur) {
            return .{ .has_blur = false, .full_levels = 0, .fractional_level = 0.0, .clamped_iter = 0 };
        }

        const max_levels: usize = 3;
        const raw_strength: f32 = @max(cmd.params[param_index], 0.0);
        const clamped_strength = @min(raw_strength, @as(f32, @floatFromInt(max_levels)));
        const full_levels: usize = @intFromFloat(@floor(clamped_strength));
        const fractional_level = clamped_strength - @as(f32, @floatFromInt(full_levels));
        const has_fractional = fractional_level > 0.0001 and full_levels < max_levels;
        const clamped_iter: usize = full_levels + (if (has_fractional) @as(usize, 1) else @as(usize, 0));

        return .{
            .has_blur = true,
            .full_levels = full_levels,
            .fractional_level = fractional_level,
            .clamped_iter = clamped_iter,
        };
    }

    fn calculateTopologyHash(self: *Engine, sorted_layers: []const LayerEntry) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        const layer_count: u32 = @intCast(sorted_layers.len);
        hasher.update(std.mem.asBytes(&layer_count));

        for (sorted_layers) |layer_entry| {
            const cmd_count: u32 = @intCast(layer_entry.data.commands.items.len);
            hasher.update(std.mem.asBytes(&cmd_count));

            for (layer_entry.data.commands.items) |cmd| {
                const has_backdrop = commandHasBackdropBlur(layer_entry.data, cmd);
                const has_element = commandHasElementBlur(layer_entry.data, cmd);
                const blur_kind: u8 = if (has_backdrop) 1 else if (has_element) 2 else 0;
                hasher.update(std.mem.asBytes(&blur_kind));

                const blur = if (has_backdrop)
                    collectCommandBlurInfoForParam(cmd, 0, true)
                else if (has_element)
                    collectCommandBlurInfoForParam(cmd, 1, true)
                else
                    LayerBlurInfo{ .has_blur = false, .full_levels = 0, .fractional_level = 0.0, .clamped_iter = 0 };

                const iter_count: u8 = @intCast(blur.clamped_iter);
                hasher.update(std.mem.asBytes(&iter_count));
            }
        }

        return hasher.final();
    }

    fn resetPersistentPayloadCounts(self: *Engine) void {
        self.ui_ctx_count = 0;
        self.copy_ctx_count = 0;
        self.kawase_ctx_count = 0;
    }

    fn nextUISliceContext(self: *Engine) !*UISliceContext {
        if (self.ui_ctx_count >= self.ui_ctxs.len) return error.RenderGraphPayloadOverflow;
        const idx = self.ui_ctx_count;
        self.ui_ctx_count += 1;
        return &self.ui_ctxs[idx];
    }

    fn nextCopyContext(self: *Engine) !*BlurEffect.CopyContext {
        if (self.copy_ctx_count >= self.copy_ctxs.len) return error.RenderGraphPayloadOverflow;
        const idx = self.copy_ctx_count;
        self.copy_ctx_count += 1;
        return &self.copy_ctxs[idx];
    }

    fn nextKawaseContext(self: *Engine) !*BlurEffect.KawaseContext {
        if (self.kawase_ctx_count >= self.kawase_ctxs.len) return error.RenderGraphPayloadOverflow;
        const idx = self.kawase_ctx_count;
        self.kawase_ctx_count += 1;
        return &self.kawase_ctxs[idx];
    }

    fn appendKawaseSequence(self: *Engine, blur: LayerBlurInfo, rebuild_topology: bool) !void {
        if (blur.clamped_iter == 0) return;

        for (0..blur.clamped_iter) |k| {
            const in_handle = if (k == 0) ResourceHandle.scene_base else ResourceHandle.fromInt(KAWASE_HANDLE_BASE + @as(u32, @intCast(k - 1)));
            const out_handle = ResourceHandle.fromInt(KAWASE_HANDLE_BASE + @as(u32, @intCast(k)));
            const target_ext = vk.Extent2D{ .width = self.swapchain.extent.width >> @intCast(k + 1), .height = self.swapchain.extent.height >> @intCast(k + 1) };
            const level_strength: f32 = if (k < blur.full_levels) 1.0 else blur.fractional_level;

            const kawase_ctx = try self.nextKawaseContext();
            kawase_ctx.* = .{
                .vkd = self.core.vkd,
                .pipeline = self.blur_effect.pipeline.handle,
                .layout = self.blur_effect.pipeline.layout,
                .half_pixel = .{ (1.0 / @as(f32, @floatFromInt(target_ext.width))) * level_strength, (1.0 / @as(f32, @floatFromInt(target_ext.height))) * level_strength },
                .input_tex_id = if (k == 0) self.blur_effect.kawase_tex_ids[0] else self.blur_effect.kawase_tex_ids[k],
                .is_up = 0,
                .extent = target_ext,
            };

            if (rebuild_topology) {
                try self.render_graph.addPass(.{
                    .name = "Kawase Down",
                    .inputs = &[_]ResourceUsage{.{ .handle = in_handle, .layout = .shader_read_only_optimal, .access = .{ .shader_read_bit = true }, .stage = .{ .fragment_shader_bit = true } }},
                    .outputs = &[_]ResourceUsage{.{ .handle = out_handle, .layout = .color_attachment_optimal, .access = .{ .color_attachment_write_bit = true }, .stage = .{ .color_attachment_output_bit = true } }},
                    .render_pass = self.blur_effect.render_pass.handle,
                    .framebuffer = self.blur_effect.kawase_framebuffers[k],
                    .extent = target_ext,
                    .payload = kawase_ctx,
                    .executeFn = executeKawasePass,
                });
            }
        }

        var k: usize = blur.clamped_iter;
        while (k > 0) : (k -= 1) {
            const in_handle = ResourceHandle.fromInt(KAWASE_HANDLE_BASE + @as(u32, @intCast(k - 1)));
            const out_handle = if (k == 1) ResourceHandle.scene_base else ResourceHandle.fromInt(KAWASE_HANDLE_BASE + @as(u32, @intCast(k - 2)));
            const target_ext = if (k == 1) self.swapchain.extent else vk.Extent2D{ .width = self.swapchain.extent.width >> @intCast(k - 1), .height = self.swapchain.extent.height >> @intCast(k - 1) };
            const level_strength: f32 = if ((k - 1) < blur.full_levels) 1.0 else blur.fractional_level;

            const kawase_ctx = try self.nextKawaseContext();
            kawase_ctx.* = .{
                .vkd = self.core.vkd,
                .pipeline = self.blur_effect.pipeline.handle,
                .layout = self.blur_effect.pipeline.layout,
                .half_pixel = .{ (1.0 / @as(f32, @floatFromInt(target_ext.width))) * level_strength, (1.0 / @as(f32, @floatFromInt(target_ext.height))) * level_strength },
                .input_tex_id = self.blur_effect.kawase_tex_ids[k],
                .is_up = 1,
                .extent = target_ext,
            };

            if (rebuild_topology) {
                try self.render_graph.addPass(.{
                    .name = "Kawase Up",
                    .inputs = &[_]ResourceUsage{.{ .handle = in_handle, .layout = .shader_read_only_optimal, .access = .{ .shader_read_bit = true }, .stage = .{ .fragment_shader_bit = true } }},
                    .outputs = &[_]ResourceUsage{.{ .handle = out_handle, .layout = .color_attachment_optimal, .access = .{ .color_attachment_write_bit = true }, .stage = .{ .color_attachment_output_bit = true } }},
                    .render_pass = self.blur_effect.render_pass.handle,
                    .framebuffer = if (k == 1) self.blur_effect.framebuffer else self.blur_effect.kawase_framebuffers[k - 2],
                    .extent = target_ext,
                    .payload = kawase_ctx,
                    .executeFn = executeKawasePass,
                });
            }
        }
    }

    fn populatePersistentPayloads(self: *Engine, ctx: FrameContext, batcher: *QuadBatcher, sorted_layers: []const LayerEntry, rebuild_topology: bool) !void {
        var current_slice_start_layer: usize = 0;
        var current_slice_start_cmd: usize = 0;
        var slice_base_v_offset: i32 = 0;
        var slice_base_i_offset: u32 = 0;
        var running_v_offset: i32 = 0;
        var running_i_offset: u32 = 0;

        for (sorted_layers, 0..) |layer_entry, i| {
            for (layer_entry.data.commands.items, 0..) |cmd, cmd_i| {
                const has_backdrop = commandHasBackdropBlur(layer_entry.data, cmd);
                const has_element = commandHasElementBlur(layer_entry.data, cmd);
                if (!has_backdrop and !has_element) continue;

                const blur = if (has_backdrop)
                    collectCommandBlurInfoForParam(cmd, 0, true)
                else
                    collectCommandBlurInfoForParam(cmd, 1, true);

                const ui_ctx = try self.nextUISliceContext();
                ui_ctx.* = .{
                    .engine = self,
                    .batcher = batcher,
                    .layers = sorted_layers,
                    .start_layer = current_slice_start_layer,
                    .start_command = current_slice_start_cmd,
                    .end_layer = i,
                    .end_command = cmd_i,
                    .base_v_offset = slice_base_v_offset,
                    .base_i_offset = slice_base_i_offset,
                    .mode = .normal,
                };

                const has_scene_base_input = current_slice_start_layer > 0 or current_slice_start_cmd > 0;

                if (rebuild_topology) {
                    try self.render_graph.addPass(.{
                        .name = "UI Slice",
                        .inputs = if (has_scene_base_input) &[_]ResourceUsage{.{ .handle = .scene_base, .layout = .shader_read_only_optimal, .access = .{ .shader_read_bit = true }, .stage = .{ .fragment_shader_bit = true } }} else &[_]ResourceUsage{},
                        .outputs = &[_]ResourceUsage{.{ .handle = .swapchain, .layout = .color_attachment_optimal, .access = .{ .color_attachment_write_bit = true }, .stage = .{ .color_attachment_output_bit = true } }},
                        .render_pass = if (!has_scene_base_input) self.render_pass.handle else self.render_pass_load.handle,
                        .framebuffer = self.framebuffers[ctx.image_index],
                        .extent = self.swapchain.extent,
                        .clear = !has_scene_base_input,
                        .payload = ui_ctx,
                        .executeFn = executeUISlice,
                    });
                }

                if (has_element and !has_backdrop) {
                    const capture_ctx = try self.nextUISliceContext();
                    capture_ctx.* = .{
                        .engine = self,
                        .batcher = batcher,
                        .layers = sorted_layers,
                        .start_layer = i,
                        .start_command = cmd_i,
                        .end_layer = i,
                        .end_command = cmd_i + 1,
                        .base_v_offset = running_v_offset,
                        .base_i_offset = running_i_offset,
                        .mode = .element_capture,
                    };

                    if (rebuild_topology) {
                        try self.render_graph.addPass(.{
                            .name = "Element Blur Capture",
                            .inputs = &[_]ResourceUsage{},
                            .outputs = &[_]ResourceUsage{.{ .handle = .scene_base, .layout = .color_attachment_optimal, .access = .{ .color_attachment_write_bit = true }, .stage = .{ .color_attachment_output_bit = true } }},
                            .render_pass = self.blur_effect.render_pass.handle,
                            .framebuffer = self.blur_effect.framebuffer,
                            .extent = self.swapchain.extent,
                            .clear = true,
                            .payload = capture_ctx,
                            .executeFn = executeUISlice,
                        });
                    }

                    try self.appendKawaseSequence(blur, rebuild_topology);

                    const composite_ctx = try self.nextUISliceContext();
                    composite_ctx.* = .{
                        .engine = self,
                        .batcher = batcher,
                        .layers = sorted_layers,
                        .start_layer = i,
                        .start_command = cmd_i,
                        .end_layer = i,
                        .end_command = cmd_i + 1,
                        .base_v_offset = running_v_offset,
                        .base_i_offset = running_i_offset,
                        .mode = .element_composite,
                    };

                    if (rebuild_topology) {
                        try self.render_graph.addPass(.{
                            .name = "Element Blur Composite",
                            .inputs = &[_]ResourceUsage{.{ .handle = .scene_base, .layout = .shader_read_only_optimal, .access = .{ .shader_read_bit = true }, .stage = .{ .fragment_shader_bit = true } }},
                            .outputs = &[_]ResourceUsage{.{ .handle = .swapchain, .layout = .color_attachment_optimal, .access = .{ .color_attachment_write_bit = true }, .stage = .{ .color_attachment_output_bit = true } }},
                            .render_pass = self.render_pass_load.handle,
                            .framebuffer = self.framebuffers[ctx.image_index],
                            .extent = self.swapchain.extent,
                            .clear = false,
                            .payload = composite_ctx,
                            .executeFn = executeUISlice,
                        });
                    }

                    current_slice_start_layer = i;
                    current_slice_start_cmd = cmd_i + 1;
                    slice_base_v_offset = running_v_offset;
                    slice_base_i_offset = running_i_offset;
                    continue;
                }

                const copy_ctx = try self.nextCopyContext();
                copy_ctx.* = .{ .vkd = self.core.vkd, .extent = self.swapchain.extent, .src_image = self.swapchain.images[ctx.image_index], .dst_image = self.blur_effect.scene_texture.image };

                if (rebuild_topology) {
                    try self.render_graph.addPass(.{
                        .name = "Snapshot Copy",
                        .is_transfer = true,
                        .inputs = &[_]ResourceUsage{.{ .handle = .swapchain, .layout = .transfer_src_optimal, .access = .{ .transfer_read_bit = true }, .stage = .{ .transfer_bit = true } }},
                        .outputs = &[_]ResourceUsage{.{ .handle = .scene_base, .layout = .transfer_dst_optimal, .access = .{ .transfer_write_bit = true }, .stage = .{ .transfer_bit = true } }},
                        .payload = copy_ctx,
                        .executeFn = executeSnapshotCopy,
                    });
                }

                try self.appendKawaseSequence(blur, rebuild_topology);

                current_slice_start_layer = i;
                current_slice_start_cmd = cmd_i;
                slice_base_v_offset = running_v_offset;
                slice_base_i_offset = running_i_offset;
            }

            if (layer_entry.data.vertices.items.len > 0) {
                running_v_offset += @intCast(layer_entry.data.vertices.items.len);
                running_i_offset += @intCast(layer_entry.data.indices.items.len);
            }
        }

        const final_ui_ctx = try self.nextUISliceContext();
        final_ui_ctx.* = .{
            .engine = self,
            .batcher = batcher,
            .layers = sorted_layers,
            .start_layer = current_slice_start_layer,
            .start_command = current_slice_start_cmd,
            .end_layer = sorted_layers.len,
            .end_command = 0,
            .base_v_offset = slice_base_v_offset,
            .base_i_offset = slice_base_i_offset,
            .mode = .normal,
        };

        const has_scene_base_input = current_slice_start_layer > 0 or current_slice_start_cmd > 0;

        if (rebuild_topology) {
            try self.render_graph.addPass(.{
                .name = "Final UI Slice",
                .inputs = if (has_scene_base_input) &[_]ResourceUsage{.{ .handle = .scene_base, .layout = .shader_read_only_optimal, .access = .{ .shader_read_bit = true }, .stage = .{ .fragment_shader_bit = true } }} else &[_]ResourceUsage{},
                .outputs = &[_]ResourceUsage{.{ .handle = .swapchain, .layout = .color_attachment_optimal, .access = .{ .color_attachment_write_bit = true }, .stage = .{ .color_attachment_output_bit = true } }},
                .render_pass = if (!has_scene_base_input) self.render_pass.handle else self.render_pass_load.handle,
                .framebuffer = self.framebuffers[ctx.image_index],
                .extent = self.swapchain.extent,
                .clear = !has_scene_base_input,
                .payload = final_ui_ctx,
                .executeFn = executeUISlice,
            });
        }
    }

    fn updateDynamicCachedPassBindings(self: *Engine, ctx: FrameContext) void {
        for (self.render_graph.sorted_nodes.items) |*pass| {
            if (!pass.is_transfer and pass.outputs.len > 0 and pass.outputs[0].handle == .swapchain) {
                pass.framebuffer = self.framebuffers[ctx.image_index];
                pass.extent = self.swapchain.extent;
            }
        }
    }

    fn prepareGraph(self: *Engine, ctx: FrameContext, batcher: *QuadBatcher, sorted_layers: []const LayerEntry) !void {
        const current_hash = self.calculateTopologyHash(sorted_layers);
        const topology_changed = !self.topology_cached or current_hash != self.last_topology_hash;

        self.resetPersistentPayloadCounts();

        if (topology_changed) {
            self.render_graph.reset();
            try self.populatePersistentPayloads(ctx, batcher, sorted_layers, true);
            try self.render_graph.compile();
            self.last_topology_hash = current_hash;
            self.topology_cached = true;
        } else {
            try self.populatePersistentPayloads(ctx, batcher, sorted_layers, false);
        }

        self.updateDynamicCachedPassBindings(ctx);
    }

    fn recordCommands(self: *Engine, ctx: FrameContext, batcher: *QuadBatcher, sorted_layers: []const LayerEntry, canvases: []const *Canvas, video_manager: *VideoManager, font_registry: *FontRegistry) !void {
        const cb = ctx.command_buffer;

        try self.resources.flushDescriptorUpdates(&self.core, ctx.frame_index);
        try self.recordCanvasUploads(cb, ctx.frame_index, canvases);
        video_manager.recordUploads(ctx.frame_index, self.core.vkd, cb);
        try font_registry.flushUploads(&self.core, cb);

        try self.resource_map.put(.swapchain, self.swapchain.images[ctx.image_index]);

        try self.render_graph.resource_states.put(.swapchain, .{ .layout = .undefined, .access = .{}, .stage = .{ .top_of_pipe_bit = true } });
        try self.render_graph.resource_states.put(.scene_base, .{ .layout = .shader_read_only_optimal, .access = .{ .shader_read_bit = true }, .stage = .{ .fragment_shader_bit = true } });
        const kawase_initial_state = ResourceState{ .layout = .shader_read_only_optimal, .access = .{ .shader_read_bit = true }, .stage = .{ .fragment_shader_bit = true } };
        for (0..self.blur_effect.kawase_textures.len) |i| {
            try self.render_graph.resource_states.put(ResourceHandle.fromInt(KAWASE_HANDLE_BASE + @as(u32, @intCast(i))), kawase_initial_state);
        }

        try self.prepareGraph(ctx, batcher, sorted_layers);

        const clear_value = vk.ClearValue{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } } };

        for (self.render_graph.sorted_nodes.items) |pass| {
            try self.render_graph.injectBarriers(self.core.vkd, cb, pass, &self.resource_map);
            if (!pass.is_transfer) {
                const pass_begin_info = vk.RenderPassBeginInfo{
                    .render_pass = pass.render_pass,
                    .framebuffer = pass.framebuffer,
                    .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = pass.extent },
                    .clear_value_count = 1,
                    .p_clear_values = @ptrCast(&clear_value),
                };
                self.core.vkd.cmdBeginRenderPass(cb, &pass_begin_info, .@"inline");
            }

            pass.executeFn(pass.payload, cb);

            if (!pass.is_transfer) {
                self.core.vkd.cmdEndRenderPass(cb);
            }
        }

        const final_state = self.render_graph.resource_states.get(.swapchain).?;
        self.insertImageBarrier(cb, self.swapchain.images[ctx.image_index], final_state.layout, .present_src_khr, final_state.access, .{}, final_state.stage, .{ .bottom_of_pipe_bit = true });

        try self.core.vkd.endCommandBuffer(cb);
    }

    fn insertImageBarrier(self: *const Engine, cb: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout, src_access: vk.AccessFlags, dst_access: vk.AccessFlags, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags) void {
        const barrier = vk.ImageMemoryBarrier{
            .src_access_mask = src_access,
            .dst_access_mask = dst_access,
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        };
        self.core.vkd.cmdPipelineBarrier(cb, src_stage, dst_stage, .{}, null, null, &[_]vk.ImageMemoryBarrier{barrier});
    }

    fn bindPipelineState(self: *const Engine, cb: vk.CommandBuffer) void {
        const vkd = self.core.vkd;

        const viewport = vk.Viewport{ .x = 0.0, .y = 0.0, .width = @as(f32, @floatFromInt(self.swapchain.extent.width)), .height = @as(f32, @floatFromInt(self.swapchain.extent.height)), .min_depth = 0.0, .max_depth = 1.0 };
        vkd.cmdSetViewport(cb, 0, &[_]vk.Viewport{viewport});

        const v_frame_offset: vk.DeviceSize = self.frames.current_frame_index * self.resources.max_vertices * @sizeOf(Vertex);
        const i_frame_offset: vk.DeviceSize = self.frames.current_frame_index * self.resources.max_indices * @sizeOf(u32);

        vkd.cmdBindVertexBuffers(cb, 0, &[_]vk.Buffer{self.resources.vertex_buffer.handle}, &[_]vk.DeviceSize{v_frame_offset});
        vkd.cmdBindIndexBuffer(cb, self.resources.index_buffer.handle, i_frame_offset, .uint32);
    }

    pub const UISliceContext = struct {
        engine: *const Engine,
        batcher: *QuadBatcher,
        layers: []const LayerEntry,
        start_layer: usize,
        start_command: usize,
        end_layer: usize,
        end_command: usize,
        base_v_offset: i32,
        base_i_offset: u32,
        mode: UISliceMode,
    };

    pub const UISliceMode = enum {
        normal,
        element_capture,
        element_composite,
    };

    fn executeUISlice(ctx_opaque: ?*anyopaque, cb: vk.CommandBuffer) void {
        const ctx: *UISliceContext = @ptrCast(@alignCast(ctx_opaque.?));
        const vkd = ctx.engine.core.vkd;
        ctx.engine.bindPipelineState(cb);

        const global_descriptor_set = ctx.engine.resources.descriptor_sets[ctx.engine.frames.current_frame_index];
        const PipelineKind = enum { none, ui, video };
        var bound_pipeline: PipelineKind = .none;
        var bound_video_descriptor: vk.DescriptorSet = .null_handle;

        var current_v_offset: i32 = ctx.base_v_offset;
        var current_i_offset: u32 = ctx.base_i_offset;

        for (ctx.layers, 0..) |layer_entry, layer_i| {
            if (layer_i < ctx.start_layer) continue;
            if (ctx.end_layer < ctx.layers.len and layer_i > ctx.end_layer) break;

            const layer = layer_entry.data;

            var cmd_start: usize = if (layer_i == ctx.start_layer) ctx.start_command else 0;
            var cmd_end: usize = layer.commands.items.len;
            if (ctx.end_layer < ctx.layers.len and layer_i == ctx.end_layer) {
                cmd_end = @min(ctx.end_command, layer.commands.items.len);
            }
            if (cmd_start > cmd_end) cmd_start = cmd_end;

            if (layer.vertices.items.len > 0 and cmd_start < cmd_end) {
                for (layer.commands.items[cmd_start..cmd_end]) |cmd| {
                    const use_video_pipeline = cmd.uses_video_pipeline and cmd.video_descriptor_set != .null_handle;
                    if (use_video_pipeline) {
                        if (bound_pipeline != .video) {
                            vkd.cmdBindPipeline(cb, .graphics, ctx.engine.video_pipeline.handle);
                            bound_pipeline = .video;
                        }
                        if (cmd.video_descriptor_set != bound_video_descriptor) {
                            const descriptor_sets = [_]vk.DescriptorSet{
                                global_descriptor_set,
                                cmd.video_descriptor_set,
                            };
                            vkd.cmdBindDescriptorSets(cb, .graphics, ctx.engine.video_pipeline.layout, 0, &descriptor_sets, null);
                            bound_video_descriptor = cmd.video_descriptor_set;
                        }
                    } else {
                        if (bound_pipeline != .ui) {
                            const descriptor_sets = [_]vk.DescriptorSet{global_descriptor_set};
                            vkd.cmdBindPipeline(cb, .graphics, ctx.engine.pipeline.handle);
                            vkd.cmdBindDescriptorSets(cb, .graphics, ctx.engine.pipeline.layout, 0, &descriptor_sets, null);
                            bound_pipeline = .ui;
                            bound_video_descriptor = .null_handle;
                        }
                    }

                    vkd.cmdSetScissor(cb, 0, &[_]vk.Rect2D{cmd.scissor});
                    var params = cmd.params;
                    params[3] = switch (ctx.mode) {
                        .normal => 0.0,
                        .element_capture => 1.0,
                        .element_composite => 2.0,
                    };
                    const layout = if (use_video_pipeline) ctx.engine.video_pipeline.layout else ctx.engine.pipeline.layout;
                    vkd.cmdPushConstants(cb, layout, .{ .fragment_bit = true }, 0, @sizeOf([4]f32), @ptrCast(&params));
                    vkd.cmdDrawIndexed(cb, cmd.index_count, 1, current_i_offset + cmd.index_offset, current_v_offset, 0);
                }
            }

            if (layer.vertices.items.len > 0) {
                current_v_offset += @intCast(layer.vertices.items.len);
                current_i_offset += @intCast(layer.indices.items.len);
            }

            if (ctx.end_layer < ctx.layers.len and layer_i == ctx.end_layer) break;
        }
    }

    fn executeSnapshotCopy(ctx_opaque: ?*anyopaque, cb: vk.CommandBuffer) void {
        const ctx: *BlurEffect.CopyContext = @ptrCast(@alignCast(ctx_opaque.?));
        const copy_region = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = ctx.extent.width, .height = ctx.extent.height, .depth = 1 },
        };
        ctx.vkd.cmdCopyImage(cb, ctx.src_image, .transfer_src_optimal, ctx.dst_image, .transfer_dst_optimal, &[_]vk.ImageCopy{copy_region});
    }

    fn executeKawasePass(ctx_opaque: ?*anyopaque, cb: vk.CommandBuffer) void {
        const ctx: *BlurEffect.KawaseContext = @ptrCast(@alignCast(ctx_opaque.?));
        ctx.vkd.cmdBindPipeline(cb, .graphics, ctx.pipeline);
        const viewport = vk.Viewport{ .x = 0.0, .y = 0.0, .width = @as(f32, @floatFromInt(ctx.extent.width)), .height = @as(f32, @floatFromInt(ctx.extent.height)), .min_depth = 0.0, .max_depth = 1.0 };
        ctx.vkd.cmdSetViewport(cb, 0, &[_]vk.Viewport{viewport});
        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.extent };
        ctx.vkd.cmdSetScissor(cb, 0, &[_]vk.Rect2D{scissor});
        const payload = [_]u32{ @bitCast(ctx.half_pixel[0]), @bitCast(ctx.half_pixel[1]), ctx.input_tex_id, ctx.is_up };
        ctx.vkd.cmdPushConstants(cb, ctx.layout, .{ .fragment_bit = true }, 0, 16, @ptrCast(&payload));
        ctx.vkd.cmdDraw(cb, 3, 1, 0, 0);
    }

    pub fn loadTexture(self: *Engine, path: [:0]const u8) !u32 {
        if (self.resources.texture_registry.texture_count >= MAX_BINDLESS) {
            return error.TooManyTextures;
        }

        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const Texture = @import("texture.zig").Texture;

        const pixels_ptr = c.stbi_load(path.ptr, &width, &height, &channels, 4);
        if (pixels_ptr == null) return error.TextureLoadFailed;
        defer c.stbi_image_free(pixels_ptr);

        const image_size = @as(usize, @intCast(width * height * 4));
        const texture = try Texture.init(&self.core, @intCast(width), @intCast(height), pixels_ptr[0..image_size]);

        try self.resources.texture_registry.textures.append(self.core.allocator, texture);
        const index = self.resources.texture_registry.registerRawView(texture.view);
        return index;
    }

    pub fn deinit(self: *Engine) void {
        _ = self.core.vkd.deviceWaitIdle(self.core.logical_device) catch {};
        self.image_ingress.deinit();

        if (self.readback_buffer) |*buf| {
            buf.deinit(&self.core);
        }
        if (self.dxgi_overlay) |*overlay| {
            overlay.deinit();
        }

        self.render_graph.deinit();
        self.resource_map.deinit();

        for (self.framebuffers) |fb| self.core.vkd.destroyFramebuffer(self.core.logical_device, fb, null);
        self.allocator.free(self.framebuffers);
        if (self.msaa_target) |*target| {
            target.deinit(&self.core);
        }

        self.blur_effect.deinit(&self.core);
        self.frames.deinit(self.allocator, &self.core);
        self.resources.deinit(&self.core);

        self.video_pipeline.deinit(&self.core);
        self.core.vkd.destroyDescriptorSetLayout(self.core.logical_device, self.video_descriptor_set_layout, null);
        self.pipeline.deinit(&self.core);
        self.render_pass.deinit(self.core.vkd, self.core.logical_device);
        self.render_pass_load.deinit(self.core.vkd, self.core.logical_device);

        self.allocator.free(self.kawase_ctxs);
        self.allocator.free(self.copy_ctxs);
        self.allocator.free(self.ui_ctxs);

        self.swapchain.deinit(&self.core);
        self.core.deinit();
    }
};
