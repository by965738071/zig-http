const std = @import("std");
const http = std.http;

/// Error types
pub const AppError = error{
    NotFound,
    BadRequest,
    Unauthorized,
    Forbidden,
    InternalServerError,
    NotImplemented,
    ValidationError,
};

/// Error response format
pub const ErrorResponse = struct {
    error_code: i32,
    message: []const u8,
    details: ?[]const u8 = null,
    path: ?[]const u8 = null,
    timestamp: i64,
};

/// Error handler
pub const ErrorHandler = struct {
    allocator: std.mem.Allocator,
    custom_pages: std.StringHashMap([]const u8),
    logger: *Logger,

    pub fn init(allocator: std.mem.Allocator, logger: *Logger) ErrorHandler {
        return .{
            .allocator = allocator,
            .custom_pages = std.StringHashMap([]const u8).init(allocator),
            .logger = logger,
        };
    }

    pub fn deinit(handler: *ErrorHandler) void {
        var it = handler.custom_pages.iterator();
        while (it.next()) |entry| {
            handler.allocator.free(entry.key_ptr.*);
            handler.allocator.free(entry.value_ptr.*);
        }
        handler.custom_pages.deinit();
    }

    /// Set custom error page
    pub fn setErrorPage(handler: *ErrorHandler, status: http.Status, html: []const u8) !void {
        const status_str = try std.fmt.allocPrint(handler.allocator, "{d}", .{@intFromEnum(status)});
        const html_copy = try handler.allocator.dupe(u8, html);
        try handler.custom_pages.put(status_str, html_copy);
    }

    /// Handle error
    pub fn handle(handler: ErrorHandler, err: anyerror, path: ?[]const u8) !ErrorResponse {
        const timestamp = std.time.timestamp();
        const status = handler.errorToStatus(err);
        const message = handler.errorMessage(err);

        try handler.logger.err("Error: {} - {}", .{ @errorName(err), message }, .{});

        return .{
            .error_code = @intFromEnum(status),
            .message = message,
            .path = path,
            .timestamp = timestamp,
        };
    }

    /// Convert error to HTTP status
    fn errorToStatus(_: ErrorHandler, err: anyerror) http.Status {
        return switch (err) {
            error.NotFound => http.Status.not_found,
            error.BadRequest => http.Status.bad_request,
            error.Unauthorized => http.Status.unauthorized,
            error.Forbidden => http.Status.forbidden,
            error.InternalServerError => http.Status.internal_server_error,
            error.NotImplemented => http.Status.not_implemented,
            error.ValidationError => http.Status.bad_request,
            else => http.Status.internal_server_error,
        };
    }

    /// Get error message
    fn errorMessage(_: ErrorHandler, err: anyerror) []const u8 {
        return switch (err) {
            error.NotFound => "Resource not found",
            error.BadRequest => "Bad request",
            error.Unauthorized => "Unauthorized access",
            error.Forbidden => "Forbidden access",
            error.InternalServerError => "Internal server error",
            error.NotImplemented => "Feature not implemented",
            error.ValidationError => "Validation failed",
            else => "An error occurred",
        };
    }
};

/// Logger
pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: LogLevel,
    output: std.ArrayList(u8),

    pub const LogLevel = enum {
        debug,
        info,
        warn,
        err,
    };

    pub fn init(allocator: std.mem.Allocator, level: LogLevel) Logger {
        return .{
            .allocator = allocator,
            .level = level,
            .output = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(logger: *Logger) void {
        logger.output.deinit(logger.allocator);
    }

    pub fn debug(logger: Logger, message: []const u8, args: anytype) void {
        if (logger.level != .debug) return;
        logger.log("DEBUG", message, args);
    }

    pub fn info(logger: Logger, message: []const u8, args: anytype) void {
        if (logger.level == .err or logger.level == .warn) return;
        logger.log("INFO", message, args);
    }

    pub fn warn(logger: Logger, message: []const u8, args: anytype) void {
        if (logger.level == .err) return;
        logger.log("WARN", message, args);
    }

    pub fn err(logger: Logger, message: []const u8, args: anytype) void {
        logger.log("ERROR", message, args);
    }

    fn log(logger: *Logger, level_str: []const u8, message: []const u8, _: anytype) void {
        const timestamp = std.time.timestamp();
        const timestamp_str = logger.formatTimestamp(timestamp);

        const entry = std.fmt.allocPrint(logger.allocator, "[{s}] {s}: {s}\n", .{ timestamp_str, level_str, message }) catch return;
        defer logger.allocator.free(entry);

        logger.output.appendSlice(logger.allocator, entry) catch {};
    }

    fn formatTimestamp(_: Logger, timestamp: i64) []const u8 {
        var buf: [64]u8 = undefined;
        const datetime = std.time.Instant.fromEpoch(timestamp);
        const local = datetime.toLocal();
        const result = local.format(std.time.format.default, "YYYY-MM-DD HH:MM:SS", .{});

        return std.fmt.bufPrintZ(&buf, "{s}", .{result}) catch "";
    }

    /// Get all log entries
    pub fn getLogs(logger: Logger) []const u8 {
        return logger.output.items;
    }
};

/// Panic recovery wrapper
pub const PanicHandler = struct {
    allocator: std.mem.Allocator,
    panic_count: usize,
    last_panic: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) PanicHandler {
        return .{
            .allocator = allocator,
            .panic_count = 0,
            .last_panic = null,
        };
    }

    pub fn deinit(handler: *PanicHandler) void {
        if (handler.last_panic) |msg| {
            handler.allocator.free(msg);
        }
    }

    pub fn handlePanic(handler: *PanicHandler, msg: []const u8, stack_trace: ?*std.builtin.StackTrace) void {
        handler.panic_count += 1;

        if (handler.last_panic) |old| {
            handler.allocator.free(old);
        }

        handler.last_panic = handler.allocator.dupe(u8, msg) catch msg;

        // Log panic
        std.log.err("PANIC: {s}\n", .{msg});

        if (stack_trace) |trace| {
            for (trace.instruction_addresses, 0..) |addr, i| {
                std.log.err("  {}: 0x{x}\n", .{ i, addr });
            }
        }

        // In production, you might want to continue
        // In development, you might want to crash
    }
};
