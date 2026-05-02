const std = @import("std");

pub const ShelfAllocator = struct {
    width: u32,
    height: u32,
    current_x: u32,
    current_y: u32,
    max_row_height: u32,

    pub fn init(width: u32, height: u32) ShelfAllocator {
        return .{
            .width = width,
            .height = height,
            .current_x = 0,
            .current_y = 0,
            .max_row_height = 0,
        };
    }

    pub fn allocate(self: *ShelfAllocator, w: u32, h: u32) ?[2]u32 {
        if (self.current_x + w > self.width) {
            self.current_x = 0;
            self.current_y += self.max_row_height;
            self.max_row_height = 0;
        }

        if (self.current_y + h > self.height) {
            return null; // Atlas overflow
        }

        const pos = [2]u32{ self.current_x, self.current_y };
        self.current_x += w;

        if (h > self.max_row_height) {
            self.max_row_height = h;
        }

        return pos;
    }
};
