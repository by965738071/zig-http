const std = @import("std");
const http = std.http;
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;

pub const AuthMiddleware = struct {
    middleware: Middleware,
    allocator: std.mem.Allocator,
    secret: []const u8,
    whitelist: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, secret: []const u8) !*AuthMiddleware {
        const self = try allocator.create(AuthMiddleware);
        self.* = .{
            .middleware = Middleware.init(AuthMiddleware),
            .allocator = allocator,
            .secret = try allocator.dupe(u8, secret),
            .whitelist = std.ArrayList([]const u8){},
        };
        return self;
    }

    pub fn skipPath(self: *AuthMiddleware, path: []const u8) !void {
        try self.whitelist.append(self.allocator,try self.allocator.dupe(u8, path));
    }

    pub fn process(self: *AuthMiddleware, ctx: *Context) !Middleware.NextAction {
        // Check whitelist
        for (self.whitelist.items) |path| {
            if (std.mem.startsWith(u8, ctx.request.head.target, path)) {
                return Middleware.NextAction.@"continue";
            }
        }

        const auth_header = ctx.getHeader("Authorization") orelse {
            try ctx.err(http.Status.unauthorized, "Missing Authorization header");
            return Middleware.NextAction.respond;
        };

        // Simple Bearer token validation (simplified for demo)
        if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
            try ctx.err(http.Status.unauthorized, "Invalid Authorization format");
            return Middleware.NextAction.respond;
        }

        const token = auth_header["Bearer ".len..];

        // Simple validation - in production use proper JWT or session validation
        if (std.mem.eql(u8, token, self.secret)) {
            return Middleware.NextAction.@"continue";
        }

        try ctx.err(http.Status.unauthorized, "Invalid token");
        return Middleware.NextAction.respond;
    }

    pub fn deinit(self: *AuthMiddleware) void {
        self.allocator.free(self.secret);
        for (self.whitelist.items) |path| {
            self.allocator.free(path);
        }
        self.whitelist.deinit(self.allocator);
    }
};
