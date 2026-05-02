const c = @import("c.zig");
const std = @import("std");

pub const SoundResource = struct {
    sound: c.ma_sound,

    pub fn initFromFile(engine: *c.ma_engine, path: [:0]const u8) !SoundResource {
        var self: SoundResource = undefined;
        const flags = c.MA_SOUND_FLAG_DECODE;

        if (c.ma_sound_init_from_file(engine, path.ptr, flags, null, null, &self.sound) != c.MA_SUCCESS) {
            return error.SoundLoadFailed;
        }
        return self;
    }

    pub fn deinit(self: *SoundResource) void {
        c.ma_sound_uninit(&self.sound);
    }
};
