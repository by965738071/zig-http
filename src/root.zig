const std = @import("std");

// Re-export main components
pub fn main(init: std.process.Init) !void {
    return @import("simple_main.zig").main(init);
}
