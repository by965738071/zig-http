const std = @import("std");
const Context = @import("context.zig").Context;

/// Structured logging configuration
pub const LogConfig = struct {
    output_format: OutputFormat = .json,
    log_level: LogLevel = .info,
    include_request_id: bool = true,
    include_ip_address: bool = true,
    include_user_agent: bool = false,
    include_headers: bool = false,
    slow_request_threshold_ns: u64 = 100_000_000, // 100ms
};

pub const OutputFormat = enum {
    text,
    json,
};

pub const LogLevel = enum { debug, info, warn, err };

/// Structured logger for HTTP requests
pub const StructuredLogger = struct {
    io:std.Io,
    config: LogConfig,

    pub fn init(config: LogConfig,io:std.Io) StructuredLogger {
        return .{ .config = config,.io = io };
    }

    /// Log an HTTP request with timing
    pub fn logRequest(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) !void {
        const log_entry = try logger.buildLogEntry(ctx, duration_ns);
        defer ctx.allocator.free(log_entry);

        const level = logger.determineLogLevel(ctx, duration_ns);

        if (level == .debug) {
            std.log.debug("{s}", .{log_entry});
        } else if (level == .info) {
            std.log.info("{s}", .{log_entry});
        } else if (level == .warn) {
            std.log.warn("{s}", .{log_entry});
        } else if (level == .err) {
            std.log.err("{s}", .{log_entry});
        }
    }

    /// Log slow request
    pub fn logSlowRequest(logger: *const StructuredLogger, ctx: *Context, duration_ns: i64) void {
        _ = logger; // Not used, kept for API consistency
        const duration_ms = @divTrunc(duration_ns, 1_000_000);
        std.log.warn("Slow request: {s} {s} - {d}ms - {s}", .{
            @tagName(ctx.request.head.method),
            ctx.request.head.target,
            duration_ms,
            ctx.getRequestId(),
        });
    }

    /// Build log entry based on format
    fn buildLogEntry(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) ![]const u8 {
        return switch (logger.config.output_format) {
            .text => try logger.buildTextLog(ctx, duration_ns),
            .json => try logger.buildJsonLog(ctx, duration_ns),
        };
    }

    fn buildTextLog(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) ![]const u8 {
        var buffer = std.ArrayList(u8){};
        const duration_us = @divTrunc(duration_ns, 1000);

        try buffer.print(ctx.allocator, "{s} {s} - {d}μs - {d}", .{
            @tagName(ctx.request.head.method),
            ctx.request.head.target,
            duration_us,
            ctx.response.status,
        });

        if (logger.config.include_request_id) {
            try buffer.print(ctx.allocator, " - {s}", .{ctx.getRequestId() orelse "unknown"});
        }

        if (logger.config.include_ip_address) {
            const ip = ctx.getHeader("X-Forwarded-For") orelse
                ctx.getHeader("X-Real-IP") orelse "unknown";
            try buffer.print(ctx.allocator, " - {s}", .{ip});
        }

        if (logger.config.include_user_agent) {
            const ua = ctx.getHeader("User-Agent") orelse "-";
            try buffer.print(ctx.allocator, " - \"{s}\"", .{ua});
        }

        return buffer.toOwnedSlice(ctx.allocator);
    }

    fn buildJsonLog(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) ![]const u8 {
        var buffer = std.ArrayList(u8){};

        try buffer.appendSlice(ctx.allocator, "{");
        
        try buffer.print(ctx.allocator, "\"timestamp\":{d},", .{std.Io.Timestamp.now(logger.io, .boot).toMilliseconds()});
        try buffer.print(ctx.allocator, "\"level\":\"{s}\",", .{@tagName(logger.config.log_level)});
        try buffer.print(ctx.allocator, "\"method\":\"{s}\",", .{@tagName(ctx.request.head.method)});
        try buffer.print(ctx.allocator, "\"path\":\"{s}\",", .{ctx.request.head.target});
        try buffer.print(ctx.allocator, "\"status\":{d},", .{ctx.response.status});
        try buffer.print(ctx.allocator, "\"duration_ns\":{d},", .{duration_ns});

        if (logger.config.include_request_id) {
            try buffer.print(ctx.allocator, "\"request_id\":\"{s}\",", .{ctx.getRequestId() orelse "unknown"});
        }

        if (logger.config.include_ip_address) {
            const ip = ctx.getHeader("X-Forwarded-For") orelse
                ctx.getHeader("X-Real-IP") orelse "unknown";
            try buffer.print(ctx.allocator, "\"ip\":\"{s}\",", .{ip});
        }

        if (logger.config.include_user_agent) {
            const ua = ctx.getHeader("User-Agent") orelse "-";
            const escaped_ua = escapeJsonString(ua);
            try buffer.print(ctx.allocator, "\"user_agent\":\"{s}\",", .{escaped_ua});
        }

        if (logger.config.include_headers) {
            try buffer.appendSlice(ctx.allocator, "\"headers\":{");
            var allHeaders = try ctx.getAllHeaders();
            var it = allHeaders.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buffer.appendSlice(ctx.allocator, ",");
                first = false;
                try buffer.print(ctx.allocator, "\"{s}\":\"{s}\"", .{
                    entry.key_ptr.*,
                    escapeJsonString(entry.value_ptr.*),
                });
            }
            allHeaders.deinit();
            try buffer.appendSlice(ctx.allocator, "},");
        }

        try buffer.appendSlice(ctx.allocator, "}\n");
        return buffer.toOwnedSlice(ctx.allocator);
    }

    fn determineLogLevel(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) LogLevel {
        if (duration_ns > logger.config.slow_request_threshold_ns) {
            return .warn;
        }

        const status = @intFromEnum(ctx.response.status);
        if (status >= 500) {
            return .err;
        } else if (status >= 400) {
            return .warn;
        }

        return logger.config.log_level;
    }

    fn escapeJsonString(s: []const u8) []const u8 {
        // Simple escape - in production, use proper JSON escaping
        _ = s;
        return "[escaped]";
    }
};

/// Error logger for structured error logging
pub const ErrorLogger = struct {
    config: LogConfig,

    pub fn init(config: LogConfig) ErrorLogger {
        return .{ .config = config };
    }

    pub fn logError(logger: *ErrorLogger, ctx: *Context, err: anyerror) !void {
        _ = logger;
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(ctx.allocator);

        try buffer.print(ctx.allocator, "{{", .{});
        try buffer.print(ctx.allocator, "\"timestamp\":{d},", .{std.time.milliTimestamp()});
        try buffer.print(ctx.allocator, "\"level\":\"error\",", .{});
        try buffer.print(ctx.allocator, "\"error\":\"{s}\",", .{@errorName(err)});
        try buffer.print(ctx.allocator, "\"request_id\":\"{s}\",", .{ctx.getRequestId() orelse "unknown"});
        try buffer.print(ctx.allocator, "\"method\":\"{s}\",", .{@tagName(ctx.request.head.method)});
        try buffer.print(ctx.allocator, "\"path\":\"{s}\",", .{ctx.request.head.target});

        const ip = ctx.getHeader("X-Forwarded-For") orelse
            ctx.getHeader("X-Real-IP") orelse "unknown";
        try buffer.print(ctx.allocator, "\"ip\":\"{s}\"", .{ip});
        try buffer.print(ctx.allocator, "}}", .{});

        std.log.err("{s}", .{buffer.items});
    }
};
