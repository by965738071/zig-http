/// Connection pool for reusing TCP connections
/// Reduces connection establishment overhead and improves performance
const std = @import("std");
const Atomic = std.atomic.Value;

/// Connection pool configuration
pub const PoolConfig = struct {
    max_connections: usize = 100,
    max_idle_connections: usize = 10,
    max_idle_time: u64 = 60_000, // 60 seconds
    max_lifetime: u64 = 300_000, // 5 minutes
    connection_timeout: u64 = 5_000, // 5 seconds
    cleanup_interval: u64 = 30_000, // 30 seconds
};

/// Connection state
const ConnState = enum {
    idle,
    in_use,
    closed,
};

/// Pooled connection
const PooledConnection = struct {
    stream: std.net.Stream,
    host: []const u8,
    port: u16,
    state: ConnState,
    created_at: u64,
    last_used: u64,
    ref_count: Atomic(u32),

    pub fn init(stream: std.net.Stream, host: []const u8, port: u16) PooledConnection {
        const now = std.time.nanoTimestamp();
        return .{
            .stream = stream,
            .host = host,
            .port = port,
            .state = .idle,
            .created_at = now,
            .last_used = now,
            .ref_count = Atomic(u32).init(0),
        };
    }

    pub fn close(self: *PooledConnection) void {
        if (self.state != .closed) {
            self.stream.close();
            self.state = .closed;
        }
    }

    pub fn incrementRef(self: *PooledConnection) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn decrementRef(self: *PooledConnection) void {
        _ = self.ref_count.fetchSub(1, .monotonic);
    }

    pub fn getRefCount(self: *PooledConnection) u32 {
        return self.ref_count.load(.monotonic);
    }

    pub fn isExpired(self: *PooledConnection, max_idle: u64, max_lifetime: u64) bool {
        const now = std.time.nanoTimestamp();
        const idle_time = (now - self.last_used) / 1_000_000; // Convert to ms
        const lifetime = (now - self.created_at) / 1_000_000;

        return idle_time > max_idle or lifetime > max_lifetime;
    }
};

/// Connection pool entry
const PoolEntry = struct {
    connection: ?*PooledConnection,
    next: ?*PoolEntry,
    prev: ?*PoolEntry,
};

/// Connection pool implementation
pub const ConnectionPool = struct {
    config: PoolConfig,
    allocator: std.mem.Allocator,
    connections: std.StringHashMap(*PoolEntry), // Key: "host:port"
    idle_connections: std.ArrayList(*PooledConnection),
    cleanup_task: ?std.Thread,
    shutdown_requested: Atomic(bool),
    mutex: std.Thread.Mutex,
    cleanup_mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !Self {
        return .{
            .config = config,
            .allocator = allocator,
            .connections = std.StringHashMap(*PoolEntry).init(allocator),
            .idle_connections = std.ArrayList(*PooledConnection).init(allocator),
            .cleanup_task = null,
            .shutdown_requested = Atomic(bool).init(false),
            .mutex = std.Thread.Mutex{},
            .cleanup_mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Close all connections
        var it = self.connections.valueIterator();
        while (it.next()) |entry| {
            if (entry.connection) |conn| {
                conn.close();
                self.allocator.destroy(conn);
            }
            self.allocator.destroy(entry.*);
        }

        self.connections.deinit();
        self.idle_connections.deinit();
    }

    /// Get a connection from the pool or create a new one
    pub fn acquire(self: *Self, host: []const u8, port: u16) !*PooledConnection {
        // Create key
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
        defer self.allocator.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to find existing idle connection
        if (self.connections.get(key)) |entry| {
            if (entry.connection) |conn| {
                if (conn.state == .idle and !conn.isExpired(
                    self.config.max_idle_time,
                    self.config.max_lifetime,
                )) {
                    conn.state = .in_use;
                    conn.incrementRef();
                    conn.last_used = std.time.nanoTimestamp();

                    // Remove from idle list
                    self.removeFromIdle(conn);

                    return conn;
                }
            }
        }

        // Create new connection
        if (self.connections.count() >= self.config.max_connections) {
            return error.PoolExhausted;
        }

        const stream = try self.connect(host, port);
        const conn = try self.allocator.create(PooledConnection);
        conn.* = PooledConnection.init(stream, try self.allocator.dupe(u8, host), port);

        const entry = try self.allocator.create(PoolEntry);
        entry.* = .{
            .connection = conn,
            .next = null,
            .prev = null,
        };

        try self.connections.put(try self.allocator.dupe(u8, key), entry);

        conn.state = .in_use;
        conn.incrementRef();
        conn.last_used = std.time.nanoTimestamp();

        return conn;
    }

    /// Release a connection back to the pool
    pub fn release(self: *Self, conn: *PooledConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        conn.decrementRef();

        if (conn.getRefCount() == 0) {
            conn.state = .idle;
            conn.last_used = std.time.nanoTimestamp();

            // Add to idle list
            if (self.idle_connections.items.len < self.config.max_idle_connections) {
                self.idle_connections.append(conn) catch {};
            } else {
                // Too many idle connections, close this one
                conn.close();
            }
        }
    }

    /// Remove connection from idle list
    fn removeFromIdle(self: *Self, conn: *PooledConnection) void {
        for (self.idle_connections.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.idle_connections.orderedRemove(i);
                return;
            }
        }
    }

    /// Establish a new connection
    fn connect(self: *Self, host: []const u8, port: u16) !std.net.Stream {
        const address = try std.net.Address.parseIp(host, port);

        // Connect with timeout using tcp_connectToHost with custom timeout
        const timeout_ns = self.config.connection_timeout * std.time.ns_per_ms;
        const stream = try std.net.tcp.connectToHost(
            self.allocator,
            address,
            timeout_ns,
        );

        // Configure socket options
        try stream.handle.setNoDelay(true); // Disable Nagle's algorithm
        try stream.handle.setKeepAlive(true);

        return stream;
    }

    /// Start cleanup task
    pub fn startCleanupTask(self: *Self) !void {
        self.shutdown_requested.store(false, .monotonic);

        self.cleanup_task = try std.Thread.spawn(
            .{},
            cleanupTaskFn,
            .{self},
        );
    }

    /// Stop cleanup task
    pub fn stopCleanupTask(self: *Self) void {
        self.shutdown_requested.store(true, .monotonic);

        if (self.cleanup_task) |task| {
            task.join();
            self.cleanup_task = null;
        }
    }

    /// Cleanup task function
    fn cleanupTaskFn(pool: *Self) void {
        while (!pool.shutdown_requested.load(.monotonic)) {
            std.time.sleep(pool.config.cleanup_interval * std.time.ns_per_ms);
            pool.cleanup();
        }
    }

    /// Cleanup expired connections
    pub fn cleanup(self: *Self) void {
        self.cleanup_mutex.lock();
        defer self.cleanup_mutex.unlock();

        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.idle_connections.items.len) {
            const conn = self.idle_connections.items[i];

            if (conn.state == .idle and conn.isExpired(
                self.config.max_idle_time,
                self.config.max_lifetime,
            )) {
                conn.close();
                _ = self.idle_connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Shutdown pool and close all connections
    pub fn shutdown(self: *Self) void {
        self.stopCleanupTask();

        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.connections.valueIterator();
        while (it.next()) |entry| {
            if (entry.connection) |conn| {
                conn.close();
            }
        }
    }

    /// Get pool statistics
    pub fn getStats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var active: usize = 0;
        var it = self.connections.valueIterator();
        while (it.next()) |entry| {
            if (entry.connection) |conn| {
                if (conn.state == .in_use) {
                    active += 1;
                }
            }
        }

        return .{
            .total_connections = self.connections.count(),
            .active_connections = active,
            .idle_connections = self.idle_connections.items.len,
            .max_connections = self.config.max_connections,
        };
    }
};

/// Pool statistics
pub const PoolStats = struct {
    total_connections: usize,
    active_connections: usize,
    idle_connections: usize,
    max_connections: usize,
};

/// HTTP connection pool with keep-alive support
pub const HttpConnectionPool = struct {
    pool: ConnectionPool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !HttpConnectionPool {
        return .{
            .pool = try ConnectionPool.init(allocator, config),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpConnectionPool) void {
        self.pool.deinit();
    }

    /// Perform HTTP request using pooled connection
    pub fn request(
        self: *HttpConnectionPool,
        method: []const u8,
        host: []const u8,
        port: u16,
        path: []const u8,
        headers: []const []const u8,
        body: ?[]const u8,
    ) !HttpResponse {
        const conn = try self.pool.acquire(host, port);
        defer self.pool.release(conn);

        // Build HTTP request buffer
        var request_buf = std.ArrayList(u8).init(self.allocator);
        defer request_buf.deinit();

        try request_buf.writer().print("{s} {s} HTTP/1.1\r\n", .{ method, path });
        try request_buf.writer().print("Host: {s}\r\n", .{host});
        try request_buf.writer().print("Connection: keep-alive\r\n", .{});

        if (body) |b| {
            try request_buf.writer().print("Content-Length: {d}\r\n", .{b.len});
        }

        for (headers) |header| {
            try request_buf.appendSlice(header);
            try request_buf.appendSlice("\r\n");
        }

        try request_buf.appendSlice("\r\n");

        if (body) |b| {
            try request_buf.appendSlice(b);
        }

        // Send request
        try conn.stream.writer().writeAll(request_buf.items);

        // Read response
        var response_buf: [8192]u8 = undefined;
        const n = try conn.stream.reader().readAll(&response_buf);

        return HttpResponse{
            .data = try self.allocator.dupe(u8, response_buf[0..n]),
            .connection = conn,
        };
    }

    /// Start cleanup task
    pub fn startCleanupTask(self: *HttpConnectionPool) !void {
        try self.pool.startCleanupTask();
    }

    /// Stop cleanup task
    pub fn stopCleanupTask(self: *HttpConnectionPool) void {
        self.pool.stopCleanupTask();
    }

    /// Get statistics
    pub fn getStats(self: *HttpConnectionPool) PoolStats {
        return self.pool.getStats();
    }
};

/// HTTP response
pub const HttpResponse = struct {
    data: []u8,
    connection: *PooledConnection,
};

test "ConnectionPool basic usage" {
    const allocator = std.testing.allocator;
    const config = PoolConfig{
        .max_connections = 10,
        .max_idle_connections = 5,
    };

    var pool = try ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Try to acquire (will fail without actual server)
    const result = pool.acquire("127.0.0.1", 8080);

    // In real scenario with server running:
    // if (result) |conn| {
    //     pool.release(conn);
    // }

    _ = result; // Suppress unused warning
}

test "PoolStats" {
    const stats = PoolStats{
        .total_connections = 10,
        .active_connections = 5,
        .idle_connections = 5,
        .max_connections = 100,
    };

    try std.testing.expect(stats.total_connections == 10);
    try std.testing.expect(stats.active_connections == 5);
    try std.testing.expect(stats.idle_connections == 5);
}
