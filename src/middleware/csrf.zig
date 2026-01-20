const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;
const http = std.http;

pub const CSRFMiddleware = struct {
    middleware: Middleware,
    allocator: std.mem.Allocator,
    secret: []const u8,
    token_lifetime_sec: u64,
    cookie_name: []const u8,
    header_name: []const u8,
    enabled: bool,

    const TokenData = struct {
        value: []const u8,
        expiry: u64,
    };

    pub const Options = struct {
        secret: []const u8,
        token_lifetime_sec: u64 = 3600, // 1 hour
        cookie_name: []const u8 = "csrf_token",
        header_name: []const u8 = "X-CSRF-Token",
        enabled: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !*CSRFMiddleware {
        const self = try allocator.create(CSRFMiddleware);
        self.* = .{
            .middleware = Middleware.init(CSRFMiddleware),
            .allocator = allocator,
            .secret = try allocator.dupe(u8, options.secret),
            .token_lifetime_sec = options.token_lifetime_sec,
            .cookie_name = try allocator.dupe(u8, options.cookie_name),
            .header_name = try allocator.dupe(u8, options.header_name),
            .enabled = options.enabled,
        };
        return self;
    }

    pub fn process(self: *CSRFMiddleware, ctx: *Context) !Middleware.NextAction {
        if (!self.enabled) {
            return Middleware.NextAction.@"continue";
        }

        const method = ctx.request.head.method;

        // Skip CSRF for safe methods (GET, HEAD, OPTIONS, TRACE)
        switch (method) {
            .GET, .HEAD, .OPTIONS, .TRACE => {
                // Generate and set CSRF token for safe methods
                try self.setToken(ctx);
                return Middleware.NextAction.@"continue";
            },
            else => {
                // Verify CSRF token for unsafe methods (POST, PUT, DELETE, etc.)
                return self.verifyToken(ctx);
            },
        }
    }

    fn setToken(self: *CSRFMiddleware, ctx: *Context) !void {
        // Generate random token
        const token = try self.generateToken();
        defer self.allocator.free(token);

        // Set cookie
        try ctx.response.setHeader("Set-Cookie", try self.formatCookie(token));

        // Store token in context for templates
        try ctx.setState("csrf_token", token);
    }

    fn verifyToken(self: *CSRFMiddleware, ctx: *Context) !Middleware.NextAction {
        // Get token from header
        const header_token = ctx.getHeader(self.header_name) orelse {
            try ctx.err(http.Status.forbidden, "CSRF token missing");
            return Middleware.NextAction.respond;
        };

        // Get token from cookie (simplified - in real implementation parse cookies properly)
        // For now, we'll assume a simple format in the Cookie header
        const cookie_header = ctx.getHeader("Cookie") orelse {
            try ctx.err(http.Status.forbidden, "CSRF cookie missing");
            return Middleware.NextAction.respond;
        };

        const cookie_token = self.extractCookie(cookie_header, self.cookie_name) orelse {
            try ctx.err(http.Status.forbidden, "CSRF cookie missing");
            return Middleware.NextAction.respond;
        };

        // Compare tokens (use constant-time comparison in production)
        if (!std.mem.eql(u8, header_token, cookie_token)) {
            try ctx.err(http.Status.forbidden, "Invalid CSRF token");
            return Middleware.NextAction.respond;
        }

        return Middleware.NextAction.@"continue";
    }

    fn generateToken(self: *CSRFMiddleware) ![]const u8 {
        var random_buf: [32]u8 = undefined;
        var xoshiro = std.Random.Xoshiro256.init(1024);
        xoshiro.fill(&random_buf);
        //std.crypto.random.bytes(&random_buf);

        const token = try self.allocator.alloc(u8, 64);
        var i: usize = 0;
        for (random_buf) |byte| {
            const hex = "0123456789abcdef";
            token[i] = hex[byte >> 4];
            token[i + 1] = hex[byte & 0xF];
            i += 2;
        }

        return token;
    }

    fn formatCookie(self: *CSRFMiddleware, token: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}={s}; Path=/; HttpOnly; SameSite=Strict", .{
            self.cookie_name,
            token,
        });
    }

    fn extractCookie(self: *CSRFMiddleware, cookie_header: []const u8, name: []const u8) ?[]const u8 {
        _ = self;
        var iter = std.mem.splitScalar(u8, cookie_header, ';');

        while (iter.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " ");
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;

            const cookie_name = trimmed[0..eq_pos];
            const cookie_value = trimmed[eq_pos + 1 ..];

            if (std.mem.eql(u8, cookie_name, name)) {
                return cookie_value;
            }
        }

        return null;
    }

    pub fn getToken(ctx: *Context) ?[]const u8 {
        if (ctx.getState("csrf_token")) |ptr| {
            return @as(*[]const u8, @ptrCast(@alignCast(ptr))).*;
        }
        return null;
    }

    pub fn deinit(self: *CSRFMiddleware) void {
        self.allocator.free(self.secret);
        self.allocator.free(self.cookie_name);
        self.allocator.free(self.header_name);
    }
};
