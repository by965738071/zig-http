const std = @import("std");

/// Metrics collector
pub const Metrics = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    total_requests: u64,
    active_connections: u64,
    total_errors: u64,
    avg_response_time_ms: f64,
    request_counts: std.StringHashMap(u64),
    mutex: std.Io.Mutex,
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Metrics {
        return .{
            .io = io,
            .allocator = allocator,
            .total_requests = 0,
            .active_connections = 0,
            .total_errors = 0,
            .avg_response_time_ms = 0,
            .request_counts = std.StringHashMap(u64).init(allocator),
            .mutex = std.Io.Mutex.init,
            .start_time = std.Io.Timestamp.now(io, .boot).toMilliseconds(),
        };
    }

    pub fn deinit(metrics: *Metrics) void {
        // Manually free the duplicated keys before deinitializing the HashMap
        var it = metrics.request_counts.iterator();
        while (it.next()) |entry| {
            metrics.allocator.free(entry.key_ptr.*);
        }
        metrics.request_counts.deinit();
    }

    /// Record request
    pub fn recordRequest(metrics: *Metrics, path: []const u8, response_time_ms: u64) void {
        metrics.mutex.lock(metrics.io);
        defer metrics.mutex.unlock(metrics.io);

        metrics.total_requests += 1;
        metrics.avg_response_time_ms = (metrics.avg_response_time_ms * (metrics.total_requests - 1) + @as(f64, @floatFromInt(response_time_ms))) / @as(f64, @floatFromInt(metrics.total_requests));

        const gop = metrics.request_counts.getOrPut(path) catch return;
        if (!gop.found_existing) {
            // Need to duplicate the key since StringHashMap doesn't own the input slice
            gop.key_ptr.* = metrics.allocator.dupe(u8, path) catch return;
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* += 1;
        }
    }

    /// Record error
    pub fn recordError(metrics: *Metrics) void {
        metrics.mutex.lock(metrics.io);
        defer metrics.mutex.unlock(metrics.io);
        metrics.total_errors += 1;
    }

    /// Increment active connections
    pub fn incActive(metrics: *Metrics) void {
        metrics.mutex.lock(metrics.io);
        defer metrics.mutex.unlock(metrics.io);
        metrics.active_connections += 1;
    }

    /// Decrement active connections
    pub fn decActive(metrics: *Metrics) void {
        metrics.mutex.lock(metrics.io);
        defer metrics.mutex.unlock(metrics.io);
        if (metrics.active_connections > 0) {
            metrics.active_connections -= 1;
        }
    }

    /// Get metrics summary as JSON.
    /// The returned slice is allocated and must be freed by the caller.
    ///
    /// Example:
    /// ```zig
    /// const json = try metrics.allocToJson();
    /// defer metrics.allocator.free(json);
    /// ```
    pub fn allocToJson(metrics: *Metrics) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(metrics.allocator);

        try result.appendSlice(metrics.allocator, "{\n");

        const io = std.io.getStdIn().io;
        const uptime = std.Io.Timestamp.now(io, .boot).toMilliseconds() - metrics.start_time;
        try result.print(metrics.allocator, "  \"uptime_seconds\": {d},\n", .{uptime});
        try result.print(metrics.allocator, "  \"total_requests\": {d},\n", .{metrics.total_requests});
        try result.print(metrics.allocator, "  \"active_connections\": {d},\n", .{metrics.active_connections});
        try result.print(metrics.allocator, "  \"total_errors\": {d},\n", .{metrics.total_errors});
        try result.print(metrics.allocator, "  \"avg_response_time_ms\": {d:.2},\n", .{metrics.avg_response_time_ms});

        try result.appendSlice(metrics.allocator, "  \"top_paths\": [\n");

        var count = 0;
        var it = metrics.request_counts.iterator();
        while (it.next()) |entry| {
            try result.print(metrics.allocator, "    {{\"path\": \"{s}\", \"count\": {d}}}", .{ entry.key_ptr.*, entry.value_ptr.* });
            count += 1;
            if (count < 5 and count < metrics.request_counts.count) {
                try result.appendSlice(metrics.allocator, ",\n");
            }
        }

        try result.appendSlice(metrics.allocator, "\n  ]\n}\n");

        return result.toOwnedSlice(metrics.allocator);
    }
};
/// Request ID generator
pub const RequestId = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    counter: std.atomic.Value(u64),
    node_id: u32,

    pub fn init(node_id: u32, io: std.Io, allocator: std.mem.Allocator) RequestId {
        return .{
            .allocator = allocator,
            .io = io,
            .counter = std.atomic.Value(u64).init(0),
            .node_id = node_id,
        };
    }

    /// Generate next request ID.
    /// The returned slice is allocated and must be freed by the caller.
    ///
    /// Example:
    /// ```zig
    /// const id = try rid.allocNext();
    /// defer rid.allocator.free(id);
    /// ```
    pub fn allocNext(rid: *RequestId) ![]const u8 {
        const count = rid.counter.fetchAdd(1, .monotonic);

        const timestamp = std.Io.Timestamp.now(rid.io, .boot).toMilliseconds();

        const result = try std.fmt.allocPrint(rid.allocator, "{d}-{d}-{d}", .{ timestamp, rid.node_id, count });
        return result;
    }
};

/// Health check endpoint
pub const HealthCheck = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    checks: std.ArrayList(*Check),

    pub const Check = struct {
        name: []const u8,
        fn_ptr: *const fn () CheckResult,
    };

    pub const CheckResult = struct {
        status: Status,
        message: []const u8,
        duration_ms: u64,

        pub const Status = enum {
            healthy,
            degraded,
            unhealthy,
        };
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HealthCheck {
        return .{
            .io = io,
            .allocator = allocator,
            .checks = std.ArrayList(*Check){},
        };
    }

    pub fn deinit(hc: *HealthCheck) void {
        // Free each check object and its allocated strings
        for (hc.checks.items) |check| {
            hc.allocator.free(check.name); // Free the duplicated name string
            hc.allocator.destroy(check); // Destroy the Check object
        }
        hc.checks.deinit(hc.allocator); // Free the ArrayList
    }

    /// Add health check
    pub fn add(hc: *HealthCheck, name: []const u8, fn_ptr: *const fn () CheckResult) !void {
        const check = try hc.allocator.create(Check); // ✅ Correct create signature
        check.* = .{
            .name = try hc.allocator.dupe(u8, name), // Allocate and copy name
            .fn_ptr = fn_ptr,
        };
        try hc.checks.append(hc.allocator, check);
    }

    /// Run all health checks
    pub fn run(hc: *HealthCheck) !HealthCheckResult {
        var overall_status = CheckResult.Status.healthy;
        var results = std.ArrayList(CheckResult){};
        defer results.deinit(hc.allocator);

        const start = std.Io.Timestamp.now(hc.io, .boot).toMilliseconds();

        for (hc.checks.items) |check| {
            const result = check.fn_ptr();
            try results.append(hc.allocator, result);

            if (result.status == .unhealthy) {
                overall_status = .unhealthy;
            } else if (result.status == .degraded and overall_status != .unhealthy) {
                overall_status = .degraded;
            }
        }

        const duration = std.Io.Timestamp.now(hc.io, .boot).toMilliseconds() - start;

        return .{
            .overall_status = overall_status,
            .checks = results.toOwnedSlice(hc.allocator),
            .duration_ms = duration,
        };
    }
};

pub const HealthCheckResult = struct {
    overall_status: HealthCheck.CheckResult.Status,
    checks: []HealthCheck.CheckResult,
    duration_ms: u64,
};

/// Structured JSON logger
pub const JsonLogger = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    context: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) JsonLogger {
        return .{
            .allocator = allocator,
            .io = io,
            .output = std.ArrayList(u8).empty, // ✅ Use .empty instead of incorrect init
            .context = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(logger: *JsonLogger) void {
        var it = logger.context.iterator();
        while (it.next()) |entry| {
            logger.allocator.free(entry.key_ptr.*);
            logger.allocator.free(entry.value_ptr.*);
        }
        logger.context.deinit();
        logger.output.deinit(logger.allocator); // ✅ Pass allocator to deinit
    }

    /// Add context field
    pub fn setContext(logger: *JsonLogger, key: []const u8, value: []const u8) !void {
        const key_copy = try logger.allocator.dupe(u8, key);
        const value_copy = try logger.allocator.dupe(u8, value);
        try logger.context.put(key_copy, value_copy);
    }

    /// Log message
    pub fn log(logger: *JsonLogger, level: []const u8, message: []const u8, _: anytype) void {
        const timestamp = std.Io.Timestamp.now(logger.io, .boot).toMilliseconds();

        // Build JSON log entry
        const entry = std.fmt.allocPrint(logger.allocator, "{{\"timestamp\": {d}, \"level\": \"{s}\", \"message\": \"{s}\"}}", .{ timestamp, level, message }) catch return;

        defer logger.allocator.free(entry);

        logger.output.appendSlice(logger.allocator, entry) catch {}; // ✅ Pass allocator
    }

    /// Get all logs
    pub fn getLogs(logger: *JsonLogger) []const u8 {
        return logger.output.items;
    }
};
