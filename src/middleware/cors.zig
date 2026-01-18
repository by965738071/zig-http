const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;

pub const CORSMiddleware = struct {
    middleware: Middleware,
    allowed_origins: []const []const u8,
    allow_credentials: bool,
    allowed_methods: []const []const u8,
    allowed_headers: []const []const u8,

    pub const Options = struct {
        allowed_origins: []const []const u8 = &.{},
        allow_credentials: bool = false,
        allowed_methods: []const []const u8 = &.{ "GET", "POST", "PUT", "DELETE", "OPTIONS" },
        allowed_headers: []const []const u8 = &.{ "Content-Type", "Authorization" },
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !*CORSMiddleware {
        const self = try allocator.create(CORSMiddleware);
        self.* = .{
            .middleware = Middleware.init(CORSMiddleware, self),
            .allowed_origins = try allocator.dupe([]const u8, options.allowed_origins),
            .allow_credentials = options.allow_credentials,
            .allowed_methods = try allocator.dupe([]const u8, options.allowed_methods),
            .allowed_headers = try allocator.dupe([]const u8, options.allowed_headers),
        };
        return self;
    }

    pub fn process(self: *CORSMiddleware, ctx: *Context) !Middleware.NextAction {
        // Handle OPTIONS preflight request
        if (ctx.request.head.method == .OPTIONS) {
            try self.setCORSHeaders(ctx);
            ctx.response.status = .no_content;
            return Middleware.NextAction.respond;
        }

        try self.setCORSHeaders(ctx);
        return Middleware.NextAction.@"continue";
    }

    fn setCORSHeaders(self: *CORSMiddleware, ctx: *Context) !void {
        const origin = ctx.getHeader("Origin") orelse "*";
        var cors_origin: []const u8 = "*";

        if (self.allowed_origins.len > 0) {
            for (self.allowed_origins) |allowed| {
                if (std.mem.eql(u8, allowed, origin) or std.mem.eql(u8, allowed, "*")) {
                    cors_origin = origin;
                    break;
                }
            }
        }

        try ctx.response.setHeader("Access-Control-Allow-Origin", cors_origin);

        if (self.allow_credentials) {
            try ctx.response.setHeader("Access-Control-Allow-Credentials", "true");
        }

        if (self.allowed_methods.len > 0) {
            const methods_str = try std.mem.join(ctx.server.allocator, ", ", self.allowed_methods);
            defer ctx.server.allocator.free(methods_str);
            try ctx.response.setHeader("Access-Control-Allow-Methods", methods_str);
        }

        if (self.allowed_headers.len > 0) {
            const headers_str = try std.mem.join(ctx.server.allocator, ", ", self.allowed_headers);
            defer ctx.server.allocator.free(headers_str);
            try ctx.response.setHeader("Access-Control-Allow-Headers", headers_str);
        }
    }

    pub fn deinit(self: *CORSMiddleware) void {
        _ = self;
        // Note: We don't free the slices here as they may be owned by the allocator
    }
};
