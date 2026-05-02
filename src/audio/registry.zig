const std = @import("std");
const c = @import("c.zig").c;

const MAX_CONCURRENT_VOICES = 64;
pub const WakeUpCallback = *const fn () void;

pub const AssetDecodeState = enum { missing, decoding, ready };
pub const PlaybackState = enum { pending, playing };

pub const SoundPayload = union(enum) {
    path: [:0]const u8,
    memory: []const u8,
};

pub const SoundAsset = struct {
    master_sound: c.ma_sound,
    decoder: c.ma_decoder,
    payload: SoundPayload,
    state: AssetDecodeState,
    id: u32,
    name: []const u8,
    bytes_estimate: usize,
    abandoned: bool = false,
};

pub const PlaybackInstance = struct {
    sound: c.ma_sound,
    asset_id: u32,
    state: PlaybackState,
    pool_index: usize,
    registry: *SoundRegistry = undefined,
    is_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const StreamInstance = struct {
    sound: c.ma_sound,
    path: [:0]const u8,
    registry: *SoundRegistry,
    is_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const PlaybackPool = struct {
    instances: [MAX_CONCURRENT_VOICES]PlaybackInstance = undefined,
    free_mask: std.StaticBitSet(MAX_CONCURRENT_VOICES) = std.StaticBitSet(MAX_CONCURRENT_VOICES).initFull(),

    pub fn init() PlaybackPool {
        var pool: PlaybackPool = .{};
        for (0..MAX_CONCURRENT_VOICES) |idx| {
            pool.instances[idx] = .{
                .sound = undefined,
                .asset_id = 0,
                .state = .pending,
                .pool_index = idx,
                .registry = undefined,
                .is_finished = std.atomic.Value(bool).init(false),
            };
        }
        return pool;
    }

    pub fn acquire(self: *PlaybackPool) ?*PlaybackInstance {
        const idx = self.free_mask.findFirstSet() orelse return null;
        self.free_mask.unset(idx);
        const instance = &self.instances[idx];
        instance.sound = undefined;
        instance.asset_id = 0;
        instance.state = .pending;
        instance.pool_index = idx;
        instance.is_finished.store(false, .release);
        return instance;
    }

    pub fn release(self: *PlaybackPool, instance: *PlaybackInstance) void {
        instance.state = .pending;
        instance.asset_id = 0;
        instance.is_finished.store(false, .release);
        self.free_mask.set(instance.pool_index);
    }
};

const AssetLru = struct {
    const Entry = struct {
        key: u32,
        value: usize,
        link: std.DoublyLinkedList.Node = .{},
    };

    pub const PopResult = struct {
        key: u32,
        value: usize,
    };

    list: std.DoublyLinkedList = .{},
    map: std.AutoHashMap(u32, *Entry),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) AssetLru {
        return .{
            .map = std.AutoHashMap(u32, *Entry).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *AssetLru) void {
        var link = self.list.first;
        while (link) |node| {
            link = node.next;
            const entry: *Entry = @fieldParentPtr("link", node);
            self.allocator.destroy(entry);
        }
        self.map.deinit();
    }

    fn put(self: *AssetLru, key: u32, value: usize) !void {
        if (self.map.fetchRemove(key)) |removed| {
            self.list.remove(&removed.value.link);
            self.allocator.destroy(removed.value);
        }

        const entry = try self.allocator.create(Entry);
        entry.* = .{ .key = key, .value = value };
        self.list.append(&entry.link);
        errdefer {
            self.list.remove(&entry.link);
            self.allocator.destroy(entry);
        }

        try self.map.put(key, entry);
    }

    fn remove(self: *AssetLru, key: u32) ?usize {
        const removed = self.map.fetchRemove(key) orelse return null;
        self.list.remove(&removed.value.link);
        const value = removed.value.value;
        self.allocator.destroy(removed.value);
        return value;
    }

    fn touch(self: *AssetLru, key: u32) void {
        if (self.map.get(key)) |entry| {
            self.list.remove(&entry.link);
            self.list.append(&entry.link);
        }
    }

    fn getPtr(self: *AssetLru, key: u32) ?*usize {
        if (self.map.get(key)) |entry| {
            return &entry.value;
        }
        return null;
    }

    fn popLeastRecentlyUsed(self: *AssetLru) ?PopResult {
        const first_link = self.list.first orelse return null;
        const entry: *Entry = @fieldParentPtr("link", first_link);
        self.list.remove(&entry.link);
        _ = self.map.remove(entry.key);
        const result = PopResult{ .key = entry.key, .value = entry.value };
        self.allocator.destroy(entry);
        return result;
    }
};

pub const SoundRegistry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    engine: *c.ma_engine,
    sound_parent_node: ?*c.ma_node = null,

    next_asset_id: u32 = 1,
    name_to_id: std.StringHashMap(u32),
    assets: std.AutoHashMap(u32, *SoundAsset),

    voice_pool: PlaybackPool,
    active_playbacks: std.AutoHashMap(u64, *PlaybackInstance),
    active_streams: std.AutoHashMap(u64, *StreamInstance),
    next_playback_id: u64 = 1,

    lru: AssetLru,
    dynamic_bytes_in_use: usize = 0,
    dynamic_budget_bytes: usize = 64 * 1024 * 1024,
    wake_up_cb: ?WakeUpCallback = null,

    state_mutex: std.Io.Mutex = .init,

    pub fn setWakeUpCallback(self: *SoundRegistry, cb: WakeUpCallback) void {
        self.wake_up_cb = cb;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        engine: *c.ma_engine,
        sound_parent_node: ?*c.ma_node,
    ) !SoundRegistry {
        return .{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .sound_parent_node = sound_parent_node,
            .name_to_id = std.StringHashMap(u32).init(allocator),
            .assets = std.AutoHashMap(u32, *SoundAsset).init(allocator),
            .voice_pool = PlaybackPool.init(),
            .active_playbacks = std.AutoHashMap(u64, *PlaybackInstance).init(allocator),
            .active_streams = std.AutoHashMap(u64, *StreamInstance).init(allocator),
            .lru = AssetLru.init(allocator),
        };
    }

    fn attachToParent(self: *SoundRegistry, sound: *c.ma_sound) void {
        if (self.sound_parent_node) |parent| {
            _ = c.ma_node_attach_output_bus(@ptrCast(sound), 0, parent, 0);
        }
    }

    pub fn deinit(self: *SoundRegistry) void {
        var pb_it = self.active_playbacks.valueIterator();
        while (pb_it.next()) |playback_ptr| {
            const playback = playback_ptr.*;
            if (playback.state == .playing) {
                c.ma_sound_uninit(&playback.sound);
            }
            self.voice_pool.release(playback);
        }
        self.active_playbacks.deinit();

        var stream_it = self.active_streams.valueIterator();
        while (stream_it.next()) |stream_ptr| {
            const stream = stream_ptr.*;
            _ = c.ma_sound_stop(&stream.sound);
            c.ma_sound_uninit(&stream.sound);
            self.allocator.free(stream.path);
            self.allocator.destroy(stream);
        }
        self.active_streams.deinit();

        var asset_it = self.assets.valueIterator();
        while (asset_it.next()) |asset_ptr| {
            const asset = asset_ptr.*;
            if (asset.state == .ready) {
                c.ma_sound_uninit(&asset.master_sound);
                if (asset.payload == .memory) {
                    _ = c.ma_decoder_uninit(&asset.decoder);
                }
            }
            self.allocator.free(asset.name);
            switch (asset.payload) {
                .path => |p| self.allocator.free(p),
                .memory => |m| self.allocator.free(m),
            }
            self.allocator.destroy(asset);
        }
        self.assets.deinit();

        self.name_to_id.deinit();
        self.lru.deinit();
    }

    pub fn loadAndPlay(self: *SoundRegistry, name: []const u8, path: [:0]const u8) ?u64 {
        const asset_id = self.getSoundId(name, path) catch return null;
        return self.play(asset_id);
    }

    pub fn getSoundId(self: *SoundRegistry, name: []const u8, path: [:0]const u8) !u32 {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.name_to_id.get(name)) |id| {
            self.lru.touch(id);
            return id;
        }

        const id = self.next_asset_id;
        self.next_asset_id +%= 1;
        if (self.next_asset_id == 0) self.next_asset_id = 1;

        const name_dupe = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dupe);

        const path_dupe = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(path_dupe);

        const asset = try self.allocator.create(SoundAsset);
        errdefer self.allocator.destroy(asset);

        asset.* = .{
            .master_sound = undefined,
            .decoder = undefined,
            .payload = .{ .path = path_dupe },
            .state = .decoding,
            .id = id,
            .name = name_dupe,
            .bytes_estimate = 0,
            .abandoned = false,
        };

        try self.name_to_id.put(name_dupe, id);
        errdefer _ = self.name_to_id.remove(name_dupe);

        try self.assets.put(id, asset);
        errdefer _ = self.assets.remove(id);

        try self.lru.put(id, 0);

        self.enqueueDecodeTask(id, asset);
        return id;
    }

    pub fn loadMemory(self: *SoundRegistry, name: []const u8, bytes: []const u8) !u32 {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.name_to_id.get(name)) |id| {
            self.lru.touch(id);
            return id;
        }

        const id = self.next_asset_id;
        self.next_asset_id +%= 1;
        if (self.next_asset_id == 0) self.next_asset_id = 1;

        const name_dupe = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dupe);

        const bytes_dupe = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(bytes_dupe);

        const asset = try self.allocator.create(SoundAsset);
        errdefer self.allocator.destroy(asset);

        asset.* = .{
            .master_sound = undefined,
            .decoder = undefined,
            .payload = .{ .memory = bytes_dupe },
            .state = .decoding,
            .id = id,
            .name = name_dupe,
            .bytes_estimate = 0,
            .abandoned = false,
        };

        try self.name_to_id.put(name_dupe, id);
        errdefer _ = self.name_to_id.remove(name_dupe);

        try self.assets.put(id, asset);
        errdefer _ = self.assets.remove(id);

        try self.lru.put(id, 0);

        self.enqueueDecodeTask(id, asset);
        return id;
    }

    pub fn play(self: *SoundRegistry, asset_id: u32) ?u64 {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        const asset = self.assets.get(asset_id) orelse return null;
        if (asset.state == .missing) return null;

        self.lru.touch(asset_id);

        const playback = self.voice_pool.acquire() orelse {
            std.log.warn("SoundRegistry: MAX_CONCURRENT_VOICES exceeded.", .{});
            return null;
        };

        playback.asset_id = asset_id;
        playback.state = .pending;

        const playback_id = self.allocatePlaybackIdLocked();

        self.active_playbacks.put(playback_id, playback) catch {
            self.voice_pool.release(playback);
            return null;
        };

        if (asset.state == .ready) {
            self.initializeAndStartPlaybackLocked(playback, asset);
        }

        return playback_id;
    }

    pub fn playStream(self: *SoundRegistry, path: [:0]const u8) ?u64 {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        const stream = self.allocator.create(StreamInstance) catch return null;
        errdefer self.allocator.destroy(stream);

        const path_dupe = self.allocator.dupeZ(u8, path) catch return null;
        errdefer self.allocator.free(path_dupe);

        stream.* = .{
            .sound = undefined,
            .path = path_dupe,
            .registry = self,
            .is_finished = std.atomic.Value(bool).init(false),
        };

        const flags = c.MA_SOUND_FLAG_STREAM | c.MA_SOUND_FLAG_ASYNC;
        if (c.ma_sound_init_from_file(self.engine, stream.path.ptr, flags, null, null, &stream.sound) != c.MA_SUCCESS) {
            return null;
        }
        self.attachToParent(&stream.sound);
        _ = c.ma_sound_set_end_callback(&stream.sound, streamEndCallback, stream);

        const playback_id = self.allocatePlaybackIdLocked();
        self.active_streams.put(playback_id, stream) catch {
            c.ma_sound_uninit(&stream.sound);
            return null;
        };

        _ = c.ma_sound_start(&stream.sound);
        return playback_id;
    }

    pub fn stopById(self: *SoundRegistry, playback_id: u64) void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.active_streams.fetchRemove(playback_id)) |removed| {
            const stream = removed.value;
            _ = c.ma_sound_set_end_callback(&stream.sound, null, null);
            _ = c.ma_sound_stop(&stream.sound);
            c.ma_sound_uninit(&stream.sound);
            self.allocator.free(stream.path);
            self.allocator.destroy(stream);
            return;
        }

        if (self.active_playbacks.fetchRemove(playback_id)) |removed| {
            self.releasePlaybackLocked(removed.value, true);
        }
    }

    // Drops state_mutex before return. ma_sound_seek_to_second on mp3 blocks 100+ ms;
    // holding state_mutex across that stalls all readers. miniaudio locks the sound itself.
    fn lookupStreamSound(self: *SoundRegistry, playback_id: u64) ?*c.ma_sound {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);
        if (self.active_streams.get(playback_id)) |stream| {
            return &stream.sound;
        }
        return null;
    }

    pub fn seekStreamSeconds(self: *SoundRegistry, playback_id: u64, seconds: f32) void {
        const sound = self.lookupStreamSound(playback_id) orelse return;
        _ = c.ma_sound_seek_to_second(sound, @max(0.0, seconds));
    }

    pub fn pauseStream(self: *SoundRegistry, playback_id: u64) void {
        const sound = self.lookupStreamSound(playback_id) orelse return;
        _ = c.ma_sound_stop(sound);
    }

    pub fn resumeStream(self: *SoundRegistry, playback_id: u64) void {
        const sound = self.lookupStreamSound(playback_id) orelse return;
        _ = c.ma_sound_start(sound);
    }

    pub fn isStreamPlaying(self: *SoundRegistry, playback_id: u64) bool {
        const sound = self.lookupStreamSound(playback_id) orelse return false;
        return c.ma_sound_is_playing(sound) != 0;
    }

    pub fn getStreamCursorSeconds(self: *SoundRegistry, playback_id: u64) f32 {
        const sound = self.lookupStreamSound(playback_id) orelse return 0.0;
        var cursor: f32 = 0.0;
        if (c.ma_sound_get_cursor_in_seconds(sound, &cursor) == c.MA_SUCCESS) return cursor;
        return 0.0;
    }

    pub fn getStreamDurationSeconds(self: *SoundRegistry, playback_id: u64) f32 {
        const sound = self.lookupStreamSound(playback_id) orelse return 0.0;
        var length: f32 = 0.0;
        if (c.ma_sound_get_length_in_seconds(sound, &length) == c.MA_SUCCESS) return length;
        return 0.0;
    }

    pub fn setVolumeById(self: *SoundRegistry, playback_id: u64, volume: f32) void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.active_streams.get(playback_id)) |stream| {
            c.ma_sound_set_volume(&stream.sound, volume);
            return;
        }

        if (self.active_playbacks.get(playback_id)) |playback| {
            if (playback.state == .playing) {
                c.ma_sound_set_volume(&playback.sound, volume);
            }
        }
    }

    pub fn unload(self: *SoundRegistry, name: []const u8) void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        const removed_name = self.name_to_id.fetchRemove(name) orelse return;
        const asset_id = removed_name.value;
        _ = self.lru.remove(asset_id);

        self.stopAllPlaybacksForAssetLocked(asset_id);

        if (self.assets.fetchRemove(asset_id)) |removed| {
            const asset = removed.value;
            if (asset.state == .decoding) {
                asset.abandoned = true;
                return;
            }
            self.destroyAssetLocked(asset);
        }
    }

    pub fn processAudioCleanup(self: *SoundRegistry) void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        var found_stream = true;
        while (found_stream) {
            found_stream = false;
            var stream_it = self.active_streams.iterator();
            while (stream_it.next()) |entry| {
                const stream = entry.value_ptr.*;
                if (stream.is_finished.load(.acquire)) {
                    const id = entry.key_ptr.*;
                    const removed = self.active_streams.fetchRemove(id).?;
                    const finished = removed.value;
                    _ = c.ma_sound_set_end_callback(&finished.sound, null, null);
                    _ = c.ma_sound_stop(&finished.sound);
                    c.ma_sound_uninit(&finished.sound);
                    self.allocator.free(finished.path);
                    self.allocator.destroy(finished);
                    found_stream = true;
                    break;
                }
            }
        }

        var found_playback = true;
        while (found_playback) {
            found_playback = false;
            var pb_it = self.active_playbacks.iterator();
            while (pb_it.next()) |entry| {
                const playback = entry.value_ptr.*;
                if (playback.is_finished.load(.acquire)) {
                    const id = entry.key_ptr.*;
                    const removed = self.active_playbacks.fetchRemove(id).?;
                    self.releasePlaybackLocked(removed.value, false);
                    found_playback = true;
                    break;
                }
            }
        }
    }

    fn allocatePlaybackIdLocked(self: *SoundRegistry) u64 {
        const id = self.next_playback_id;
        self.next_playback_id +%= 1;
        if (self.next_playback_id == 0) self.next_playback_id = 1;
        return id;
    }

    fn releasePlaybackLocked(self: *SoundRegistry, playback: *PlaybackInstance, fade_out: bool) void {
        if (playback.state == .playing) {
            if (fade_out) {
                _ = c.ma_sound_stop_with_fade_in_milliseconds(&playback.sound, 12);
            } else {
                _ = c.ma_sound_stop(&playback.sound);
            }
            c.ma_sound_uninit(&playback.sound);
        }
        self.voice_pool.release(playback);
    }

    fn initializeAndStartPlaybackLocked(self: *SoundRegistry, playback: *PlaybackInstance, asset: *SoundAsset) void {
        if (playback.state != .pending) return;
        if (asset.state != .ready) return;

        if (c.ma_sound_init_copy(self.engine, &asset.master_sound, 0, null, &playback.sound) != c.MA_SUCCESS) {
            return;
        }
        self.attachToParent(&playback.sound);
        playback.registry = self;
        playback.is_finished.store(false, .release);
        _ = c.ma_sound_set_end_callback(&playback.sound, playbackEndCallback, playback);

        c.ma_sound_set_volume(&playback.sound, 1.0);
        if (c.ma_sound_start(&playback.sound) == c.MA_SUCCESS) {
            playback.state = .playing;
            _ = c.ma_sound_set_fade_in_milliseconds(&playback.sound, 0, 1, 12);
        } else {
            c.ma_sound_uninit(&playback.sound);
        }
    }

    fn stopAllPlaybacksForAssetLocked(self: *SoundRegistry, asset_id: u32) void {
        var found_any = true;
        while (found_any) {
            found_any = false;
            var it = self.active_playbacks.iterator();
            while (it.next()) |entry| {
                const playback = entry.value_ptr.*;
                if (playback.asset_id == asset_id) {
                    const id = entry.key_ptr.*;
                    const removed = self.active_playbacks.fetchRemove(id).?;
                    self.releasePlaybackLocked(removed.value, false);
                    found_any = true;
                    break;
                }
            }
        }
    }

    fn purgePendingPlaybacksForAssetLocked(self: *SoundRegistry, asset_id: u32) void {
        var found_any = true;
        while (found_any) {
            found_any = false;
            var it = self.active_playbacks.iterator();
            while (it.next()) |entry| {
                const playback = entry.value_ptr.*;
                if (playback.asset_id == asset_id and playback.state == .pending) {
                    const id = entry.key_ptr.*;
                    const removed = self.active_playbacks.fetchRemove(id).?;
                    self.voice_pool.release(removed.value);
                    found_any = true;
                    break;
                }
            }
        }
    }

    fn enqueueDecodeTask(self: *SoundRegistry, asset_id: u32, asset: *SoundAsset) void {
        _ = self.io.concurrent(decodeTask, .{.{
            .registry = self,
            .asset_id = asset_id,
            .asset = asset,
        }}) catch {
            _ = self.io.async(decodeTask, .{.{
                .registry = self,
                .asset_id = asset_id,
                .asset = asset,
            }});
        };
    }

    fn decodeTask(args: struct { registry: *SoundRegistry, asset_id: u32, asset: *SoundAsset }) void {
        const flags = c.MA_SOUND_FLAG_DECODE;
        var result: c.ma_result = c.MA_ERROR;

        switch (args.asset.payload) {
            .path => |p| {
                result = c.ma_sound_init_from_file(args.registry.engine, p.ptr, flags, null, null, &args.asset.master_sound);
            },
            .memory => |m| {
                result = c.ma_decoder_init_memory(m.ptr, m.len, null, &args.asset.decoder);
                if (result == c.MA_SUCCESS) {
                    result = c.ma_sound_init_from_data_source(args.registry.engine, @ptrCast(&args.asset.decoder), flags, null, &args.asset.master_sound);

                    if (result != c.MA_SUCCESS) {
                        _ = c.ma_decoder_uninit(&args.asset.decoder);
                    }
                }
            },
        }

        args.registry.state_mutex.lockUncancelable(std.Options.debug_io);
        defer args.registry.state_mutex.unlock(std.Options.debug_io);

        if (args.asset.abandoned) {
            if (result == c.MA_SUCCESS) {
                c.ma_sound_uninit(&args.asset.master_sound);
                if (args.asset.payload == .memory) {
                    _ = c.ma_decoder_uninit(&args.asset.decoder);
                }
            }
            args.registry.allocator.free(args.asset.name);
            switch (args.asset.payload) {
                .path => |p| args.registry.allocator.free(p),
                .memory => |m| args.registry.allocator.free(m),
            }
            args.registry.allocator.destroy(args.asset);
            return;
        }

        if (result == c.MA_SUCCESS) {
            args.asset.state = .ready;

            var format: c.ma_format = c.ma_format_unknown;
            var channels: c.ma_uint32 = 0;
            if (c.ma_sound_get_data_format(&args.asset.master_sound, &format, &channels, null, null, 0) != c.MA_SUCCESS) {
                format = c.ma_format_s16;
                channels = 2;
            }

            var length_frames: c.ma_uint64 = 0;
            if (c.ma_sound_get_length_in_pcm_frames(&args.asset.master_sound, &length_frames) != c.MA_SUCCESS) {
                length_frames = 0;
            }
            const frame_count: usize = @intCast(length_frames);
            const channel_count: usize = @max(@as(usize, @intCast(channels)), 1);
            const bps_raw: usize = @intCast(c.ma_get_bytes_per_sample(format));
            const bytes_per_sample: usize = if (bps_raw == 0) 2 else bps_raw;
            const frame_bytes = std.math.mul(usize, frame_count, channel_count) catch std.math.maxInt(usize);
            const bytes_estimate = std.math.mul(usize, frame_bytes, bytes_per_sample) catch std.math.maxInt(usize);

            args.asset.bytes_estimate = bytes_estimate;
            args.registry.dynamic_bytes_in_use +|= bytes_estimate;

            if (args.registry.lru.getPtr(args.asset_id)) |value_ptr| {
                value_ptr.* = bytes_estimate;
            } else {
                args.registry.lru.put(args.asset_id, bytes_estimate) catch {};
            }

            args.registry.evictIfNeededLocked();

            var it = args.registry.active_playbacks.valueIterator();
            while (it.next()) |playback_ptr| {
                const playback = playback_ptr.*;
                if (playback.asset_id == args.asset_id and playback.state == .pending) {
                    args.registry.initializeAndStartPlaybackLocked(playback, args.asset);
                }
            }
        } else {
            args.asset.state = .missing;
            args.registry.purgePendingPlaybacksForAssetLocked(args.asset_id);
        }
    }

    fn evictIfNeededLocked(self: *SoundRegistry) void {
        while (self.dynamic_budget_bytes > 0 and self.dynamic_bytes_in_use > self.dynamic_budget_bytes) {
            const victim = self.lru.popLeastRecentlyUsed() orelse break;
            self.evictAssetLocked(victim.key);
        }
    }

    fn evictAssetLocked(self: *SoundRegistry, asset_id: u32) void {
        const removed = self.assets.fetchRemove(asset_id) orelse return;
        const asset = removed.value;

        _ = self.lru.remove(asset_id);
        _ = self.name_to_id.remove(asset.name);

        self.stopAllPlaybacksForAssetLocked(asset_id);

        if (asset.state == .decoding) {
            asset.abandoned = true;
            return;
        }

        self.destroyAssetLocked(asset);
    }

    fn destroyAssetLocked(self: *SoundRegistry, asset: *SoundAsset) void {
        if (asset.state == .ready) {
            c.ma_sound_uninit(&asset.master_sound);
            if (asset.payload == .memory) {
                _ = c.ma_decoder_uninit(&asset.decoder);
            }
            self.dynamic_bytes_in_use -|= asset.bytes_estimate;
        }

        self.allocator.free(asset.name);
        switch (asset.payload) {
            .path => |p| self.allocator.free(p),
            .memory => |m| self.allocator.free(m),
        }
        self.allocator.destroy(asset);
    }
};

fn streamEndCallback(pUserData: ?*anyopaque, pSound: [*c]c.ma_sound) callconv(.c) void {
    _ = pSound;
    const user = pUserData orelse return;
    const stream: *StreamInstance = @ptrCast(@alignCast(user));
    stream.is_finished.store(true, .release);

    if (stream.registry.wake_up_cb) |wake_up| {
        wake_up();
    }
}

fn playbackEndCallback(pUserData: ?*anyopaque, pSound: [*c]c.ma_sound) callconv(.c) void {
    _ = pSound;
    const user = pUserData orelse return;
    const playback: *PlaybackInstance = @ptrCast(@alignCast(user));
    playback.is_finished.store(true, .release);

    if (playback.registry.wake_up_cb) |wake_up| {
        wake_up();
    }
}
