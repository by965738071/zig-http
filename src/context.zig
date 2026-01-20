const std = @import("std");
const http = std.http;

const Response = @import("response.zig").Response;
const ParamList = @import("types.zig").ParamList;
const HTTPServer = @import("http_server.zig").HTTPServer;

pub const Context = struct {
    server: *HTTPServer,
    request: *http.Server.Request,
    response: *Response,
    params: ParamList,
    state: std.StringHashMap(*anyopaque),

    pub fn init(allocator: std.mem.Allocator, server: *HTTPServer, request: *http.Server.Request, response: *Response) !Context {
        return .{
            .server = server,
            .request = request,
            .response = response,
            .params = ParamList.init(allocator),
            .state = std.StringHashMap(*anyopaque).init(allocator),
        };
    }

    pub fn deinit(ctx: *Context) void {
        ctx.params.deinit();
        ctx.state.deinit();
    }

    pub fn getParam(ctx: Context, name: []const u8) ?[]const u8 {
        return ctx.params.get(name);
    }

    pub fn getQuery(ctx: *Context, name: []const u8) ?[]const u8 {
        // Parse query string from request.target
        const target = ctx.request.head.target;
        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
        const query = target[query_start + 1 ..];

        var iter = std.mem.splitScalar(u8, query, '&');
        while (iter.next()) |pair| {
            const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, name)) {
                return value;
            }
        }
        return null;
    }

    pub fn getHeader(_: Context, _: []const u8) ?[]const u8 {
        // TODO: Need to access headers from request.head
        // The std.http.Server.Head structure doesn't expose headers directly
        // We need to parse them from the head_buffer or use a different approach
        return null;
    }

    pub fn setState(ctx: *Context, key: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        const ptr = try ctx.server.allocator.create(T);
        ptr.* = value;
        try ctx.state.put(key, @ptrCast(ptr));
    }

    pub fn getState(ctx: Context, key: []const u8) ?*anyopaque {
        return ctx.state.get(key);
    }

    pub fn json(ctx: *Context, value: anytype) !void {
        try ctx.response.writeJSON(value);
    }

    pub fn html(ctx: *Context, content: []const u8) !void {
        try ctx.response.setHeader("Content-Type", "text/html; charset=utf-8");
        try ctx.response.write(content);
    }

    pub fn text(ctx: *Context, content: []const u8) !void {
        try ctx.response.setHeader("Content-Type", "text/plain; charset=utf-8");
        try ctx.response.write(content);
    }

    pub fn setStatus(ctx: *Context, status_code: http.Status) void {
        ctx.response.setStatus(status_code);
    }

    pub fn err(ctx: *Context, status_code: http.Status, message: []const u8) !void {
        ctx.setStatus(status_code);
        try ctx.json(.{ .error_val = message });
    }
};
