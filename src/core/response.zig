const std = @import("std");
const http = std.http;
//const StringInterner = @import("../utils/zero_copy.zig").StringInterner;

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: http.Status = .ok,
    headers: std.StringHashMap([]const u8),
    body: std.ArrayList(u8),
    string_interner: *std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, string_interner: *std.StringHashMap([]const u8)) !Response {
        return .{
            .allocator = allocator,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = std.ArrayList(u8){},
            .string_interner = string_interner,
        };
    }

    pub fn deinit(res: *Response) void {
        // Note: Headers keys/values are interned, not owned by Response
        // Do NOT free them here - they are managed by StringInterner
        res.headers.deinit();
        res.body.deinit(res.allocator);
    }

    pub fn reset(res: *Response) void {
        res.status = .ok;
        res.headers.clearRetainingCapacity();
        res.body.clearRetainingCapacity();
    }

    pub fn write(res: *Response, data: []const u8) !void {
        try res.body.appendSlice(res.allocator, data);
    }

    pub fn writeJSON(res: *Response, data: anytype) !void {
        try res.setHeader("Content-Type", "application/json; charset=utf-8");

        // Use std.json.Stringify.valueAlloc to serialize the data
        const json_str = try std.json.Stringify.valueAlloc(res.allocator, data, .{});
        defer res.allocator.free(json_str);

        // Write the JSON to the response body
        try res.write(json_str);
    }

    pub fn setStatus(res: *Response, status: http.Status) void {
        res.status = status;
    }

    pub fn setHeader(res: *Response, name: []const u8, value: []const u8) !void {
        // Use StringInterner to avoid duplicate allocations
        const name_interned = res.string_interner.get(name) orelse return error.InvalidHeaderName;
        const value_interned = res.string_interner.get(value) orelse return error.InvalidHeaderValue;

        if (res.headers.getPtr(name_interned)) |existing| {
            existing.* = value_interned;
        } else {
            try res.headers.put(name_interned, value_interned);
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

    pub fn toHttpResponse(res: *Response, writer: *std.Io.Writer, request: *http.Server.Request) !void {
        const status_code = @intFromEnum(res.status);
        const phrase = res.status.phrase() orelse "Unknown";
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ status_code, phrase });

        try writer.print("Content-Length: {d}\r\n", .{res.body.items.len});
        try writer.print("Connection: {s}\r\n", .{if (request.head.keep_alive) "keep-alive" else "close"});
        try writer.writeAll("Server: Zig-HTTP/0.16\r\n");

        var it = res.headers.iterator();
        while (it.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try writer.writeAll("\r\n");

        if (res.body.items.len > 0) {
            try writer.writeAll(res.body.items);
        }

        try writer.flush();
    }
};
