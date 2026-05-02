const std = @import("std");
const vk = @import("../../vk.zig");

pub const VulkanRenderPass = struct {
    handle: vk.RenderPass,

    pub fn init(
        vkd: vk.DeviceWrapper,
        dev: vk.Device,
        format: vk.Format,
        initial_layout: vk.ImageLayout,
        final_layout: vk.ImageLayout,
        load_op: vk.AttachmentLoadOp,
        samples: vk.SampleCountFlags,
    ) !VulkanRenderPass {
        const is_msaa = samples.toInt() > (@as(vk.Flags, 1));
        var attachments: [2]vk.AttachmentDescription = undefined;
        var attachment_count: u32 = 1;

        attachments[0] = vk.AttachmentDescription{
            .flags = .{},
            .format = format,
            .samples = samples,
            .load_op = load_op,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = initial_layout,
            .final_layout = if (is_msaa) .color_attachment_optimal else final_layout,
        };

        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };
        var resolve_attachment_ref = vk.AttachmentReference{
            .attachment = 1,
            .layout = .color_attachment_optimal,
        };

        if (is_msaa) {
            attachments[1] = vk.AttachmentDescription{
                .flags = .{},
                .format = format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .dont_care,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = initial_layout,
                .final_layout = final_layout,
            };
            attachment_count = 2;
        }

        const subpass = vk.SubpassDescription{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_ref),
            .p_resolve_attachments = if (is_msaa) @ptrCast(&resolve_attachment_ref) else null,
            .p_depth_stencil_attachment = null,
            .input_attachment_count = 0,
            .p_input_attachments = null,
            .p_preserve_attachments = null,
        };

        const render_pass_info = vk.RenderPassCreateInfo{
            .flags = .{},
            .attachment_count = attachment_count,
            .p_attachments = @ptrCast(&attachments),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 0,
            .p_dependencies = null,
        };

        return VulkanRenderPass{
            .handle = try vkd.createRenderPass(dev, &render_pass_info, null),
        };
    }

    pub fn deinit(self: *VulkanRenderPass, vkd: vk.DeviceWrapper, dev: vk.Device) void {
        vkd.destroyRenderPass(dev, self.handle, null);
    }
};
