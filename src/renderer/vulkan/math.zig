const std = @import("std");

pub const Mat4 = extern struct {
    data: [16]f32,

    pub fn identity() Mat4 {
        var m = std.mem.zeroes(Mat4);
        m.data[0] = 1.0;
        m.data[5] = 1.0;
        m.data[10] = 1.0;
        m.data[15] = 1.0;
        return m;
    }

    pub fn ortho(left: f32, right: f32, top: f32, bottom: f32) Mat4 {
        var m = identity();
        m.data[0] = 2.0 / (right - left);
        m.data[5] = 2.0 / (bottom - top);
        m.data[10] = 1.0;

        m.data[12] = -(right + left) / (right - left);
        m.data[13] = -(bottom + top) / (bottom - top);
        m.data[14] = 0.0;

        return m;
    }
};
