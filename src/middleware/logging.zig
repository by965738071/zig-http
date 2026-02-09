const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;

pub const LoggingMiddleware = struct {
    middleware: Middleware,

    pub fn init(allocator: std.mem.Allocator) !*LoggingMiddleware {
        const self = try allocator.create(LoggingMiddleware);
        self.* = .{
            .middleware = Middleware.init(LoggingMiddleware),
        };
        return self;
    }

    pub fn process(self: *LoggingMiddleware, ctx: *Context, io: std.Io) !Middleware.NextAction {
        _ = self;
        const start = std.Io.Timestamp.now(io, .boot);
        defer {
            const duration = start.untilNow(io, .boot);

            std.log.info("{s} {s} - {d}μs", .{
                @tagName(ctx.request.head.method),
                ctx.request.head.target,
                duration.toNanoseconds(),
            });
        }
        return Middleware.NextAction.@"continue";
    }

    pub fn deinit(self: *LoggingMiddleware) void {
        _ = self;
    }
};
