const std = @import("std");
const vk = @import("../vk.zig");
const VideoPlayback = @import("playback.zig").VideoPlayback;
const Core = @import("../renderer/vulkan/core.zig").Core;
const TextureRegistry = @import("../renderer/vulkan/texture_registry.zig").TextureRegistry;
const YuvTexture = @import("../renderer/vulkan/yuv_texture.zig").YuvTexture;
const ma = @import("../audio/c.zig").c;

pub const VideoManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    core: *const Core,
    texture_registry: *TextureRegistry,
    video_descriptor_set_layout: vk.DescriptorSetLayout,
    audio_engine: *ma.ma_engine,
    frame_slots: usize,
    playbacks: std.AutoHashMap(u32, *VideoPlayback),
    next_id: u32 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        core: *const Core,
        texture_registry: *TextureRegistry,
        video_descriptor_set_layout: vk.DescriptorSetLayout,
        audio_engine: *ma.ma_engine,
        frame_slots: usize,
    ) VideoManager {
        return .{
            .allocator = allocator,
            .io = io,
            .core = core,
            .texture_registry = texture_registry,
            .video_descriptor_set_layout = video_descriptor_set_layout,
            .audio_engine = audio_engine,
            .frame_slots = frame_slots,
            .playbacks = std.AutoHashMap(u32, *VideoPlayback).init(allocator),
        };
    }

    pub fn deinit(self: *VideoManager) void {
        var it = self.playbacks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.core, self.texture_registry);
        }
        self.playbacks.deinit();
    }

    pub fn createPlayback(self: *VideoManager, path: [:0]const u8) !*VideoPlayback {
        const pb = try VideoPlayback.initAsync(self.allocator, self.io, self.next_id, path, self.audio_engine);
        try self.playbacks.put(self.next_id, pb);
        self.next_id += 1;
        return pb;
    }

    pub fn destroyPlayback(self: *VideoManager, id: u32) void {
        if (self.playbacks.fetchRemove(id)) |entry| {
            entry.value.deinit(self.core, self.texture_registry);
        }
    }

    pub fn hasActivePlayback(self: *const VideoManager) bool {
        var it = self.playbacks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.state == .playing) return true;
        }
        return false;
    }

    pub fn getMinFrameTime(self: *const VideoManager) ?f64 {
        var min_time: ?f64 = null;
        var it = self.playbacks.iterator();
        while (it.next()) |entry| {
            const pb = entry.value_ptr.*;
            if (pb.state != .playing) continue;
            const frame_time = 1.0 / pb.fps;
            if (min_time) |m| {
                min_time = @min(m, frame_time);
            } else {
                min_time = frame_time;
            }
        }
        return min_time;
    }

    pub fn tick(self: *VideoManager, frame_index: usize) !bool {
        var it = self.playbacks.iterator();
        var any_frames_uploaded = false;
        while (it.next()) |entry| {
            const pb = entry.value_ptr.*;

            if (pb.state != .loading and pb.state != .error_state and pb.state != .ended and pb.texture == null) {
                pb.texture = try YuvTexture.create(
                    self.allocator,
                    self.core,
                    self.texture_registry,
                    self.video_descriptor_set_layout,
                    pb.width,
                    pb.height,
                    self.frame_slots,
                );
            }
            any_frames_uploaded = (try pb.tickPlayback(frame_index)) or any_frames_uploaded;
        }

        return any_frames_uploaded;
    }

    pub fn getMinWaitTimeS(self: *VideoManager) ?f64 {
        var min_wait: ?f64 = null;
        var it = self.playbacks.valueIterator();
        while (it.next()) |pb| {
            if (pb.*.getTimeUntilNextFrameS()) |wait_s| {
                if (min_wait) |current_min| {
                    min_wait = @min(current_min, wait_s);
                } else {
                    min_wait = wait_s;
                }
            }
        }
        return min_wait;
    }

    pub fn recordUploads(self: *VideoManager, frame_index: usize, vkd: vk.DeviceWrapper, cb: vk.CommandBuffer) void {
        var it = self.playbacks.valueIterator();
        while (it.next()) |playback| {
            if (!playback.*.upload_pending) continue;
            if (playback.*.texture) |tex| {
                tex.recordUpload(frame_index, vkd, cb);
            }
            playback.*.upload_pending = false;
        }
    }
};
