const std = @import("std");
const Io = std.Io;

/// WebSocket connection pool for broadcasting
pub const WebSocketPool = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*WebSocketConnection),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) WebSocketPool {
        return .{
            .allocator = allocator,
            .connections = std.ArrayList(*WebSocketConnection).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(pool: *WebSocketPool) void {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        for (pool.connections.items) |conn| {
            conn.deinit();
            pool.allocator.destroy(conn);
        }
        pool.connections.deinit();
    }

    /// Add connection
    pub fn add(pool: *WebSocketPool, conn: *WebSocketConnection) !void {
        pool.mutex.lock();
        defer pool.mutex.unlock();
        try pool.connections.append(conn);
    }

    /// Remove connection
    pub fn remove(pool: *WebSocketPool, conn: *WebSocketConnection) void {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        for (pool.connections.items, 0..) |item, i| {
            if (item == conn) {
                _ = pool.connections.orderedRemove(i);
                break;
            }
        }
    }

    /// Broadcast message to all connections
    pub fn broadcast(pool: *WebSocketPool, message: []const u8) void {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        for (pool.connections.items) |conn| {
            conn.send(message) catch {};
        }
    }

    /// Get connection count
    pub fn count(pool: *WebSocketPool) usize {
        pool.mutex.lock();
        defer pool.mutex.unlock();
        return pool.connections.items.len;
    }
};

/// WebSocket connection with advanced features
pub const WebSocketConnection = struct {
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    io: Io,
    write_buffer: std.ArrayList(u8),
    read_buffer: []u8,
    closed: std.atomic.Value(bool),
    last_ping: std.atomic.Value(i64),
    ping_interval: i64,
    ping_timeout: i64,
    subprotocol: ?[]const u8,
    user_data: ?*anyopaque,

    pub fn init(allocator: std.mem.Allocator, stream: Io.net.Stream, io: Io, read_buffer: []u8) WebSocketConnection {
        return .{
            .allocator = allocator,
            .stream = stream,
            .io = io,
            .write_buffer = std.ArrayList(u8).init(allocator, {}),
            .read_buffer = read_buffer,
            .closed = std.atomic.Value(bool).init(false),
            .last_ping = std.atomic.Value(i64).init(std.time.timestamp()),
            .ping_interval = 30000, // 30 seconds
            .ping_timeout = 60000, // 60 seconds
            .subprotocol = null,
            .user_data = null,
        };
    }

    pub fn deinit(conn: *WebSocketConnection) void {
        conn.closed.store(true, .monotonic);
        conn.write_buffer.deinit();
        if (conn.subprotocol) |sp| {
            conn.allocator.free(sp);
        }
    }

    /// Send message
    pub fn send(conn: *WebSocketConnection, message: []const u8) !void {
        if (conn.closed.load(.monotonic)) return error.Closed;

        conn.write_buffer.clearRetainingCapacity();
        try conn.write_frame(message, .text);
    }

    /// Send binary message
    pub fn sendBinary(conn: *WebSocketConnection, data: []const u8) !void {
        if (conn.closed.load(.monotonic)) return error.Closed;

        conn.write_buffer.clearRetainingCapacity();
        try conn.write_frame(data, .binary);
    }

    /// Send ping
    pub fn ping(conn: *WebSocketConnection) !void {
        if (conn.closed.load(.monotonic)) return error.Closed;

        conn.write_buffer.clearRetainingCapacity();
        try conn.write_frame(&.{}, .ping);
        conn.last_ping.store(std.time.timestamp(), .monotonic);
    }

    /// Send pong
    pub fn pong(conn: *WebSocketConnection, data: []const u8) !void {
        if (conn.closed.load(.monotonic)) return error.Closed;

        conn.write_buffer.clearRetainingCapacity();
        try conn.write_frame(data, .pong);
    }

    /// Start heartbeat
    pub fn startHeartbeat(conn: *WebSocketConnection) !void {
        // In a real implementation, this would spawn a thread
        // For now, we'll just send a ping on demand
        try conn.ping();
    }

    /// Check if connection is alive
    pub fn isAlive(conn: *WebSocketConnection) bool {
        const now = std.time.timestamp();
        const last = conn.last_ping.load(.monotonic);
        return (now - last) < conn.ping_timeout;
    }

    /// Close connection with status code and optional reason
    pub fn close(conn: *WebSocketConnection, code: u16, reason: []const u8) !void {
        conn.closed.store(true, .monotonic);

        // Build close frame payload: [2-byte big-endian code][reason]
        const payload_size = 2 + reason.len;
        conn.write_buffer.clearRetainingCapacity();

        // Write frame header (FIN + close opcode)
        const first_byte: u8 = 0x80 | 0x08;
        try conn.write_buffer.append(conn.allocator, first_byte);

        // Write payload length
        if (payload_size < 126) {
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(payload_size)));
        } else if (payload_size < 65536) {
            try conn.write_buffer.append(conn.allocator, 126);
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(payload_size >> 8)));
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(payload_size & 0xff)));
        } else {
            return error.PayloadTooLarge;
        }

        // Write close code (big-endian)
        try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(code >> 8)));
        try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(code & 0xff)));

        // Write reason if provided
        if (reason.len > 0) {
            try conn.write_buffer.appendSlice(conn.allocator, reason);
        }

        // Send frame
        const w = conn.stream.writer(conn.io, &.{});
        try w.writeAll(conn.write_buffer.items);
        try w.flush();

        conn.stream.close(conn.io);
    }

    /// Set user data
    pub fn setUserData(conn: *WebSocketConnection, data: anytype) !void {
        const T = @TypeOf(data);
        const ptr = try conn.allocator.create(T);
        ptr.* = data;
        conn.user_data = @ptrCast(ptr);
    }

    /// Get user data
    pub fn getUserData(conn: WebSocketConnection, comptime T: type) ?*T {
        if (conn.user_data) |data| {
            return @as(*T, @ptrCast(@alignCast(data)));
        }
        return null;
    }

    /// Write WebSocket frame
    fn write_frame(conn: *WebSocketConnection, data: []const u8, frame_type: FrameType) !void {
        const fin: u8 = 0x80;
        const opcode: u8 = switch (frame_type) {
            .text => 0x01,
            .binary => 0x02,
            .ping => 0x09,
            .pong => 0x0A,
            .close => 0x08,
        };

        const first_byte = fin | opcode;
        try conn.write_buffer.append(conn.allocator, first_byte);

        // Write length
        const len = data.len;
        if (len < 126) {
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(len)));
        } else if (len < 65536) {
            try conn.write_buffer.append(conn.allocator, 126);
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(len >> 8)));
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(len & 0xff)));
        } else {
            try conn.write_buffer.append(conn.allocator, 127);
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(len >> 24)));
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast((len >> 16) & 0xff)));
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast((len >> 8) & 0xff)));
            try conn.write_buffer.append(conn.allocator, @as(u8, @intCast(len & 0xff)));
        }

        // Write payload
        try conn.write_buffer.appendSlice(conn.allocator, data);

        // Write to stream
        const w = conn.stream.writer(conn.io, &.{});
        try w.writeAll(conn.write_buffer.items);
        try w.flush();
    }

    pub const FrameType = enum {
        text,
        binary,
        ping,
        pong,
        close,
    };
};

/// Message queue for WebSocket
pub const MessageQueue = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList([]const u8),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,

    pub fn init(allocator: std.mem.Allocator) MessageQueue {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList([]const u8).init(allocator),
            .mutex = .{},
            .condition = .{},
        };
    }

    pub fn deinit(queue: *MessageQueue) void {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        for (queue.messages.items) |msg| {
            queue.allocator.free(msg);
        }
        queue.messages.deinit();
    }

    /// Push message
    pub fn push(queue: *MessageQueue, message: []const u8) !void {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        const msg_copy = try queue.allocator.dupe(u8, message);
        try queue.messages.append(msg_copy);
        queue.condition.signal();
    }

    /// Pop message (blocking)
    pub fn pop(queue: *MessageQueue) ?[]const u8 {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        while (queue.messages.items.len == 0) {
            queue.condition.wait(&queue.mutex);
        }

        const msg = queue.messages.orderedRemove(0);
        return msg;
    }

    /// Try pop without blocking
    pub fn tryPop(queue: *MessageQueue) ?[]const u8 {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        if (queue.messages.items.len == 0) return null;

        return queue.messages.orderedRemove(0);
    }
};

/// Subprotocol negotiation
pub const Subprotocol = struct {
    name: []const u8,
    version: ?[]const u8 = null,

    pub fn format(sp: Subprotocol, allocator: std.mem.Allocator) ![]const u8 {
        if (sp.version) |v| {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ sp.name, v });
        }
        return allocator.dupe(u8, sp.name);
    }
};

/// Subprotocol registry
pub const SubprotocolRegistry = struct {
    allocator: std.mem.Allocator,
    protocols: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) SubprotocolRegistry {
        return .{
            .allocator = allocator,
            .protocols = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(registry: *SubprotocolRegistry) void {
        var it = registry.protocols.iterator();
        while (it.next()) |entry| {
            registry.allocator.free(entry.key_ptr.*);
            registry.allocator.free(entry.value_ptr.*);
        }
        registry.protocols.deinit();
    }

    /// Register subprotocol
    pub fn register(registry: *SubprotocolRegistry, name: []const u8, version: ?[]const u8) !void {
        const name_copy = try registry.allocator.dupe(u8, name);
        const version_copy = if (version) |v|
            try registry.allocator.dupe(u8, v)
        else
            null;
        try registry.protocols.put(name_copy, version_copy orelse "");
    }

    /// Negotiate subprotocol from client's Sec-WebSocket-Protocol header
    /// client_protocols should be a comma-separated list of protocol names
    pub fn negotiate(registry: SubprotocolRegistry, header_value: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, header_value, ',');

        while (it.next()) |proto| {
            const trimmed = std.mem.trim(u8, proto, &std.ascii.whitespace);
            if (registry.protocols.get(trimmed)) |_| {
                return trimmed;
            }
        }

        return null;
    }
};
