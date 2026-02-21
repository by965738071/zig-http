const std = @import("std");

pub const Handler = *const fn (ctx: *Context) anyerror!void;

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_connections: usize = 1000,
    request_timeout: u64 = 30_000, // 30s
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 4096,
    max_request_body_size: usize = 10 * 1024 * 1024, // 10MB
    max_header_size: usize = 8192, // 8KB
    connection_timeout: u64 = 60_000, // 60s connection timeout
};

pub const Method = std.http.Method;
pub const Status = std.http.Status;

pub const ParamList = struct {
    data: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ParamList {
        return .{
            .data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(list: *ParamList) void {
        list.data.deinit();
    }

    pub fn get(list: ParamList, name: []const u8) ?[]const u8 {
        return list.data.get(name);
    }

    pub fn put(list: *ParamList, name: []const u8, value: []const u8) !void {
        try list.data.put(name, value);
    }
};

// Context is defined in context.zig to avoid circular dependency
const Context = @import("context.zig").Context;
