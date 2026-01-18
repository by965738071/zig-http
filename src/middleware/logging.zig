const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;

pub const LoggingMiddleware = struct {
    middleware: Middleware,

    pub fn init(allocator: std.mem.Allocator) !*LoggingMiddleware {
        const self = try allocator.create(LoggingMiddleware);
        self.* = .{
            .middleware = Middleware.init(LoggingMiddleware, self),
        };
        return self;
    }

    pub fn process(self: *LoggingMiddleware, ctx: *Context) !Middleware.NextAction {
        _ = self;
        const start = std.time.Instant.now() catch unreachable;
        defer {
            const elapsed = start.elapsed() catch unreachable;
            std.log.info("{s} {s} - {d}μs", .{
                @tagName(ctx.request.head.method),
                ctx.request.head.target,
                elapsed / 1000,
            });
        }
        return Middleware.NextAction.@"continue";
    }

    pub fn deinit(self: *LoggingMiddleware) void {
        _ = self;
    }
};
