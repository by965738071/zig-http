const std = @import("std");

/// Rate limiter configuration
pub const RateLimiterConfig = struct {
    max_requests: u64 = 100, // Max requests per window
    window_ms: u64 = 60000, // Window size in milliseconds (1 minute)
    cleanup_interval: u64 = 300000, // Cleanup interval (5 minutes)
};

/// Rate limiter entry
const RateLimiterEntry = struct {
    count: u64,
    window_start: i64,
};

/// Rate limiter for request frequency limiting
pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    clients: std.StringHashMap(RateLimiterEntry),
    config: RateLimiterConfig,
    last_cleanup: i64,
    mutex: std.Io.Mutex,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, config: RateLimiterConfig, io: std.Io) RateLimiter {
        return .{
            .allocator = allocator,
            .clients = std.StringHashMap(RateLimiterEntry).init(allocator),
            .config = config,
            .last_cleanup = std.Io.Timestamp.now(io, .boot).toMilliseconds(),
            .mutex = std.Io.Mutex.init,
            .io = io,
        };
    }

    pub fn deinit(limiter: *RateLimiter) void {
        limiter.clients.deinit();
    }

    /// Check if request is allowed
    pub fn isAllowed(limiter: *RateLimiter, client_id: []const u8) bool {
        limiter.mutex.lock(limiter.io) catch return false;
        defer limiter.mutex.unlock(limiter.io);

        const now = std.Io.Timestamp.now(limiter.io, .boot).toMilliseconds();

        // Periodic cleanup
        if (now - limiter.last_cleanup > limiter.config.cleanup_interval) {
            limiter.cleanup(now);
            limiter.last_cleanup = now;
        }

        // Get or create entry
        const entry = limiter.clients.getOrPut(client_id) catch |err| {
            std.log.err("Rate limiter error: {}", .{err});
            return false;
        };

        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .count = 1, .window_start = now };
            return true;
        }

        // Check if window expired
        if (now - entry.value_ptr.window_start >= limiter.config.window_ms) {
            entry.value_ptr.* = .{ .count = 1, .window_start = now };
            return true;
        }

        // Check if over limit
        if (entry.value_ptr.count >= limiter.config.max_requests) {
            return false;
        }

        entry.value_ptr.count += 1;
        return true;
    }

    /// Reset rate limit for client
    pub fn reset(limiter: *RateLimiter, client_id: []const u8) void {
        limiter.mutex.lock(limiter.io) catch {};
        defer limiter.mutex.unlock(limiter.io);
        _ = limiter.clients.remove(client_id);
    }

    /// Get remaining requests for client
    pub fn getRemaining(limiter: *RateLimiter, client_id: []const u8) u64 {
        limiter.mutex.lock(limiter.io) catch return 0;
        defer limiter.mutex.unlock(limiter.io);

        const entry = limiter.clients.get(client_id) orelse return limiter.config.max_requests;
        return limiter.config.max_requests - entry.count;
    }

    /// Clean up expired entries
    fn cleanup(limiter: *RateLimiter, now_ms: i64) void {
        var keys = std.ArrayList([]const u8).empty;
        defer {
            for (keys.items) |k| limiter.allocator.free(k);
            keys.deinit(limiter.allocator);
        }

        var it = limiter.clients.iterator();
        while (it.next()) |entry| {
            if (now_ms - entry.value_ptr.window_start >= limiter.config.window_ms) {
                keys.append(limiter.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (keys.items) |key| {
            _ = limiter.clients.remove(key);
        }
    }
};

test "rate limiter" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{ .max_requests = 5, .window_ms = 1000 }, std.testing.io_instance);
    defer limiter.deinit();

    // Should allow first 5 requests
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(limiter.isAllowed("client1"));
    }

    // 6th request should be denied
    try std.testing.expect(!limiter.isAllowed("client1"));

    // Different client should be allowed
    try std.testing.expect(limiter.isAllowed("client2"));
}
