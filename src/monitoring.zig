const std = @import("std");

/// Metrics collector
pub const Metrics = struct {
    allocator: std.mem.Allocator,
    total_requests: u64,
    active_connections: u64,
    total_errors: u64,
    avg_response_time_ms: f64,
    request_counts: std.StringHashMap(u64),
    mutex: std.Thread.Mutex,
    start_time: u64,

    pub fn init(allocator: std.mem.Allocator) Metrics {
        return .{
            .allocator = allocator,
            .total_requests = 0,
            .active_connections = 0,
            .total_errors = 0,
            .avg_response_time_ms = 0,
            .request_counts = std.StringHashMap(u64).init(allocator),
            .mutex = .{},
            .start_time = blk: {
                const now = std.time.Instant.now() catch unreachable;
                break :blk now.timestamp;
            },
        };
    }

    pub fn deinit(metrics: *Metrics) void {
        var it = metrics.request_counts.iterator();
        while (it.next()) |entry| {
            metrics.allocator.free(entry.key_ptr.*);
        }
        metrics.request_counts.deinit();
    }

    /// Record request
    pub fn recordRequest(metrics: *Metrics, path: []const u8, response_time_ms: u64) void {
        metrics.mutex.lock();
        defer metrics.mutex.unlock();

        metrics.total_requests += 1;
        metrics.avg_response_time_ms = (metrics.avg_response_time_ms * (metrics.total_requests - 1) + @as(f64, @floatFromInt(response_time_ms))) / @as(f64, @floatFromInt(metrics.total_requests));

        const entry = metrics.request_counts.getOrPut(path) catch return;
        if (!entry.found_existing) {
            const path_copy = metrics.allocator.dupe(u8, path) catch path;
            _ = metrics.request_counts.put(path_copy, 1) catch {};
        } else {
            entry.value_ptr.* += 1;
        }
    }

    /// Record error
    pub fn recordError(metrics: *Metrics) void {
        metrics.mutex.lock();
        defer metrics.mutex.unlock();
        metrics.total_errors += 1;
    }

    /// Increment active connections
    pub fn incActive(metrics: *Metrics) void {
        metrics.mutex.lock();
        defer metrics.mutex.unlock();
        metrics.active_connections += 1;
    }

    /// Decrement active connections
    pub fn decActive(metrics: *Metrics) void {
        metrics.mutex.lock();
        defer metrics.mutex.unlock();
        if (metrics.active_connections > 0) {
            metrics.active_connections -= 1;
        }
    }

    /// Get metrics summary as JSON
    pub fn toJson(metrics: Metrics, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator, {});
        errdefer result.deinit();

        try result.appendSlice(allocator, "{\n");

        const uptime = std.time.timestamp() - metrics.start_time;
        try result.print(allocator, "  \"uptime_seconds\": {d},\n", .{uptime});
        try result.print(allocator, "  \"total_requests\": {d},\n", .{metrics.total_requests});
        try result.print(allocator, "  \"active_connections\": {d},\n", .{metrics.active_connections});
        try result.print(allocator, "  \"total_errors\": {d},\n", .{metrics.total_errors});
        try result.print(allocator, "  \"avg_response_time_ms\": {d:.2},\n", .{metrics.avg_response_time_ms});

        try result.appendSlice(allocator, "  \"top_paths\": [\n");

        var count = 0;
        var it = metrics.request_counts.iterator();
        while (it.next()) |entry| {
            try result.print(allocator, "    {{\"path\": \"{s}\", \"count\": {d}}}", .{ entry.key_ptr.*, entry.value_ptr.* });
            count += 1;
            if (count < 5 and count < metrics.request_counts.count) {
                try result.appendSlice(allocator, ",\n");
            }
        }

        try result.appendSlice(allocator, "\n  ]\n}\n");

        return result.toOwnedSlice(allocator);
    }
};

/// Request ID generator
pub const RequestId = struct {
    counter: std.atomic.Value(u64),
    node_id: u32,

    pub fn init(node_id: u32) RequestId {
        return .{
            .counter = std.atomic.Value(u64).init(0),
            .node_id = node_id,
        };
    }

    pub fn next(rid: *RequestId) ![]const u8 {
        const count = rid.counter.fetchAdd(1, .monotonic);
        const timestamp = std.time.timestamp();

        // Format: timestamp-nodeid-counter
        const allocator = std.heap.page_allocator;
        const result = try std.fmt.allocPrint(allocator, "{d}-{d}-{d}", .{ timestamp, rid.node_id, count });
        return result;
    }
};

/// Health check endpoint
pub const HealthCheck = struct {
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

    pub fn init(allocator: std.mem.Allocator) HealthCheck {
        return .{
            .allocator = allocator,
            .checks = std.ArrayList(*Check).init(allocator),
        };
    }

    pub fn deinit(hc: *HealthCheck) void {
        hc.checks.deinit();
    }

    /// Add health check
    pub fn add(hc: *HealthCheck, name: []const u8, fn_ptr: *const fn () CheckResult) !void {
        const check = try hc.allocator.create(Check);
        check.* = .{
            .name = try hc.allocator.dupe(u8, name),
            .fn_ptr = fn_ptr,
        };
        try hc.checks.append(check);
    }

    /// Run all health checks
    pub fn run(hc: HealthCheck) !HealthCheckResult {
        var overall_status = CheckResult.Status.healthy;
        var results = std.ArrayList(CheckResult).init(hc.allocator);
        defer results.deinit();

        const start = std.time.microTimestamp();

        for (hc.checks.items) |check| {
            const result = check.fn_ptr();
            try results.append(result);

            if (result.status == .unhealthy) {
                overall_status = .unhealthy;
            } else if (result.status == .degraded and overall_status != .unhealthy) {
                overall_status = .degraded;
            }
        }

        const duration = @as(u64, @intCast(std.time.microTimestamp() - start)) / 1000;

        return .{
            .overall_status = overall_status,
            .checks = results.toOwnedSlice(),
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
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    context: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) JsonLogger {
        return .{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator, {}),
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
        logger.output.deinit();
    }

    /// Add context field
    pub fn setContext(logger: *JsonLogger, key: []const u8, value: []const u8) !void {
        const key_copy = try logger.allocator.dupe(u8, key);
        const value_copy = try logger.allocator.dupe(u8, value);
        try logger.context.put(key_copy, value_copy);
    }

    /// Log message
    pub fn log(logger: *JsonLogger, level: []const u8, message: []const u8, _: anytype) void {
        const timestamp = std.time.timestamp();

        // Build JSON log entry
        const entry = std.fmt.allocPrint(logger.allocator, "{{\"timestamp\": {d}, \"level\": \"{s}\", \"message\": \"{s}\"}}", .{ timestamp, level, message }) catch return;

        defer logger.allocator.free(entry);

        logger.output.appendSlice(entry) catch {};
    }

    /// Get all logs
    pub fn getLogs(logger: JsonLogger) []const u8 {
        return logger.output.items;
    }
};
