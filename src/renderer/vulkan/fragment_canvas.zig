const std = @import("std");
const vk = @import("../../vk.zig");
const vk_common = @import("vk_common.zig");
const c = vk_common.c;
const Core = @import("core.zig").Core;
const Buffer = @import("buffer.zig").Buffer;
const Texture = @import("texture.zig").Texture;
const RenderTexture = @import("render_texture.zig").RenderTexture;
const TextureRegistry = @import("texture_registry.zig").TextureRegistry;
const compute = @import("compute_canvas.zig");

const MAX_FRAMES_IN_FLIGHT = @import("frame_manager.zig").MAX_FRAMES_IN_FLIGHT;

pub const Uniforms = compute.Uniforms;
pub const InputImage = compute.InputImage;

pub const fullscreen_vertex_glsl =
    \\#version 450
    \\layout(location = 0) out vec2 v_uv;
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    \\    v_uv = p;
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

pub const FragmentBacking = struct {
    width: u32,
    height: u32,

    color: RenderTexture,
    tex_id: u32,

    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,

    input: ?Texture,
    input_sampler: vk.Sampler,

    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
    ubo_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,

    uniforms: Uniforms,

    pub fn create(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        width: u32,
        height: u32,
        vert_spirv: []const u32,
        frag_spirv: []const u32,
        input_image: ?InputImage,
    ) !*FragmentBacking {
        if (width == 0 or height == 0) return error.InvalidCanvasSize;
        if (vert_spirv.len == 0 or frag_spirv.len == 0) return error.EmptyShader;

        const self = try allocator.create(FragmentBacking);
        errdefer allocator.destroy(self);

        self.width = width;
        self.height = height;
        self.input = null;
        self.input_sampler = .null_handle;
        self.uniforms = .{ .resolution = .{ @floatFromInt(width), @floatFromInt(height) } };

        self.color = try RenderTexture.init(core, .{ .width = width, .height = height }, .r8g8b8a8_unorm, .{ .@"1_bit" = true }, true);
        errdefer self.color.deinit(core);

        self.tex_id = try texture_registry.registerManagedView(core, self.color.view);
        errdefer texture_registry.releaseManagedView(self.tex_id);

        if (input_image) |img| {
            self.input = try Texture.init(core, img.width, img.height, img.pixels);
            self.input_sampler = try compute.linearSampler(core);
        }
        errdefer if (self.input) |*tex| {
            core.vkd.destroySampler(core.logical_device, self.input_sampler, null);
            tex.deinit(core);
        };

        const color_attachment = vk.AttachmentDescription{
            .flags = .{},
            .format = .r8g8b8a8_unorm,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .shader_read_only_optimal,
        };
        const color_ref = vk.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const subpass = vk.SubpassDescription{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .input_attachment_count = 0,
            .p_input_attachments = null,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_ref),
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = null,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = null,
        };
        const dependencies = [_]vk.SubpassDependency{
            .{ .src_subpass = vk.SUBPASS_EXTERNAL, .dst_subpass = 0, .src_stage_mask = .{ .fragment_shader_bit = true }, .dst_stage_mask = .{ .color_attachment_output_bit = true }, .src_access_mask = .{ .shader_read_bit = true }, .dst_access_mask = .{ .color_attachment_write_bit = true }, .dependency_flags = .{} },
            .{ .src_subpass = 0, .dst_subpass = vk.SUBPASS_EXTERNAL, .src_stage_mask = .{ .color_attachment_output_bit = true }, .dst_stage_mask = .{ .fragment_shader_bit = true }, .src_access_mask = .{ .color_attachment_write_bit = true }, .dst_access_mask = .{ .shader_read_bit = true }, .dependency_flags = .{} },
        };
        const rp_info = vk.RenderPassCreateInfo{
            .flags = .{},
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = dependencies.len,
            .p_dependencies = &dependencies,
        };
        self.render_pass = try core.vkd.createRenderPass(core.logical_device, &rp_info, null);
        errdefer core.vkd.destroyRenderPass(core.logical_device, self.render_pass, null);

        const fb_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = self.render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&self.color.view),
            .width = width,
            .height = height,
            .layers = 1,
        };
        self.framebuffer = try core.vkd.createFramebuffer(core.logical_device, &fb_info, null);
        errdefer core.vkd.destroyFramebuffer(core.logical_device, self.framebuffer, null);

        const has_input = self.input != null;
        const all_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        };
        const binding_count: u32 = if (has_input) 2 else 1;
        self.descriptor_set_layout = try core.vkd.createDescriptorSetLayout(core.logical_device, &.{ .flags = .{}, .binding_count = binding_count, .p_bindings = &all_bindings }, null);
        errdefer core.vkd.destroyDescriptorSetLayout(core.logical_device, self.descriptor_set_layout, null);

        self.pipeline_layout = try core.vkd.createPipelineLayout(core.logical_device, &.{ .flags = .{}, .set_layout_count = 1, .p_set_layouts = @ptrCast(&self.descriptor_set_layout), .push_constant_range_count = 0, .p_push_constant_ranges = null }, null);
        errdefer core.vkd.destroyPipelineLayout(core.logical_device, self.pipeline_layout, null);

        const vert_module = try core.vkd.createShaderModule(core.logical_device, &.{ .flags = .{}, .code_size = vert_spirv.len * @sizeOf(u32), .p_code = vert_spirv.ptr }, null);
        defer core.vkd.destroyShaderModule(core.logical_device, vert_module, null);
        const frag_module = try core.vkd.createShaderModule(core.logical_device, &.{ .flags = .{}, .code_size = frag_spirv.len * @sizeOf(u32), .p_code = frag_spirv.ptr }, null);
        defer core.vkd.destroyShaderModule(core.logical_device, frag_module, null);

        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .flags = .{}, .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main", .p_specialization_info = null },
            .{ .flags = .{}, .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main", .p_specialization_info = null },
        };

        const vertex_input = vk.PipelineVertexInputStateCreateInfo{ .flags = .{}, .vertex_binding_description_count = 0, .p_vertex_binding_descriptions = null, .vertex_attribute_description_count = 0, .p_vertex_attribute_descriptions = null };
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{ .flags = .{}, .topology = .triangle_list, .primitive_restart_enable = vk.Bool32.false };

        const viewport = vk.Viewport{ .x = 0.0, .y = 0.0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0.0, .max_depth = 1.0 };
        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
        const viewport_state = vk.PipelineViewportStateCreateInfo{ .flags = .{}, .viewport_count = 1, .p_viewports = @ptrCast(&viewport), .scissor_count = 1, .p_scissors = @ptrCast(&scissor) };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{ .flags = .{}, .depth_clamp_enable = vk.Bool32.false, .rasterizer_discard_enable = vk.Bool32.false, .polygon_mode = .fill, .cull_mode = .{}, .front_face = .counter_clockwise, .depth_bias_enable = vk.Bool32.false, .depth_bias_constant_factor = 0.0, .depth_bias_clamp = 0.0, .depth_bias_slope_factor = 0.0, .line_width = 1.0 };
        const multisampling = vk.PipelineMultisampleStateCreateInfo{ .flags = .{}, .rasterization_samples = .{ .@"1_bit" = true }, .sample_shading_enable = vk.Bool32.false, .min_sample_shading = 1.0, .p_sample_mask = null, .alpha_to_coverage_enable = vk.Bool32.false, .alpha_to_one_enable = vk.Bool32.false };

        const blend_attachment = vk.PipelineColorBlendAttachmentState{ .blend_enable = vk.Bool32.false, .src_color_blend_factor = .one, .dst_color_blend_factor = .zero, .color_blend_op = .add, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .zero, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true } };
        const color_blending = vk.PipelineColorBlendStateCreateInfo{ .flags = .{}, .logic_op_enable = vk.Bool32.false, .logic_op = .copy, .attachment_count = 1, .p_attachments = @ptrCast(&blend_attachment), .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 } };

        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{ .flags = .{}, .dynamic_state_count = dynamic_states.len, .p_dynamic_states = &dynamic_states };

        const pipeline_info = [_]vk.GraphicsPipelineCreateInfo{.{
            .flags = .{},
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state_info,
            .layout = self.pipeline_layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }};
        var pipelines: [1]vk.Pipeline = undefined;
        _ = try core.vkd.createGraphicsPipelines(core.logical_device, .null_handle, &pipeline_info, null, &pipelines);
        self.pipeline = pipelines[0];
        errdefer core.vkd.destroyPipeline(core.logical_device, self.pipeline, null);

        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .uniform_buffer, .descriptor_count = MAX_FRAMES_IN_FLIGHT },
            .{ .type = .combined_image_sampler, .descriptor_count = MAX_FRAMES_IN_FLIGHT },
        };
        self.descriptor_pool = try core.vkd.createDescriptorPool(core.logical_device, &.{ .flags = .{}, .max_sets = MAX_FRAMES_IN_FLIGHT, .pool_size_count = if (has_input) pool_sizes.len else pool_sizes.len - 1, .p_pool_sizes = &pool_sizes }, null);
        errdefer core.vkd.destroyDescriptorPool(core.logical_device, self.descriptor_pool, null);

        var set_layouts: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout = undefined;
        for (&set_layouts) |*l| l.* = self.descriptor_set_layout;
        _ = try core.vkd.allocateDescriptorSets(core.logical_device, &.{ .descriptor_pool = self.descriptor_pool, .descriptor_set_count = MAX_FRAMES_IN_FLIGHT, .p_set_layouts = &set_layouts }, &self.descriptor_sets);

        var created_buffers: usize = 0;
        errdefer for (self.ubo_buffers[0..created_buffers]) |*buf| buf.deinit(core);
        for (&self.ubo_buffers) |*buf| {
            buf.* = try Buffer.init(core, @sizeOf(Uniforms), .{ .uniform_buffer_bit = true }, c.VMA_MEMORY_USAGE_CPU_TO_GPU, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT));
            created_buffers += 1;
        }

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const ubo_descriptor = vk.DescriptorBufferInfo{ .buffer = self.ubo_buffers[i].handle, .offset = 0, .range = @sizeOf(Uniforms) };
            const input_descriptor = vk.DescriptorImageInfo{ .sampler = self.input_sampler, .image_view = if (self.input) |tex| tex.view else .null_handle, .image_layout = .shader_read_only_optimal };
            const writes = [_]vk.WriteDescriptorSet{
                .{ .dst_set = self.descriptor_sets[i], .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .uniform_buffer, .p_buffer_info = @ptrCast(&ubo_descriptor), .p_image_info = undefined, .p_texel_buffer_view = undefined },
                .{ .dst_set = self.descriptor_sets[i], .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = @ptrCast(&input_descriptor), .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
            };
            core.vkd.updateDescriptorSets(core.logical_device, if (has_input) writes[0..2] else writes[0..1], null);
        }

        return self;
    }

    pub fn destroy(self: *FragmentBacking, allocator: std.mem.Allocator, core: *const Core, texture_registry: *TextureRegistry) void {
        if (self.input) |*tex| {
            core.vkd.destroySampler(core.logical_device, self.input_sampler, null);
            tex.deinit(core);
        }
        for (&self.ubo_buffers) |*buf| buf.deinit(core);
        core.vkd.destroyDescriptorPool(core.logical_device, self.descriptor_pool, null);
        core.vkd.destroyPipeline(core.logical_device, self.pipeline, null);
        core.vkd.destroyPipelineLayout(core.logical_device, self.pipeline_layout, null);
        core.vkd.destroyDescriptorSetLayout(core.logical_device, self.descriptor_set_layout, null);
        core.vkd.destroyFramebuffer(core.logical_device, self.framebuffer, null);
        core.vkd.destroyRenderPass(core.logical_device, self.render_pass, null);
        texture_registry.releaseManagedView(self.tex_id);
        self.color.deinit(core);
        allocator.destroy(self);
    }

    pub fn setParam(self: *FragmentBacking, index: usize, value: [4]f32) void {
        if (index >= self.uniforms.user.len) return;
        self.uniforms.user[index] = value;
    }

    pub fn record(self: *FragmentBacking, core: *const Core, cb: vk.CommandBuffer, frame_index: usize, time: f32, frame: u32) void {
        const vkd = core.vkd;

        self.uniforms.delta = @max(0.0, time - self.uniforms.time);
        self.uniforms.time = time;
        self.uniforms.frame = frame;
        const ptr = self.ubo_buffers[frame_index].mapped_ptr.?;
        @memcpy(ptr[0..@sizeOf(Uniforms)], std.mem.asBytes(&self.uniforms));

        const clear = vk.ClearValue{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } } };
        const begin_info = vk.RenderPassBeginInfo{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffer,
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        };
        vkd.cmdBeginRenderPass(cb, &begin_info, .@"inline");
        vkd.cmdBindPipeline(cb, .graphics, self.pipeline);
        const viewport = vk.Viewport{ .x = 0.0, .y = 0.0, .width = @floatFromInt(self.width), .height = @floatFromInt(self.height), .min_depth = 0.0, .max_depth = 1.0 };
        vkd.cmdSetViewport(cb, 0, &[_]vk.Viewport{viewport});
        vkd.cmdSetScissor(cb, 0, &[_]vk.Rect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } }});
        vkd.cmdBindDescriptorSets(cb, .graphics, self.pipeline_layout, 0, &[_]vk.DescriptorSet{self.descriptor_sets[frame_index]}, null);
        vkd.cmdDraw(cb, 3, 1, 0, 0);
        vkd.cmdEndRenderPass(cb);
    }

    pub fn resize(self: *FragmentBacking, core: *const Core, texture_registry: *TextureRegistry, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return;
        if (width == self.width and height == self.height) return;

        core.vkd.destroyFramebuffer(core.logical_device, self.framebuffer, null);
        texture_registry.releaseManagedView(self.tex_id);
        self.color.deinit(core);

        self.color = try RenderTexture.init(core, .{ .width = width, .height = height }, .r8g8b8a8_unorm, .{ .@"1_bit" = true }, true);
        self.tex_id = try texture_registry.registerManagedView(core, self.color.view);
        self.framebuffer = try core.vkd.createFramebuffer(core.logical_device, &.{
            .flags = .{},
            .render_pass = self.render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&self.color.view),
            .width = width,
            .height = height,
            .layers = 1,
        }, null);

        self.width = width;
        self.height = height;
        self.uniforms.resolution = .{ @floatFromInt(width), @floatFromInt(height) };
    }
};
