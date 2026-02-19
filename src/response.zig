const std = @import("std");
const http = std.http;

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: http.Status = .ok,
    headers: std.StringHashMap([]const u8),
    body: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !Response {
        return .{
            .allocator = allocator,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = std.ArrayList(u8){},
        };
    }

    pub fn deinit(res: *Response) void {
        var it = res.headers.iterator();
        while (it.next()) |entry| {
            res.allocator.free(entry.key_ptr.*);
            res.allocator.free(entry.value_ptr.*);
        }
        res.headers.deinit();
        res.body.deinit(res.allocator);
    }

    pub fn reset(res: *Response) void {
        res.status = .ok;
        var it = res.headers.iterator();
        while (it.next()) |entry| {
            res.allocator.free(entry.key_ptr.*);
            res.allocator.free(entry.value_ptr.*);
        }
        res.headers.clearRetainingCapacity();
        res.body.clearRetainingCapacity();
    }

    pub fn write(res: *Response, data: []const u8) !void {
        try res.body.appendSlice(res.allocator, data);
    }

    pub fn writeJSON(res: *Response, _: anytype) !void {
        try res.setHeader("Content-Type", "application/json; charset=utf-8");
        try res.write("{}");
    }

    pub fn setStatus(res: *Response, status: http.Status) void {
        res.status = status;
    }

    pub fn setHeader(res: *Response, name: []const u8, value: []const u8) !void {
        const name_copy = try res.allocator.dupe(u8, name);
        errdefer res.allocator.free(name_copy);
        const value_copy = try res.allocator.dupe(u8, value);
        errdefer res.allocator.free(value_copy);

        if (res.headers.getPtr(name_copy)) |existing| {
            res.allocator.free(existing.*);
            existing.* = value_copy;
            res.allocator.free(name_copy);
        } else {
            try res.headers.put(name_copy, value_copy);
        }
    }

    pub fn addHeader(res: *Response, name: []const u8, value: []const u8) !void {
        try res.setHeader(name, value);
    }

    pub fn writeAll(res: *Response, data: []const u8) !void {
        try res.write(data);
    }

    pub fn appendSlice(res: *Response, data: []const u8) !void {
        try res.body.appendSlice(res.allocator, data);
    }

    pub fn getHeader(res: *Response, name: []const u8) ?[]const u8 {
        var it = res.headers.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    pub fn hasHeader(res: *Response, name: []const u8) bool {
        return res.getHeader(name) != null;
    }

    pub fn toHttpResponse(res: *Response, writer: anytype, request: *http.Server.Request) !void {
        const w = &writer.interface;

        const status_code = @intFromEnum(res.status);
        const phrase = res.status.phrase() orelse "Unknown";
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ status_code, phrase });

        try w.print("Content-Length: {d}\r\n", .{res.body.items.len});
        try w.print("Connection: {s}\r\n", .{if (request.head.keep_alive) "keep-alive" else "close"});
        try w.writeAll("Server: Zig-HTTP/0.16\r\n");

        var it = res.headers.iterator();
        while (it.next()) |entry| {
            try w.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try w.writeAll("\r\n");

        if (res.body.items.len > 0) {
            try w.writeAll(res.body.items);
        }

        try w.flush();
    }
};
