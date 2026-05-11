const std = @import("std");
const c = @import("c.zig").c;

const MAX_CONCURRENT_VOICES = 64;
pub const WakeUpCallback = *const fn () void;

pub const AssetDecodeState = enum { missing, decoding, ready };
pub const PlaybackState = enum { pending, playing };

pub const StreamSeekStatus = struct {
    active: bool = false,
    seeking: bool = false,
    playback_id: ?u64 = null,
};

pub const AdvanceEvent = struct {
    /// The id that just finished and was replaced.
    finished_id: u64,
    /// The id of the freshly-started follow-up stream.
    new_id: u64,
};

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
    /// Set by enqueueAfter; processed in cleanup so the next track starts as soon
    /// as the previous one signals end-of-stream (gapless within group).
    next_path: ?[:0]const u8 = null,
    /// Owned by registry; on advance the new stream id is published here so the app
    /// can pick it up via takeAdvancedTo().
    advanced_to: ?u64 = null,
    /// Wall-clock deadline (ms since epoch) at which crossfade-out completes
    /// and the stream should be torn down. null = no scheduled fade-out.
    fade_out_deadline_ms: ?i64 = null,
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
    stream_op_mutex: std.Io.Mutex = .init,
    stream_seek_worker: *StreamSeekWorker,

    /// Posted by processAudioCleanup when a queued track has been started in place
    /// of a finished one. App polls via takeAdvancedTo() to learn the new id.
    advance_events: std.ArrayList(AdvanceEvent) = .empty,

    pub fn setWakeUpCallback(self: *SoundRegistry, cb: WakeUpCallback) void {
        self.wake_up_cb = cb;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        engine: *c.ma_engine,
        sound_parent_node: ?*c.ma_node,
    ) !SoundRegistry {
        const seek_worker = try allocator.create(StreamSeekWorker);
        errdefer allocator.destroy(seek_worker);
        seek_worker.* = StreamSeekWorker.init(io);
        seek_worker.thread = try std.Thread.spawn(.{}, StreamSeekWorker.run, .{seek_worker});

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
            .stream_seek_worker = seek_worker,
        };
    }

    fn attachToParent(self: *SoundRegistry, sound: *c.ma_sound) void {
        if (self.sound_parent_node) |parent| {
            _ = c.ma_node_attach_output_bus(@ptrCast(sound), 0, parent, 0);
        }
    }

    pub fn deinit(self: *SoundRegistry) void {
        self.stream_seek_worker.deinit(self.allocator);
        self.advance_events.deinit(self.allocator);

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
            self.destroyStreamLocked(stream_ptr.*);
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
            self.destroyStreamLocked(removed.value);
            return;
        }

        if (self.active_playbacks.fetchRemove(playback_id)) |removed| {
            self.releasePlaybackLocked(removed.value, true);
        }
    }

    fn acquireStreamSound(self: *SoundRegistry, playback_id: u64) ?*c.ma_sound {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        if (self.active_streams.get(playback_id)) |stream| {
            self.stream_op_mutex.lockUncancelable(std.Options.debug_io);
            self.state_mutex.unlock(std.Options.debug_io);
            return &stream.sound;
        }
        self.state_mutex.unlock(std.Options.debug_io);
        return null;
    }

    pub fn seekStreamSeconds(self: *SoundRegistry, playback_id: u64, seconds: f32) void {
        self.stream_seek_worker.submit(self, playback_id, seconds);
    }

    pub fn seekStreamSecondsImmediate(self: *SoundRegistry, playback_id: u64, seconds: f32) void {
        const sound = self.acquireStreamSound(playback_id) orelse return;
        defer self.stream_op_mutex.unlock(std.Options.debug_io);
        _ = c.ma_sound_seek_to_second(sound, @max(0.0, seconds));
    }

    pub fn pauseStream(self: *SoundRegistry, playback_id: u64) void {
        const sound = self.acquireStreamSound(playback_id) orelse return;
        defer self.stream_op_mutex.unlock(std.Options.debug_io);
        _ = c.ma_sound_stop(sound);
    }

    pub fn resumeStream(self: *SoundRegistry, playback_id: u64) void {
        const sound = self.acquireStreamSound(playback_id) orelse return;
        defer self.stream_op_mutex.unlock(std.Options.debug_io);
        _ = c.ma_sound_start(sound);
    }

    pub fn isStreamPlaying(self: *SoundRegistry, playback_id: u64) bool {
        const sound = self.acquireStreamSound(playback_id) orelse return false;
        defer self.stream_op_mutex.unlock(std.Options.debug_io);
        return c.ma_sound_is_playing(sound) != 0;
    }

    pub fn getStreamCursorSeconds(self: *SoundRegistry, playback_id: u64) f32 {
        const sound = self.acquireStreamSound(playback_id) orelse return 0.0;
        defer self.stream_op_mutex.unlock(std.Options.debug_io);
        var cursor: f32 = 0.0;
        if (c.ma_sound_get_cursor_in_seconds(sound, &cursor) == c.MA_SUCCESS) return cursor;
        return 0.0;
    }

    pub fn getStreamDurationSeconds(self: *SoundRegistry, playback_id: u64) f32 {
        const sound = self.acquireStreamSound(playback_id) orelse return 0.0;
        defer self.stream_op_mutex.unlock(std.Options.debug_io);
        var length: f32 = 0.0;
        if (c.ma_sound_get_length_in_seconds(sound, &length) == c.MA_SUCCESS) return length;
        return 0.0;
    }

    pub fn getStreamSeekStatus(self: *SoundRegistry) StreamSeekStatus {
        return self.stream_seek_worker.status();
    }

    pub fn isStreamSeeking(self: *SoundRegistry, playback_id: u64) bool {
        const s = self.stream_seek_worker.status();
        return s.seeking and s.playback_id == playback_id;
    }

    pub fn isStreamSeekActive(self: *SoundRegistry, playback_id: u64) bool {
        const s = self.stream_seek_worker.status();
        return s.active and s.playback_id == playback_id;
    }

    pub fn setVolumeById(self: *SoundRegistry, playback_id: u64, volume: f32) void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.active_streams.get(playback_id)) |stream| {
            self.stream_op_mutex.lockUncancelable(std.Options.debug_io);
            defer self.stream_op_mutex.unlock(std.Options.debug_io);
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

        const now_ms: i64 = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();

        // Stop streams whose crossfade-out deadline has passed.
        var found_fade = true;
        while (found_fade) {
            found_fade = false;
            var fade_it = self.active_streams.iterator();
            while (fade_it.next()) |entry| {
                const stream = entry.value_ptr.*;
                if (stream.fade_out_deadline_ms) |dl| {
                    if (now_ms >= dl) {
                        const id = entry.key_ptr.*;
                        const removed = self.active_streams.fetchRemove(id).?;
                        self.destroyStreamLocked(removed.value);
                        found_fade = true;
                        break;
                    }
                }
            }
        }

        var found_stream = true;
        while (found_stream) {
            found_stream = false;
            var stream_it = self.active_streams.iterator();
            while (stream_it.next()) |entry| {
                const stream = entry.value_ptr.*;
                if (stream.is_finished.load(.acquire)) {
                    const id = entry.key_ptr.*;
                    // Pull next_path off the dying stream before we destroy it.
                    const queued = stream.next_path;
                    stream.next_path = null;
                    const removed = self.active_streams.fetchRemove(id).?;
                    self.destroyStreamLocked(removed.value);
                    found_stream = true;

                    if (queued) |path| {
                        defer self.allocator.free(path);
                        // Re-acquire by dropping our state_mutex during the inner playStream
                        // (it locks state_mutex itself). Since we already released the entry,
                        // it's safe to unlock briefly.
                        self.state_mutex.unlock(std.Options.debug_io);
                        const new_id_opt = self.playStream(path);
                        self.state_mutex.lockUncancelable(std.Options.debug_io);
                        if (new_id_opt) |new_id| {
                            self.advance_events.append(self.allocator, .{
                                .finished_id = id,
                                .new_id = new_id,
                            }) catch {};
                        }
                    }
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

    fn destroyStreamLocked(self: *SoundRegistry, stream: *StreamInstance) void {
        self.stream_op_mutex.lockUncancelable(std.Options.debug_io);
        defer self.stream_op_mutex.unlock(std.Options.debug_io);

        _ = c.ma_sound_set_end_callback(&stream.sound, null, null);
        _ = c.ma_sound_stop(&stream.sound);
        c.ma_sound_uninit(&stream.sound);
        self.allocator.free(stream.path);
        if (stream.next_path) |np| self.allocator.free(np);
        self.allocator.destroy(stream);
    }

    /// Queue a follow-up stream. When `current_id` ends naturally, processAudioCleanup
    /// will start `next_path` and publish a new playback id via takeAdvancedEvents().
    /// Replaces any previously-queued path. Caller retains ownership of `next_path`;
    /// it is duped internally.
    pub fn enqueueAfter(self: *SoundRegistry, current_id: u64, next_path: [:0]const u8) !void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        const stream = self.active_streams.get(current_id) orelse return error.NoSuchStream;
        const dupe = try self.allocator.dupeZ(u8, next_path);
        if (stream.next_path) |old| self.allocator.free(old);
        stream.next_path = dupe;
    }

    pub fn clearQueuedAfter(self: *SoundRegistry, current_id: u64) void {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);
        const stream = self.active_streams.get(current_id) orelse return;
        if (stream.next_path) |old| {
            self.allocator.free(old);
            stream.next_path = null;
        }
    }

    /// Crossfade between an existing stream and a new file path. Returns the new
    /// stream's playback id. The old stream fades to zero over `fade_ms` and is
    /// torn down by processAudioCleanup once the deadline passes.
    pub fn startCrossfade(
        self: *SoundRegistry,
        out_id: u64,
        in_path: [:0]const u8,
        fade_ms: u32,
    ) !u64 {
        const new_id = self.playStream(in_path) orelse return error.PlayStreamFailed;

        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.active_streams.get(new_id)) |new_stream| {
            self.stream_op_mutex.lockUncancelable(std.Options.debug_io);
            defer self.stream_op_mutex.unlock(std.Options.debug_io);
            // miniaudio applies fade on top of the base volume (final = volume * fade),
            // so DON'T setVolume(0) here - that pins the result at 0 forever. Leave
            // base volume at 1.0 and let the fade-in ramp the multiplier 0 → 1.
            _ = c.ma_sound_set_fade_in_milliseconds(&new_stream.sound, 0.0, 1.0, fade_ms);
        }

        if (self.active_streams.get(out_id)) |out_stream| {
            self.stream_op_mutex.lockUncancelable(std.Options.debug_io);
            defer self.stream_op_mutex.unlock(std.Options.debug_io);
            _ = c.ma_sound_set_fade_in_milliseconds(&out_stream.sound, -1.0, 0.0, fade_ms);
            const now_ms: i64 = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
            out_stream.fade_out_deadline_ms = now_ms + @as(i64, @intCast(fade_ms));
        }

        return new_id;
    }

    /// Drain pending advance events (queued-track-started notifications).
    /// Caller takes ownership of the returned slice and must free with `allocator`.
    pub fn takeAdvanceEvents(self: *SoundRegistry, allocator: std.mem.Allocator) ![]AdvanceEvent {
        self.state_mutex.lockUncancelable(std.Options.debug_io);
        defer self.state_mutex.unlock(std.Options.debug_io);

        if (self.advance_events.items.len == 0) return &.{};
        const out = try allocator.dupe(AdvanceEvent, self.advance_events.items);
        self.advance_events.clearRetainingCapacity();
        return out;
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

const StreamSeekWorker = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    registry: ?*SoundRegistry = null,
    shutdown: bool = false,
    has_target: bool = false,
    is_seeking: bool = false,
    target_playback_id: u64 = 0,
    active_playback_id: u64 = 0,
    target_seconds: f32 = 0.0,
    settle_ms: i64 = 120,

    fn init(io: std.Io) StreamSeekWorker {
        return .{ .io = io };
    }

    fn deinit(self: *StreamSeekWorker, allocator: std.mem.Allocator) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        allocator.destroy(self);
    }

    fn submit(self: *StreamSeekWorker, registry: *SoundRegistry, playback_id: u64, seconds: f32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.registry = registry;
        self.target_playback_id = playback_id;
        self.target_seconds = @max(0.0, seconds);
        self.has_target = true;
        self.cond.signal(self.io);
    }

    fn status(self: *StreamSeekWorker) StreamSeekStatus {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_seeking) {
            return .{
                .active = true,
                .seeking = true,
                .playback_id = self.active_playback_id,
            };
        }

        return .{
            .active = self.has_target,
            .seeking = false,
            .playback_id = if (self.has_target) self.target_playback_id else null,
        };
    }

    fn run(self: *StreamSeekWorker) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.has_target and !self.shutdown) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }

            const pid = self.target_playback_id;
            const seconds = self.target_seconds;
            const settle_ms = self.settle_ms;
            self.mutex.unlock(self.io);

            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(settle_ms), .awake) catch {};

            self.mutex.lockUncancelable(self.io);
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }
            if (!self.has_target or self.target_playback_id != pid or self.target_seconds != seconds) {
                self.mutex.unlock(self.io);
                continue;
            }

            const registry = self.registry;
            self.has_target = false;
            self.is_seeking = true;
            self.active_playback_id = pid;
            self.mutex.unlock(self.io);

            if (registry) |r| {
                r.seekStreamSecondsImmediate(pid, seconds);
            }

            self.mutex.lockUncancelable(self.io);
            self.is_seeking = false;
            self.active_playback_id = 0;
            if (!self.has_target) self.registry = null;
            self.mutex.unlock(self.io);
        }
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
