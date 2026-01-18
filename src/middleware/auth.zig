const std = @import("std");
const http = std.http;
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;

pub const AuthMiddleware = struct {
    middleware: Middleware,
    secret: []const u8,

    pub fn init(allocator: std.mem.Allocator, secret: []const u8) !*AuthMiddleware {
        const self = try allocator.create(AuthMiddleware);
        self.* = .{
            .middleware = Middleware.init(AuthMiddleware, self),
            .secret = try allocator.dupe(u8, secret),
        };
        return self;
    }

    pub fn process(self: *AuthMiddleware, ctx: *Context) !Middleware.NextAction {
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
        _ = self;
        // Note: We don't free secret here as it may be owned by the allocator
    }
};
