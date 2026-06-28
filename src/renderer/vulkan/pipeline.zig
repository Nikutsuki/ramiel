const vert_spv align(@alignOf(u32)) = @embedFile("vert_spv").*;
const frag_spv align(@alignOf(u32)) = @embedFile("frag_spv").*;
const video_frag_spv align(@alignOf(u32)) = @embedFile("video_frag_spv").*;
const kawase_vert_spv align(@alignOf(u32)) = @embedFile("kawase_vert_spv").*;
const kawase_frag_spv align(@alignOf(u32)) = @embedFile("kawase_frag_spv").*;

const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;
const Instance = @import("vertex.zig").Instance;
const Mat4 = @import("math.zig").Mat4;

pub const Pipeline = struct {
    pub const MAX_BINDLESS_TEXTURES = 1024;

    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,

    descriptor_set_layout: vk.DescriptorSetLayout,
    owns_descriptor_set_layout: bool,

    pub fn init(core: *Core, render_pass: vk.RenderPass, extent: vk.Extent2D, samples: vk.SampleCountFlags) !Pipeline {
        if (vert_spv.len == 0) {
            return error.VertShaderLoadFailed;
        }
        if (frag_spv.len == 0) {
            return error.FragShaderLoadFailed;
        }

        const vert_module = try createShaderModule(core.vkd, core.logical_device, &vert_spv);
        const frag_module = try createShaderModule(core.vkd, core.logical_device, &frag_spv);
        defer core.vkd.destroyShaderModule(core.logical_device, vert_module, null);
        defer core.vkd.destroyShaderModule(core.logical_device, frag_module, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .flags = .{},
                .stage = .{ .vertex_bit = true },
                .module = vert_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{
                .flags = .{},
                .stage = .{ .fragment_bit = true },
                .module = frag_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
        };

        const binding_desc = Instance.getBindingDescription();
        const attribute_descs = Instance.getAttributeDescriptions();

        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding_desc),
            .vertex_attribute_description_count = attribute_descs.len,
            .p_vertex_attribute_descriptions = @ptrCast(&attribute_descs),
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = vk.Bool32.false,
        };

        const viewport = vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @as(f32, @floatFromInt(extent.width)),
            .height = @as(f32, @floatFromInt(extent.height)),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = @ptrCast(&viewport),
            .scissor_count = 1,
            .p_scissors = @ptrCast(&scissor),
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .flags = .{},
            .depth_clamp_enable = vk.Bool32.false,
            .rasterizer_discard_enable = vk.Bool32.false,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = false },
            .front_face = .clockwise,
            .depth_bias_enable = vk.Bool32.false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
            .line_width = 1.0,
        };

        const is_msaa = samples.toInt() > (@as(vk.Flags, 1));
        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .rasterization_samples = samples,
            .sample_shading_enable = vk.Bool32.false,
            .min_sample_shading = 1.0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = if (is_msaa) vk.Bool32.true else vk.Bool32.false,
            .alpha_to_one_enable = vk.Bool32.false,
        };

        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = vk.Bool32.true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .flags = .{},
            .logic_op_enable = vk.Bool32.false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            .p_immutable_samplers = null,
        };

        const offscreen_layout_binding = vk.DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };

        const sampler_layout_bindings = vk.DescriptorSetLayoutBinding{
            .binding = 2,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = MAX_BINDLESS_TEXTURES,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };

        const all_bindings = [_]vk.DescriptorSetLayoutBinding{
            ubo_layout_binding,
            offscreen_layout_binding,
            sampler_layout_bindings,
        };

        const binding_flags = [_]vk.DescriptorBindingFlags{
            .{},
            .{},
            .{
                .partially_bound_bit = true,
                .variable_descriptor_count_bit = true,
                .update_after_bind_bit = true,
            },
        };

        const flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .binding_count = all_bindings.len,
            .p_binding_flags = @ptrCast(&binding_flags),
        };

        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .p_next = @ptrCast(&flags_info),
            .flags = .{ .update_after_bind_pool_bit = true },
            .binding_count = all_bindings.len,
            .p_bindings = @ptrCast(&all_bindings),
        };

        const descriptor_set_layout = try core.vkd.createDescriptorSetLayout(core.logical_device, &layout_info, null);

        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .fragment_bit = true },
            .offset = 0,
            .size = @sizeOf([4]f32),
        };

        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant_range),
        };

        const layout = try core.vkd.createPipelineLayout(core.logical_device, &pipeline_layout_info, null);

        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = @ptrCast(&dynamic_states),
        };

        const pipeline_info = [_]vk.GraphicsPipelineCreateInfo{.{
            .flags = .{},
            .stage_count = shader_stages.len,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state_info,
            .layout = layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }};

        var pipelines: [1]vk.Pipeline = undefined;

        _ = try core.vkd.createGraphicsPipelines(core.logical_device, .null_handle, &pipeline_info, null, &pipelines);

        return Pipeline{
            .render_pass = render_pass,
            .layout = layout,
            .handle = pipelines[0],
            .descriptor_set_layout = descriptor_set_layout,
            .owns_descriptor_set_layout = true,
        };
    }

    pub fn initKawase(core: *const Core, render_pass: vk.RenderPass, descriptor_set_layout: vk.DescriptorSetLayout) !Pipeline {
        const vert_shader = try createShaderModule(core.vkd, core.logical_device, &kawase_vert_spv);
        defer core.vkd.destroyShaderModule(core.logical_device, vert_shader, null);

        const frag_shader = try createShaderModule(core.vkd, core.logical_device, &kawase_frag_spv);
        defer core.vkd.destroyShaderModule(core.logical_device, frag_shader, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .flags = .{}, .stage = .{ .vertex_bit = true }, .module = vert_shader, .p_name = "main", .p_specialization_info = null },
            .{ .flags = .{}, .stage = .{ .fragment_bit = true }, .module = frag_shader, .p_name = "main", .p_specialization_info = null },
        };

        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 0,
            .p_vertex_binding_descriptions = null,
            .vertex_attribute_description_count = 0,
            .p_vertex_attribute_descriptions = null,
        };

        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .fragment_bit = true },
            .offset = 0,
            .size = @sizeOf([4]u32),
        };

        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant_range),
        };

        const layout = try core.vkd.createPipelineLayout(core.logical_device, &pipeline_layout_info, null);

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = vk.Bool32.false,
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .flags = .{},
            .depth_clamp_enable = vk.Bool32.false,
            .rasterizer_discard_enable = vk.Bool32.false,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = false }, // Cull none for fullscreen triangle usually, or back
            .front_face = .clockwise,
            .depth_bias_enable = vk.Bool32.false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
            .line_width = 1.0,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .sample_shading_enable = vk.Bool32.false,
            .rasterization_samples = .{ .@"1_bit" = true },
            .min_sample_shading = 1.0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = vk.Bool32.false,
            .alpha_to_one_enable = vk.Bool32.false,
        };

        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            .blend_enable = vk.Bool32.false, // No blending for Kawase passes typically
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .flags = .{},
            .logic_op_enable = vk.Bool32.false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
        };

        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = null, // Dynamic
            .scissor_count = 1,
            .p_scissors = null, // Dynamic
        };

        const pipeline_info = [_]vk.GraphicsPipelineCreateInfo{
            .{
                .flags = .{},
                .stage_count = 2,
                .p_stages = &shader_stages,
                .p_vertex_input_state = &vertex_input_info,
                .p_input_assembly_state = &input_assembly,
                .p_viewport_state = &viewport_state,
                .p_rasterization_state = &rasterizer,
                .p_multisample_state = &multisampling,
                .p_depth_stencil_state = null,
                .p_color_blend_state = &color_blending,
                .p_dynamic_state = &dynamic_state_info,
                .layout = layout,
                .render_pass = render_pass,
                .subpass = 0,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            },
        };

        var pipelines: [1]vk.Pipeline = undefined;
        _ = try core.vkd.createGraphicsPipelines(core.logical_device, .null_handle, &pipeline_info, null, &pipelines);

        return Pipeline{
            .render_pass = render_pass,
            .layout = layout,
            .handle = pipelines[0],
            .descriptor_set_layout = descriptor_set_layout,
            .owns_descriptor_set_layout = false,
        };
    }

    pub fn initVideo(
        core: *const Core,
        render_pass: vk.RenderPass,
        extent: vk.Extent2D,
        samples: vk.SampleCountFlags,
    global_descriptor_set_layout: vk.DescriptorSetLayout,
        video_descriptor_set_layout: vk.DescriptorSetLayout,
    ) !Pipeline {
        if (vert_spv.len == 0) return error.VertShaderLoadFailed;
        if (video_frag_spv.len == 0) return error.FragShaderLoadFailed;

        const vert_module = try createShaderModule(core.vkd, core.logical_device, &vert_spv);
        const frag_module = try createShaderModule(core.vkd, core.logical_device, &video_frag_spv);
        defer core.vkd.destroyShaderModule(core.logical_device, vert_module, null);
        defer core.vkd.destroyShaderModule(core.logical_device, frag_module, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .flags = .{},
                .stage = .{ .vertex_bit = true },
                .module = vert_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{
                .flags = .{},
                .stage = .{ .fragment_bit = true },
                .module = frag_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
        };

        const binding_desc = Instance.getBindingDescription();
        const attribute_descs = Instance.getAttributeDescriptions();

        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding_desc),
            .vertex_attribute_description_count = attribute_descs.len,
            .p_vertex_attribute_descriptions = @ptrCast(&attribute_descs),
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = vk.Bool32.false,
        };

        const viewport = vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @as(f32, @floatFromInt(extent.width)),
            .height = @as(f32, @floatFromInt(extent.height)),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };

        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = @ptrCast(&viewport),
            .scissor_count = 1,
            .p_scissors = @ptrCast(&scissor),
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .flags = .{},
            .depth_clamp_enable = vk.Bool32.false,
            .rasterizer_discard_enable = vk.Bool32.false,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = false },
            .front_face = .clockwise,
            .depth_bias_enable = vk.Bool32.false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
            .line_width = 1.0,
        };

        const is_msaa = samples.toInt() > (@as(vk.Flags, 1));
        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .rasterization_samples = samples,
            .sample_shading_enable = vk.Bool32.false,
            .min_sample_shading = 1.0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = if (is_msaa) vk.Bool32.true else vk.Bool32.false,
            .alpha_to_one_enable = vk.Bool32.false,
        };

        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = vk.Bool32.true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .flags = .{},
            .logic_op_enable = vk.Bool32.false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .fragment_bit = true },
            .offset = 0,
            .size = @sizeOf([4]f32),
        };

        const set_layouts = [_]vk.DescriptorSetLayout{
            global_descriptor_set_layout,
            video_descriptor_set_layout,
        };
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = set_layouts.len,
            .p_set_layouts = &set_layouts,
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant_range),
        };

        const layout = try core.vkd.createPipelineLayout(core.logical_device, &pipeline_layout_info, null);

        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = @ptrCast(&dynamic_states),
        };

        const pipeline_info = [_]vk.GraphicsPipelineCreateInfo{.{
            .flags = .{},
            .stage_count = shader_stages.len,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state_info,
            .layout = layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }};

        var pipelines: [1]vk.Pipeline = undefined;
        _ = try core.vkd.createGraphicsPipelines(core.logical_device, .null_handle, &pipeline_info, null, &pipelines);

        return .{
            .render_pass = render_pass,
            .layout = layout,
            .handle = pipelines[0],
            .descriptor_set_layout = video_descriptor_set_layout,
            .owns_descriptor_set_layout = false,
        };
    }

    pub fn deinit(self: *Pipeline, core: *Core) void {
        core.vkd.destroyPipeline(core.logical_device, self.handle, null);
        core.vkd.destroyPipelineLayout(core.logical_device, self.layout, null);
        if (self.owns_descriptor_set_layout) {
            core.vkd.destroyDescriptorSetLayout(core.logical_device, self.descriptor_set_layout, null);
        }
    }
};

fn createShaderModule(vkd: vk.DeviceWrapper, dev: vk.Device, code: []const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = code.len,
        .p_code = @ptrCast(@alignCast(code.ptr)),
    };
    return try vkd.createShaderModule(dev, &create_info, null);
}
