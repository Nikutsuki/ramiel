const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;
const RenderTexture = @import("render_texture.zig").RenderTexture;
const RenderPass = @import("render_pass.zig").VulkanRenderPass;
const Pipeline = @import("pipeline.zig").Pipeline;
const ResourceManager = @import("resource_manager.zig").ResourceManager;

pub const BlurEffect = struct {
    render_pass: RenderPass,
    pipeline: Pipeline,
    
    scene_texture: RenderTexture,
    framebuffer: vk.Framebuffer,
    
    kawase_textures: [3]RenderTexture,
    kawase_framebuffers: [3]vk.Framebuffer,
    kawase_tex_ids: [4]u32, // scene_base + 3 targets

    pub const CopyContext = struct {
        vkd: vk.DeviceWrapper,
        extent: vk.Extent2D,
        src_image: vk.Image,
        dst_image: vk.Image,
    };

    pub const KawaseContext = struct {
        vkd: vk.DeviceWrapper,
        pipeline: vk.Pipeline,
        layout: vk.PipelineLayout,
        half_pixel: [2]f32,
        input_tex_id: u32,
        is_up: u32,
        extent: vk.Extent2D,
    };

    pub fn init(core: *Core, resource_manager: *ResourceManager, extent: vk.Extent2D, format: vk.Format, main_pipeline: *const Pipeline) !BlurEffect {
        const render_pass = try RenderPass.init(core.vkd, core.logical_device, format, .undefined, .color_attachment_optimal, .clear, .{ .@"1_bit" = true });
        const pipeline = try Pipeline.initKawase(core, render_pass.handle, main_pipeline.descriptor_set_layout);

        const scene_texture = try RenderTexture.init(core, extent, format, .{ .@"1_bit" = true }, true);
        try core.transitionImageLayout(scene_texture.image, .undefined, .shader_read_only_optimal);

        const fb_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass.handle,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&scene_texture.view),
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };
        const framebuffer = try core.vkd.createFramebuffer(core.logical_device, &fb_info, null);

        var kawase_textures: [3]RenderTexture = undefined;
        var kawase_framebuffers: [3]vk.Framebuffer = undefined;
        
        var current_width = extent.width / 2;
        var current_height = extent.height / 2;

        for (0..3) |i| {
            const ext = vk.Extent2D{ .width = current_width, .height = current_height };
            kawase_textures[i] = try RenderTexture.init(core, ext, format, .{ .@"1_bit" = true }, true);
            try core.transitionImageLayout(kawase_textures[i].image, .undefined, .shader_read_only_optimal);

            const kfb_info = vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = render_pass.handle,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&kawase_textures[i].view),
                .width = current_width,
                .height = current_height,
                .layers = 1,
            };
            kawase_framebuffers[i] = try core.vkd.createFramebuffer(core.logical_device, &kfb_info, null);

            current_width /= 2;
            current_height /= 2;
        }

        const base_id = resource_manager.texture_registry.registerRawView(scene_texture.view);
        const k0_id = resource_manager.texture_registry.registerRawView(kawase_textures[0].view);
        const k1_id = resource_manager.texture_registry.registerRawView(kawase_textures[1].view);
        const k2_id = resource_manager.texture_registry.registerRawView(kawase_textures[2].view);

        try resource_manager.markOffscreenDescriptorDirty(1, scene_texture.view, scene_texture.sampler);

        return BlurEffect{
            .render_pass = render_pass,
            .pipeline = pipeline,
            .scene_texture = scene_texture,
            .framebuffer = framebuffer,
            .kawase_textures = kawase_textures,
            .kawase_framebuffers = kawase_framebuffers,
            .kawase_tex_ids = .{ base_id, k0_id, k1_id, k2_id },
        };
    }

    pub fn deinit(self: *BlurEffect, core: *Core) void {
        core.vkd.destroyFramebuffer(core.logical_device, self.framebuffer, null);
        self.scene_texture.deinit(core);
        
        for (&self.kawase_textures) |*tex| tex.deinit(core);
        for (self.kawase_framebuffers) |fb| core.vkd.destroyFramebuffer(core.logical_device, fb, null);
        
        self.pipeline.deinit(core);
        self.render_pass.deinit(core.vkd, core.logical_device);
    }

    pub fn resize(self: *BlurEffect, resource_manager: *ResourceManager, extent: vk.Extent2D, format: vk.Format, core: *Core) !void {
        core.vkd.destroyFramebuffer(core.logical_device, self.framebuffer, null);
        self.scene_texture.deinit(core);
        for (&self.kawase_textures) |*tex| tex.deinit(core);
        for (self.kawase_framebuffers) |fb| core.vkd.destroyFramebuffer(core.logical_device, fb, null);

        self.scene_texture = try RenderTexture.init(core, extent, format, .{ .@"1_bit" = true }, true);
        try core.transitionImageLayout(self.scene_texture.image, .undefined, .shader_read_only_optimal);

        const fb_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = self.render_pass.handle,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&self.scene_texture.view),
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };
        self.framebuffer = try core.vkd.createFramebuffer(core.logical_device, &fb_info, null);

        var current_width = extent.width / 2;
        var current_height = extent.height / 2;

        for (0..3) |i| {
            const ext = vk.Extent2D{ .width = current_width, .height = current_height };
            self.kawase_textures[i] = try RenderTexture.init(core, ext, format, .{ .@"1_bit" = true }, true);
            try core.transitionImageLayout(self.kawase_textures[i].image, .undefined, .shader_read_only_optimal);

            const kfb_info = vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = self.render_pass.handle,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&self.kawase_textures[i].view),
                .width = current_width,
                .height = current_height,
                .layers = 1,
            };
            self.kawase_framebuffers[i] = try core.vkd.createFramebuffer(core.logical_device, &kfb_info, null);

            current_width /= 2;
            current_height /= 2;
        }

        resource_manager.texture_registry.updateRawView(self.kawase_tex_ids[0], self.scene_texture.view);
        resource_manager.texture_registry.updateRawView(self.kawase_tex_ids[1], self.kawase_textures[0].view);
        resource_manager.texture_registry.updateRawView(self.kawase_tex_ids[2], self.kawase_textures[1].view);
        resource_manager.texture_registry.updateRawView(self.kawase_tex_ids[3], self.kawase_textures[2].view);
        
        try resource_manager.markOffscreenDescriptorDirty(1, self.scene_texture.view, self.scene_texture.sampler);
    }
};
