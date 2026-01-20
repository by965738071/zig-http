const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;

pub const XSSMiddleware = struct {
    middleware: Middleware,
    allocator: std.mem.Allocator,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) !*XSSMiddleware {
        const self = try allocator.create(XSSMiddleware);
        self.* = .{
            .middleware = Middleware.init(XSSMiddleware),
            .allocator = allocator,
            .enabled = enabled,
        };
        return self;
    }

    pub fn process(self: *XSSMiddleware, ctx: *Context) !Middleware.NextAction {
        if (!self.enabled) {
            return Middleware.NextAction.@"continue";
        }

        // Set security headers
        try ctx.response.setHeader("X-Content-Type-Options", "nosniff");
        try ctx.response.setHeader("X-Frame-Options", "DENY");
        try ctx.response.setHeader("X-XSS-Protection", "1; mode=block");

        // Set Content-Security-Policy
        const csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; object-src 'none'; frame-ancestors 'none';";
        try ctx.response.setHeader("Content-Security-Policy", csp);

        return Middleware.NextAction.@"continue";
    }

    pub fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        // HTML5 entity encoding
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        for (input) |char| {
            switch (char) {
                '&' => try result.appendSlice(allocator, "&amp;"),
                '<' => try result.appendSlice(allocator, "&lt;"),
                '>' => try result.appendSlice(allocator, "&gt;"),
                '"' => try result.appendSlice(allocator, "&quot;"),
                '\'' => try result.appendSlice(allocator, "&#x27;"),
                '/' => try result.appendSlice(allocator, "&#x2F;"),
                else => try result.append(allocator, char),
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn escapeJs(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        for (input) |char| {
            switch (char) {
                '\\' => try result.appendSlice(allocator, "\\\\"),
                '"' => try result.appendSlice(allocator, "\\\""),
                '\'' => try result.appendSlice(allocator, "\\'"),
                '\n' => try result.appendSlice(allocator, "\\n"),
                '\r' => try result.appendSlice(allocator, "\\r"),
                '\t' => try result.appendSlice(allocator, "\\t"),
                0x00,
                0x01,
                0x02,
                0x03,
                0x04,
                0x05,
                0x06,
                0x07,
                0x08,
                0x0B,
                0x0C,
                0x0E,
                0x0F,
                => try result.print("\\x{X:0>2}", .{char}),

                else => try result.append(allocator, char),
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn sanitizeUrl(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        // Remove javascript: and data: protocols from URLs
        const lower_input = try allocator.dupe(u8, input);
        defer allocator.free(lower_input);

        for (lower_input, 0..) |_, i| {
            lower_input[i] = std.ascii.toLower(input[i]);
        }

        const dangerous_protocols = [_][]const u8{ "javascript:", "data:", "vbscript:" };
        for (dangerous_protocols) |proto| {
            if (std.mem.startsWith(u8, lower_input, proto)) {
                return allocator.dupe(u8, "#");
            }
        }

        return allocator.dupe(u8, input);
    }

    pub fn deinit(self: *XSSMiddleware) void {
        _ = self;
    }
};
