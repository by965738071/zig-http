const std = @import("std");
const http = std.http;

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: http.Status = .ok,
    headers: std.ArrayList(http.Header),
    body: std.ArrayList(u8),
    writer: ?*std.Io.Writer = null,

    pub fn init(allocator: std.mem.Allocator) !Response {
        return .{
            .allocator = allocator,
            .headers = std.ArrayList(http.Header){},
            .body = std.ArrayList(u8){},
            .writer = null,
        };
    }

    pub fn deinit(res: *Response) void {
        res.headers.deinit(res.allocator);
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

    pub fn writeJSON(res: *Response, value: anytype) !void {
        // API 已正确: 使用 std.json.Stringify
        const json_string = try std.json.Stringify.valueAlloc(res.allocator, value, .{ .emit_null_optional_fields = false });

        defer res.allocator.free(json_string);

        try res.setHeader("Content-Type", "application/json");
        try res.write(json_string);
    }

    pub fn setStatus(res: *Response, status: http.Status) void {
        res.status = status;
    }

    pub fn setHeader(res: *Response, name: []const u8, value: []const u8) !void {
        // 修复: append 不再需要 allocator 参数
        try res.headers.append(
            res.allocator,
            .{ .name = name, .value = value },
        );
    }

    pub fn addHeader(res: *Response, name: []const u8, value: []const u8) !void {
        try res.setHeader(name, value);
    }

    pub fn writeAll(res: *Response, data: []const u8) !void {
        try res.write(data);
    }

    pub fn flush(res: *Response) !void {
        if (res.writer) |w| {
            try w.flush();
        }
    }

    pub fn clearRetainingCapacity(res: *Response) void {
        res.body.clearRetainingCapacity();
    }

    pub fn appendSlice(res: *Response, data: []const u8) !void {
        try res.body.appendSlice(res.allocator, data);
    }

    pub fn getHeader(res: *Response, name: []const u8) ?[]const u8 {
        for (res.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }

    pub fn toHttpResponse(res: *Response, writer: anytype, request: *http.Server.Request) !void {
        // 手动构建 HTTP 响应
        const w = &writer.interface;

        // 状态行
        const status_code = @intFromEnum(res.status);
        const phrase = res.status.phrase() orelse "Unknown";
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ status_code, phrase });

        // Content-Length header
        try w.print("Content-Length: {d}\r\n", .{res.body.items.len});

        // Connection header
        try w.print("connection: {s}\r\n", .{if (request.head.keep_alive) "keep-alive" else "close"});

        // 自定义 headers
        for (res.headers.items) |header| {
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        // 空行分隔
        try w.writeAll("\r\n");

        // Body
        if (res.body.items.len > 0) {
            try w.writeAll(res.body.items);
        }

        // 确保数据刷新到网络
        try w.flush();
    }
};
