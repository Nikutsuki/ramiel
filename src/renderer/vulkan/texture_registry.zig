const std = @import("std");
const vk = @import("../../vk.zig");
const vk_common = @import("vk_common.zig");
const c = vk_common.c;
const Core = @import("core.zig").Core;
const Texture = @import("texture.zig").Texture;
const TextureId = @import("../../assets.zig").TextureId;
const getTextureData = @import("../../assets.zig").getTextureData;
const NO_TEXTURE = @import("../../assets.zig").NO_TEXTURE;
const glfw = @import("glfw");
const MAX_BINDLESS = @import("pipeline.zig").Pipeline.MAX_BINDLESS_TEXTURES;
const gif_decoder = @import("../decoders/gif.zig");
const AnimatedState = @import("../image_animation.zig").AnimatedState;

pub const TextureState = enum { missing, decoding, ready };

pub const TextureEntry = struct {
    id: u32,
    state: TextureState,
    last_used_frame: u64 = 0,
    bytes_estimate: usize = 0,
    evictable: bool = false,
};

const PendingUpload = struct {
    name: []const u8,
    pixels: []u8,
    width: u32,
    height: u32,
    bytes_estimate: usize,
    animation: ?AnimatedState = null,
};

const DynamicTexture = struct {
    texture: Texture,
    animation: ?*AnimatedState = null,

    fn init(
        allocator: std.mem.Allocator,
        texture: Texture,
        animation: ?AnimatedState,
    ) !DynamicTexture {
        var animation_ptr: ?*AnimatedState = null;
        if (animation) |anim| {
            animation_ptr = try allocator.create(AnimatedState);
            animation_ptr.?.* = anim;
        }

        return .{
            .texture = texture,
            .animation = animation_ptr,
        };
    }

    fn deinit(self: *DynamicTexture, allocator: std.mem.Allocator, core: *const Core) void {
        if (self.animation) |anim| {
            anim.deinit(allocator);
            allocator.destroy(anim);
            self.animation = null;
        }
        self.texture.deinit(core);
    }
};

const LruCache = @import("lru_cache.zig").LruCache;

const LruValue = struct {
    descriptor_id: u32,
    bytes_estimate: usize,
};

const DecodeTaskArgs = struct {
    self: *TextureRegistry,
    name: []const u8,
    bytes: []u8,
    target_width: u32,
    target_height: u32,
};

pub const TextureRegistry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    vkd: vk.DeviceWrapper,
    logical_device: vk.Device,
    sampler: vk.Sampler,
    descriptor_sets: [2]vk.DescriptorSet,

    index_map: std.EnumArray(TextureId, u32),
    textures: std.ArrayList(Texture),
    texture_count: u32,
    fallback_tex_id: u32,

    dynamic_entries: std.StringHashMap(TextureEntry),
    state_mutex: std.Io.Mutex = .init,
    pending_mutex: std.Io.Mutex = .init,
    pending_uploads: std.ArrayList(PendingUpload),
    decode_futures: std.ArrayList(std.Io.Future(void)),
    free_descriptor_ids: std.ArrayList(u32),
    dynamic_textures: std.AutoHashMap(u32, DynamicTexture),
    dynamic_bytes_in_use: usize,
    dynamic_budget_bytes: usize,
    frame_index: u64,
    lru: LruCache(LruValue),

    pub const DEFAULT_DYNAMIC_BUDGET_BYTES: usize = 512 * 1024 * 1024;

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        core: *const Core,
        descriptor_sets: []const vk.DescriptorSet,
    ) !TextureRegistry {
        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .anisotropy_enable = vk.Bool32.false,
            .max_anisotropy = 1.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.Bool32.false,
            .compare_enable = vk.Bool32.false,
            .compare_op = .always,
            .mipmap_mode = .linear,
            .mip_lod_bias = 0.0,
            .min_lod = 0.0,
            .max_lod = 0.0,
        };

        const sampler = try core.vkd.createSampler(core.logical_device, &sampler_info, null);

        var sets: [2]vk.DescriptorSet = undefined;
        @memcpy(&sets, descriptor_sets[0..2]);

        var registry = TextureRegistry{
            .allocator = allocator,
            .io = io,
            .vkd = core.vkd,
            .logical_device = core.logical_device,
            .sampler = sampler,
            .descriptor_sets = sets,
            .index_map = std.EnumArray(TextureId, u32).initFill(0),
            .textures = .empty,
            .texture_count = 0,
            .fallback_tex_id = NO_TEXTURE,
            .dynamic_entries = std.StringHashMap(TextureEntry).init(allocator),
            .pending_uploads = .empty,
            .decode_futures = .empty,
            .free_descriptor_ids = .empty,
            .dynamic_textures = std.AutoHashMap(u32, DynamicTexture).init(allocator),
            .dynamic_bytes_in_use = 0,
            .dynamic_budget_bytes = DEFAULT_DYNAMIC_BUDGET_BYTES,
            .frame_index = 0,
            .lru = LruCache(LruValue).init(allocator),
        };

        try registry.preloadAll(core);
        registry.fallback_tex_id = registry.getIndex(.blank_canvas);
        return registry;
    }

    fn preloadAll(self: *TextureRegistry, core: *const Core) !void {
        inline for (std.meta.fields(TextureId)) |field| {
            const id = @field(TextureId, field.name);
            if (id == .blur_material or id == .sdf or id == .text) {
                self.index_map.set(id, NO_TEXTURE);
                continue;
            }

            const data = getTextureData(id);
            var texture: Texture = undefined;

            if (id == .blank_canvas) {
                texture = try Texture.init(core, 1, 1, data);
            } else {
                var width: c_int = 0;
                var height: c_int = 0;
                var channels: c_int = 0;

                const pixels_ptr = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &width, &height, &channels, 4);
                if (pixels_ptr == null) return error.TextureLoadFailed;
                defer c.stbi_image_free(pixels_ptr);

                const image_size = @as(usize, @intCast(width * height * 4));
                texture = try Texture.init(core, @intCast(width), @intCast(height), pixels_ptr[0..image_size]);
            }

            try self.textures.append(self.allocator, texture);
            const index = self.texture_count;

            self.index_map.set(id, index);
            self.updateDescriptor(texture.view, index);
            self.texture_count += 1;
        }
    }

    fn updateDescriptor(self: *TextureRegistry, image_view: vk.ImageView, index: u32) void {
        const image_info = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = image_view,
            .sampler = self.sampler,
        };

        for (self.descriptor_sets) |set| {
            const write_set = vk.WriteDescriptorSet{
                .dst_set = set,
                .dst_binding = 2,
                .dst_array_element = index,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast(&image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
            const writes = [_]vk.WriteDescriptorSet{write_set};
            self.vkd.updateDescriptorSets(self.logical_device, writes[0..], null);
        }
    }

    pub fn registerRawView(self: *TextureRegistry, image_view: vk.ImageView) u32 {
        const index = self.texture_count;
        self.updateDescriptor(image_view, index);
        self.texture_count += 1;
        return index;
    }

    pub fn registerManagedView(self: *TextureRegistry, core: *const Core, image_view: vk.ImageView) !u32 {
        const index = try self.allocateDynamicDescriptorId(core);
        self.updateDescriptor(image_view, index);
        return index;
    }

    pub fn uploadManagedRgba(
        self: *TextureRegistry,
        core: *const Core,
        pixels: []const u8,
        width: u32,
        height: u32,
    ) !u32 {
        if (width == 0 or height == 0) return error.InvalidTextureSize;

        var texture = try Texture.init(core, width, height, pixels);
        errdefer texture.deinit(core);

        const gpu_id = try self.allocateDynamicDescriptorId(core);
        errdefer self.releaseManagedView(gpu_id);

        self.updateDescriptor(texture.view, gpu_id);

        var dynamic_texture = try DynamicTexture.init(self.allocator, texture, null);
        errdefer dynamic_texture.deinit(self.allocator, core);

        try self.dynamic_textures.put(gpu_id, dynamic_texture);
        self.dynamic_bytes_in_use += @as(usize, width) * @as(usize, height) * 4;

        return gpu_id;
    }

    pub fn releaseManagedView(self: *TextureRegistry, index: u32) void {
        if (index == NO_TEXTURE) return;
        if (index >= MAX_BINDLESS) return;
        if (index < self.textures.items.len) return;

        for (self.free_descriptor_ids.items) |free_id| {
            if (free_id == index) return;
        }

        self.updateDescriptor(self.textures.items[self.fallback_tex_id].view, index);
        _ = self.free_descriptor_ids.append(self.allocator, index) catch {};
    }

    pub fn freeManagedTexture(self: *TextureRegistry, core: *const Core, index: u32) void {
        if (self.dynamic_textures.fetchRemove(index)) |removed| {
            var dynamic_texture = removed.value;
            self.dynamic_bytes_in_use -|= @as(usize, dynamic_texture.texture.width) *
                @as(usize, dynamic_texture.texture.height) * 4;
            dynamic_texture.deinit(self.allocator, core);
        }
        self.releaseManagedView(index);
    }

    pub fn updateRawView(self: *TextureRegistry, index: u32, image_view: vk.ImageView) void {
        self.updateDescriptor(image_view, index);
    }

    pub fn getIndex(self: *const TextureRegistry, id: TextureId) u32 {
        return self.index_map.get(id);
    }

    pub fn getImageId(self: *TextureRegistry, name: []const u8) u32 {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.dynamic_entries.getPtr(name)) |entry| {
            if (entry.state == .ready) {
                entry.last_used_frame = self.frame_index;
                self.lru.touch(name);
            }
            return entry.id;
        }
        return self.fallback_tex_id;
    }

    pub fn getImageAnimation(self: *TextureRegistry, name: []const u8) ?*const AnimatedState {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        const entry = self.dynamic_entries.get(name) orelse return null;
        if (entry.state != .ready) return null;
        const dynamic_tex = self.dynamic_textures.getPtr(entry.id) orelse return null;
        if (dynamic_tex.animation) |anim| return anim;
        return null;
    }

    pub fn getImageState(self: *TextureRegistry, name: []const u8) TextureState {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.dynamic_entries.get(name)) |entry| {
            return entry.state;
        }
        return .missing;
    }

    pub fn pushImageData(self: *TextureRegistry, name: []const u8, compressed_bytes: []const u8) !void {
        try self.pushImageDataWithHint(name, compressed_bytes, 0, 0);
    }

    pub fn pushImageDataWithHint(
        self: *TextureRegistry,
        name: []const u8,
        compressed_bytes: []const u8,
        target_width: u32,
        target_height: u32,
    ) !void {
        const bytes_dupe = try self.allocator.dupe(u8, compressed_bytes);
        errdefer self.allocator.free(bytes_dupe);
        const decode_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(decode_name);

        const decoding_value: TextureEntry = .{
            .id = self.fallback_tex_id,
            .state = .decoding,
            .last_used_frame = self.frame_index,
            .bytes_estimate = 0,
            .evictable = false,
        };

        self.state_mutex.lockUncancelable(std.Options.debug_io);
        if (self.dynamic_entries.getPtr(name)) |existing| {
            _ = self.lru.remove(name);
            existing.* = decoding_value;
        } else {
            const name_dupe = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_dupe);
            try self.dynamic_entries.put(name_dupe, decoding_value);
        }
        self.state_mutex.unlock(std.Options.debug_io);

        const future = self.io.concurrent(decodeWorker, .{.{
            .self = self,
            .name = decode_name,
            .bytes = bytes_dupe,
            .target_width = target_width,
            .target_height = target_height,
        }}) catch self.io.async(decodeWorker, .{.{
            .self = self,
            .name = decode_name,
            .bytes = bytes_dupe,
            .target_width = target_width,
            .target_height = target_height,
        }});

        self.pending_mutex.lockUncancelable(std.Options.debug_io);
        defer self.pending_mutex.unlock(std.Options.debug_io);
        try self.decode_futures.append(self.allocator, future);
    }

    fn decodeWorker(args: DecodeTaskArgs) void {
        const self = args.self;
        const name = args.name;
        const bytes = args.bytes;
        defer self.allocator.free(name);
        defer self.allocator.free(bytes);

        if (gif_decoder.isGifPayload(bytes)) {
            var decoded = gif_decoder.decodeToAtlas(self.allocator, bytes) catch |err| {
                std.log.warn(
                    "texture_registry: gif decode failed name='{s}' err={s}",
                    .{ name, @errorName(err) },
                );
                self.markDecodeFailed(name);
                return;
            };

            errdefer decoded.deinit(self.allocator);

            const upload_name = self.allocator.dupe(u8, name) catch {
                self.markDecodeFailed(name);
                return;
            };

            self.pending_mutex.lockUncancelable(std.Options.debug_io);
            defer self.pending_mutex.unlock(std.Options.debug_io);
            self.pending_uploads.append(self.allocator, .{
                .name = upload_name,
                .pixels = decoded.pixels,
                .width = decoded.width,
                .height = decoded.height,
                .bytes_estimate = decoded.pixels.len,
                .animation = decoded.animation,
            }) catch {
                self.allocator.free(upload_name);
                self.markDecodeFailed(name);
                return;
            };

            glfw.postEmptyEvent();
            return;
        }

        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;
        const pixels_c = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &ch, 4);
        if (pixels_c == null) {
            std.log.warn(
                "texture_registry: decode failed name='{s}' bytes={d} target={d}x{d}",
                .{ name, bytes.len, args.target_width, args.target_height },
            );
            self.markDecodeFailed(name);
            return;
        }
        defer c.stbi_image_free(pixels_c);

        const src_w: u32 = @intCast(w);
        const src_h: u32 = @intCast(h);
        const pixel_slice = pixels_c[0..@as(usize, @intCast(src_w * src_h * 4))];
        const downscale_dims = computeTargetDimensions(src_w, src_h, args.target_width, args.target_height);
        const pixels_dupe = downscaleRgba(
            self.allocator,
            pixel_slice,
            src_w,
            src_h,
            downscale_dims.width,
            downscale_dims.height,
        ) catch {
            self.markDecodeFailed(name);
            return;
        };
        const upload_name = self.allocator.dupe(u8, name) catch {
            self.allocator.free(pixels_dupe);
            self.markDecodeFailed(name);
            return;
        };

        self.pending_mutex.lockUncancelable(std.Options.debug_io);
        defer self.pending_mutex.unlock(std.Options.debug_io);
        self.pending_uploads.append(self.allocator, .{
            .name = upload_name,
            .pixels = pixels_dupe,
            .width = downscale_dims.width,
            .height = downscale_dims.height,
            .bytes_estimate = pixels_dupe.len,
        }) catch {
            self.allocator.free(upload_name);
            self.allocator.free(pixels_dupe);
            std.log.warn(
                "texture_registry: pending upload enqueue failed name='{s}' size={d}x{d}",
                .{ name, downscale_dims.width, downscale_dims.height },
            );
            self.markDecodeFailed(name);
            return;
        };

        glfw.postEmptyEvent();
    }

    fn markDecodeFailed(self: *TextureRegistry, name: []const u8) void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.dynamic_entries.getPtr(name)) |entry| {
            _ = self.lru.remove(name);
            entry.* = .{
                .id = self.fallback_tex_id,
                .state = .missing,
                .last_used_frame = self.frame_index,
                .bytes_estimate = 0,
                .evictable = false,
            };
        } else {
            std.log.warn("texture_registry: markDecodeFailed map miss name='{s}'", .{name});
        }
    }

    pub fn markImageMissing(self: *TextureRegistry, name: []const u8) !void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        const missing_value: TextureEntry = .{
            .id = self.fallback_tex_id,
            .state = .missing,
            .last_used_frame = self.frame_index,
            .bytes_estimate = 0,
            .evictable = false,
        };
        if (self.dynamic_entries.getPtr(name)) |existing| {
            _ = self.lru.remove(name);
            existing.* = missing_value;
        } else {
            const name_dupe = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_dupe);
            try self.dynamic_entries.put(name_dupe, missing_value);
        }
    }

    pub fn setFrameIndex(self: *TextureRegistry, frame_index: u64) void {
        self.frame_index = frame_index;
    }

    pub fn setDynamicBudgetBytes(self: *TextureRegistry, bytes: usize) void {
        self.dynamic_budget_bytes = bytes;
    }

    pub fn processPendingUploads(self: *TextureRegistry, core: *const Core) !usize {
        self.pending_mutex.lockUncancelable(std.Options.debug_io);

        const limit = @min(self.pending_uploads.items.len, 4);
        var uploads = std.ArrayList(PendingUpload).empty;
        if (limit > 0) {
            uploads.appendSlice(self.allocator, self.pending_uploads.items[0..limit]) catch {};
            const remaining = self.pending_uploads.items.len - limit;
            if (remaining > 0) {
                std.mem.copyForwards(PendingUpload, self.pending_uploads.items[0..remaining], self.pending_uploads.items[limit..]);
            }
            self.pending_uploads.shrinkRetainingCapacity(remaining);
        }

        self.pending_mutex.unlock(std.Options.debug_io);
        defer uploads.deinit(self.allocator);
        if (uploads.items.len > 0) {
        }

        var uploaded_count: usize = 0;
        for (uploads.items) |upload| {
            defer self.allocator.free(upload.pixels);
            defer self.allocator.free(upload.name);

            var pending_animation = upload.animation;
            defer releasePendingAnimation(self.allocator, pending_animation);

            const texture = Texture.init(core, upload.width, upload.height, upload.pixels) catch |err| {
                std.log.warn(
                    "texture_registry: GPU upload texture init failed name='{s}' size={d}x{d} err={s}",
                    .{ upload.name, upload.width, upload.height, @errorName(err) },
                );
                self.markDecodeFailed(upload.name);
                continue;
            };
            const gpu_id = self.allocateDynamicDescriptorId(core) catch |err| {
                std.log.warn(
                    "texture_registry: descriptor slot allocation failed name='{s}' err={s}",
                    .{ upload.name, @errorName(err) },
                );
                var tex_mut = texture;
                tex_mut.deinit(core);
                self.markDecodeFailed(upload.name);
                continue;
            };

            self.updateDescriptor(texture.view, gpu_id);

            var dynamic_texture = DynamicTexture.init(self.allocator, texture, pending_animation) catch |err| {
                std.log.warn(
                    "texture_registry: dynamic texture init failed name='{s}' tex_id={d} err={s}",
                    .{ upload.name, gpu_id, @errorName(err) },
                );
                var tex_mut = texture;
                tex_mut.deinit(core);
                self.updateDescriptor(self.textures.items[self.fallback_tex_id].view, gpu_id);
                _ = self.free_descriptor_ids.append(self.allocator, gpu_id) catch {};
                self.markDecodeFailed(upload.name);
                continue;
            };
            pending_animation = null;

            self.dynamic_textures.put(gpu_id, dynamic_texture) catch |err| {
                std.log.warn(
                    "texture_registry: dynamic texture map insert failed name='{s}' tex_id={d} err={s}",
                    .{ upload.name, gpu_id, @errorName(err) },
                );
                dynamic_texture.deinit(self.allocator, core);
                self.updateDescriptor(self.textures.items[self.fallback_tex_id].view, gpu_id);
                _ = self.free_descriptor_ids.append(self.allocator, gpu_id) catch {};
                self.markDecodeFailed(upload.name);
                continue;
            };

            self.dynamic_bytes_in_use += upload.bytes_estimate;
            while (self.dynamic_budget_bytes > 0 and self.dynamic_bytes_in_use > self.dynamic_budget_bytes) {
                if (!self.evictOne(core)) {
                    std.log.warn(
                        "texture_registry: cannot meet memory budget, all textures active or LRU empty",
                        .{},
                    );
                    break;
                }
            }

            self.state_mutex.lockUncancelable(std.Options.debug_io);
            if (self.dynamic_entries.getEntry(upload.name)) |kv| {
                const map_key = kv.key_ptr.*;
                _ = self.lru.remove(upload.name);
                self.lru.put(map_key, .{
                    .descriptor_id = gpu_id,
                    .bytes_estimate = upload.bytes_estimate,
                }) catch |err| {
                    std.log.warn(
                        "texture_registry: lru track failed name='{s}' tex_id={d} err={s} — entry still linked but non-evictable",
                        .{ upload.name, gpu_id, @errorName(err) },
                    );
                    kv.value_ptr.* = .{
                        .id = gpu_id,
                        .state = .ready,
                        .last_used_frame = self.frame_index,
                        .bytes_estimate = upload.bytes_estimate,
                        .evictable = false,
                    };
                    uploaded_count += 1;
                    self.state_mutex.unlock(std.Options.debug_io);
                    continue;
                };

                kv.value_ptr.* = .{
                    .id = gpu_id,
                    .state = .ready,
                    .last_used_frame = self.frame_index,
                    .bytes_estimate = upload.bytes_estimate,
                    .evictable = true,
                };
                uploaded_count += 1;
            } else {
                std.log.warn(
                    "texture_registry: upload entry miss name='{s}' tex_id={d} — destroying leaked texture",
                    .{ upload.name, gpu_id },
                );
                if (self.dynamic_textures.fetchRemove(gpu_id)) |removed| {
                    var dyn_tex = removed.value;
                    dyn_tex.deinit(self.allocator, core);
                }

                self.updateDescriptor(self.textures.items[self.fallback_tex_id].view, gpu_id);
                _ = self.free_descriptor_ids.append(self.allocator, gpu_id) catch {};
                self.dynamic_bytes_in_use -|= upload.bytes_estimate;
            }
            self.state_mutex.unlock(std.Options.debug_io);
        }

        return uploaded_count;
    }

    fn allocateDynamicDescriptorId(self: *TextureRegistry, core: *const Core) !u32 {
        if (self.free_descriptor_ids.items.len > 0) {
            return self.free_descriptor_ids.pop().?;
        }
        while (self.texture_count >= MAX_BINDLESS) {
            if (!self.evictOne(core)) {
                std.log.warn(
                    "texture_registry: descriptor array full (count={d}/{d}) and LRU is empty",
                    .{ self.texture_count, MAX_BINDLESS },
                );
                return error.NoFreeDescriptorSlot;
            }
            if (self.free_descriptor_ids.items.len > 0) {
                return self.free_descriptor_ids.pop().?;
            }
        }
        const index = self.texture_count;
        self.texture_count += 1;
        return index;
    }

    fn evictIfNeeded(self: *TextureRegistry, core: *const Core) void {
        while (self.dynamic_budget_bytes > 0 and self.dynamic_bytes_in_use > self.dynamic_budget_bytes) {
            if (!self.evictOne(core)) break;
        }
    }

    fn evictOne(self: *TextureRegistry, core: *const Core) bool {
        self.state_mutex.lockUncancelable(std.Options.debug_io);

        const victim = self.lru.popLeastRecentlyUsed() orelse {
            self.state_mutex.unlock(std.Options.debug_io);
            return false;
        };

        if (self.dynamic_entries.getPtr(victim.key)) |entry| {
            entry.* = .{
                .id = self.fallback_tex_id,
                .state = .missing,
                .last_used_frame = self.frame_index,
                .bytes_estimate = 0,
                .evictable = false,
            };
        }
        self.state_mutex.unlock(std.Options.debug_io);

        const removed = self.dynamic_textures.fetchRemove(victim.value.descriptor_id) orelse return false;
        var dynamic_texture = removed.value;
        dynamic_texture.deinit(self.allocator, core);
        self.dynamic_bytes_in_use -|= victim.value.bytes_estimate;
        self.updateDescriptor(self.textures.items[self.fallback_tex_id].view, victim.value.descriptor_id);
        _ = self.free_descriptor_ids.append(self.allocator, victim.value.descriptor_id) catch {};
        return true;
    }

    pub fn deinit(self: *TextureRegistry, core: *const Core) void {
        for (self.decode_futures.items) |*future| {
            future.cancel(self.io);
            future.await(self.io);
        }
        self.decode_futures.deinit(self.allocator);
        self.free_descriptor_ids.deinit(self.allocator);

        self.pending_mutex.lockUncancelable(std.Options.debug_io);
        for (self.pending_uploads.items) |upload| {
            self.allocator.free(upload.pixels);
            self.allocator.free(upload.name);
            releasePendingAnimation(self.allocator, upload.animation);
        }
        self.pending_uploads.deinit(self.allocator);
        self.pending_mutex.unlock(std.Options.debug_io);

        self.lru.deinit();

        var iter = self.dynamic_entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.dynamic_entries.deinit();

        var dyn_it = self.dynamic_textures.iterator();
        while (dyn_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator, core);
        }
        self.dynamic_textures.deinit();

        for (self.textures.items) |*texture| {
            texture.deinit(core);
        }
        self.textures.deinit(self.allocator);
        self.vkd.destroySampler(self.logical_device, self.sampler, null);
    }
};

const TargetDims = struct {
    width: u32,
    height: u32,
};

fn computeTargetDimensions(src_w: u32, src_h: u32, target_w: u32, target_h: u32) TargetDims {
    if (target_w == 0 or target_h == 0 or src_w == 0 or src_h == 0) {
        return .{ .width = src_w, .height = src_h };
    }

    const clamped_w = @max(target_w, 1);
    const clamped_h = @max(target_h, 1);
    if (src_w <= clamped_w and src_h <= clamped_h) {
        return .{ .width = src_w, .height = src_h };
    }

    const src_w_f: f64 = @floatFromInt(src_w);
    const src_h_f: f64 = @floatFromInt(src_h);
    const target_w_f: f64 = @floatFromInt(clamped_w);
    const target_h_f: f64 = @floatFromInt(clamped_h);
    const scale = @min(target_w_f / src_w_f, target_h_f / src_h_f);

    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@floor(src_w_f * scale))));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@floor(src_h_f * scale))));
    return .{ .width = out_w, .height = out_h };
}

fn downscaleRgba(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
) ![]u8 {
    if (dst_w == src_w and dst_h == src_h) {
        return allocator.dupe(u8, src);
    }

    const dst_len: usize = @as(usize, dst_w) * @as(usize, dst_h) * 4;
    const dst = try allocator.alloc(u8, dst_len);
    errdefer allocator.free(dst);

    const result = c.stbir_resize_uint8_linear(
        src.ptr,
        @intCast(src_w),
        @intCast(src_h),
        0,
        dst.ptr,
        @intCast(dst_w),
        @intCast(dst_h),
        0,
        c.STBIR_RGBA,
    );
    if (result == null) {
        return error.StbirResizeFailed;
    }

    return dst;
}

fn releasePendingAnimation(allocator: std.mem.Allocator, animation: ?AnimatedState) void {
    if (animation) |anim_val| {
        var anim = anim_val;
        anim.deinit(allocator);
    }
}
