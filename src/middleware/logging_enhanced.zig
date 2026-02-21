const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;
const Io = std.Io;

/// Structured logging middleware configuration
pub const LoggingConfig = struct {
    log_level: LogLevel = .info,
    log_format: LogFormat = .text,
    include_headers: bool = false,
    include_body: bool = false,
    slow_request_threshold_ns: u64 = 100_000_000, // 100ms
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    error,
};

pub const LogFormat = enum {
    text,
    json,
};

/// Structured logging middleware for request/response logging
pub const LoggingMiddleware = struct {
    config: LoggingConfig,

    pub fn init(config: LoggingConfig) LoggingMiddleware {
        return .{ .config = config };
    }

    pub fn process(self: *LoggingMiddleware, ctx: *Context, io: std.Io) !Middleware.NextAction {
        const start_time = std.time.nanoTimestamp();

        defer {
            const elapsed_ns = std.time.nanoTimestamp() - start_time;
            self.logRequest(ctx, elapsed_ns);

            // Log slow requests as warnings
            if (elapsed_ns > self.config.slow_request_threshold_ns) {
                self.logSlowRequest(ctx, elapsed_ns);
            }
        }

        return .@"continue";
    }

    fn logRequest(self: *LoggingMiddleware, ctx: *Context, elapsed_ns: i64) !void {
        const elapsed_us = @divTrunc(elapsed_ns, 1000);

        switch (self.config.log_format) {
            .text => {
                self.logText(ctx, elapsed_us);
            },
            .json => {
                self.logJson(ctx, elapsed_ns);
            },
        }
    }

    fn logText(self: *LoggingMiddleware, ctx: *Context, elapsed_us: i64) void {
        const level = self.getLogLevel();
        const log_fn = switch (level) {
            .debug => std.log.debug,
            .info => std.log.info,
            .warn => std.log.warn,
            .error => std.log.err,
        };

        log_fn("{s} {s} - {d}μs - {d} - {s}", .{
            ctx.method,
            ctx.path,
            elapsed_us,
            ctx.response.status,
            ctx.getRequestId(),
        });

        if (self.config.include_headers) {
            const headers = ctx.getAllHeaders();
            var it = headers.iterator();
            while (it.next()) |entry| {
                log_fn("  Header: {s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
    }

    fn logJson(self: *LoggingMiddleware, ctx: *Context, elapsed_ns: i64) !void {
        var buffer = std.ArrayList(u8).init(ctx.allocator);
        defer buffer.deinit();

        try buffer.writer().print(
            \\{{
            \\  "timestamp":{d},
            \\  "level":"{s}",
            \\  "method":"{s}",
            \\  "path":"{s}",
            \\  "status":{d},
            \\  "duration_ns":{d},
            \\  "request_id":"{s}",
            \\  "ip":"{s}"
        ,
            .{
                std.time.timestamp(),
                @tagName(self.config.log_level),
                ctx.method,
                ctx.path,
                ctx.response.status,
                elapsed_ns,
                ctx.getRequestId(),
                ctx.ip_address orelse "unknown",
            },
        );

        if (self.config.include_headers) {
            try buffer.appendSlice(",\n  \"headers\":{");
            const headers = ctx.getAllHeaders();
            var it = headers.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buffer.appendSlice(",");
                first = false;
                try buffer.writer().print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try buffer.appendSlice("}");
        }

        try buffer.appendSlice("\n}\n");

        std.log.info("{s}", .{buffer.items});
    }

    fn logSlowRequest(self: *LoggingMiddleware, ctx: *Context, elapsed_ns: i64) void {
        const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
        std.log.warn("Slow request: {s} {s} - {d}ms - {s}", .{
            ctx.method,
            ctx.path,
            elapsed_ms,
            ctx.getRequestId(),
        });
    }

    fn getLogLevel(self: *LoggingMiddleware) LogLevel {
        return self.config.log_level;
    }
};
