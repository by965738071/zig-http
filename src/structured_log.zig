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

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err
};

/// Structured logger for HTTP requests
pub const StructuredLogger = struct {
    config: LogConfig,

    pub fn init(config: LogConfig) StructuredLogger {
        return .{ .config = config };
    }

    /// Log an HTTP request with timing
    pub fn logRequest(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) !void {
        const log_entry = try logger.buildLogEntry(ctx, duration_ns);
        defer ctx.allocator.free(log_entry);

        const level = logger.determineLogLevel(ctx, duration_ns);
        const log_fn = switch (level) {
            .debug => std.log.debug,
            .info => std.log.info,
            .warn => std.log.warn,
            .err => std.log.err,
        };

        log_fn("{s}", .{log_entry});
    }

    /// Log slow request
    pub fn logSlowRequest(logger: *const StructuredLogger, ctx: *Context, duration_ns: i64) void {
        _ = logger; // Not used, kept for API consistency
        const duration_ms = @divTrunc(duration_ns, 1_000_000);
        std.log.warn("Slow request: {s} {s} - {d}ms - {s}", .{
            ctx.method,
            ctx.path,
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
        var buffer = std.ArrayList(u8).init(ctx.allocator);
        const duration_us = @divTrunc(duration_ns, 1000);

        try buffer.writer().print("{s} {s} - {d}μs - {d}", .{
            ctx.method,
            ctx.path,
            duration_us,
            ctx.response.status,
        });

        if (logger.config.include_request_id) {
            try buffer.writer().print(" - {s}", .{ctx.getRequestId()});
        }

        if (logger.config.include_ip_address) {
            try buffer.writer().print(" - {s}", .{ctx.ip_address orelse "unknown"});
        }

        if (logger.config.include_user_agent) {
            const ua = ctx.getHeader("User-Agent") orelse "-";
            try buffer.writer().print(" - \"{s}\"", .{ua});
        }

        return buffer.toOwnedSlice();
    }

    fn buildJsonLog(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) ![]const u8 {
        var buffer = std.ArrayList(u8).init(ctx.allocator);

        try buffer.appendSlice("{");
        try buffer.writer().print("\"timestamp\":{d},", .{std.time.timestamp()});
        try buffer.writer().print("\"level\":\"{s}\",", .{@tagName(logger.config.log_level)});
        try buffer.writer().print("\"method\":\"{s}\",", .{ctx.method});
        try buffer.writer().print("\"path\":\"{s}\",", .{ctx.path});
        try buffer.writer().print("\"status\":{d},", .{ctx.response.status});
        try buffer.writer().print("\"duration_ns\":{d},", .{duration_ns});

        if (logger.config.include_request_id) {
            try buffer.writer().print("\"request_id\":\"{s}\",", .{ctx.getRequestId()});
        }

        if (logger.config.include_ip_address) {
            try buffer.writer().print("\"ip\":\"{s}\",", .{ctx.ip_address orelse "unknown"});
        }

        if (logger.config.include_user_agent) {
            const ua = ctx.getHeader("User-Agent") orelse "-";
            const escaped_ua = escapeJsonString(ua);
            try buffer.writer().print("\"user_agent\":\"{s}\",", .{escaped_ua});
        }

        if (logger.config.include_headers) {
            try buffer.appendSlice("\"headers\":{");
            const headers = ctx.getAllHeaders();
            var it = headers.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buffer.appendSlice(",");
                first = false;
                try buffer.writer().print("\"{s}\":\"{s}\"", .{
                    entry.key_ptr.*,
                    escapeJsonString(entry.value_ptr.*),
                });
            }
            try buffer.appendSlice("},");
        }

        try buffer.appendSlice("}\n");
        return buffer.toOwnedSlice();
    }

    fn determineLogLevel(logger: *StructuredLogger, ctx: *Context, duration_ns: i64) LogLevel {
        if (duration_ns > logger.config.slow_request_threshold_ns) {
            return .warn;
        }

        const status = ctx.response.status;
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
        var buffer = std.ArrayList(u8).init(ctx.allocator);
        defer buffer.deinit();

        try buffer.writer().print("{{", .{});
        try buffer.writer().print("\"timestamp\":{d},", .{std.time.timestamp()});
        try buffer.writer().print("\"level\":\"error\",", .{});
        try buffer.writer().print("\"error\":\"{s}\",", .{@errorName(err)});
        try buffer.writer().print("\"request_id\":\"{s}\",", .{ctx.getRequestId()});
        try buffer.writer().print("\"method\":\"{s}\",", .{ctx.method});
        try buffer.writer().print("\"path\":\"{s}\",", .{ctx.path});
        try buffer.writer().print("\"ip\":\"{s}\"", .{ctx.ip_address orelse "unknown"});
        try buffer.writer().print("}}", .{});

        std.log.err("{s}", .{buffer.items});
    }
};
