/// Buffer management optimization
/// Efficient buffer allocation, reuse, and management for high-performance I/O
const std = @import("std");

/// Buffer manager configuration
pub const BufferConfig = struct {
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 4096,
    max_read_buffers: usize = 100,
    max_write_buffers: usize = 100,
    enable_buffer_pooling: bool = true,
};

/// Buffer header for tracking buffer metadata
const BufferHeader = struct {
    next: ?*Buffer = null,
    prev: ?*Buffer = null,
    size: usize,
    in_use: bool,
    allocated_at: u64,
};

/// Managed buffer
const Buffer = struct {
    header: BufferHeader,
    data: []u8,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Buffer {
        const data = try allocator.alloc(u8, size);
        return .{
            .header = .{
                .next = null,
                .prev = null,
                .size = size,
                .in_use = false,
                .allocated_at = std.time.nanoTimestamp(),
            },
            .data = data,
        };
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Buffer manager for efficient buffer allocation
pub const BufferManager = struct {
    config: BufferConfig,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    // Read buffers
    free_read_buffers: std.ArrayList(*Buffer),
    used_read_buffers: std.ArrayList(*Buffer),

    // Write buffers
    free_write_buffers: std.ArrayList(*Buffer),
    used_write_buffers: std.ArrayList(*Buffer),

    // Statistics
    total_read_allocations: usize,
    total_write_allocations: usize,
    total_read_reuses: usize,
    total_write_reuses: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: BufferConfig) BufferManager {
        return .{
            .config = config,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .free_read_buffers = std.ArrayList(*Buffer).init(allocator),
            .used_read_buffers = std.ArrayList(*Buffer).init(allocator),
            .free_write_buffers = std.ArrayList(*Buffer).init(allocator),
            .used_write_buffers = std.ArrayList(*Buffer).init(allocator),
            .total_read_allocations = 0,
            .total_write_allocations = 0,
            .total_read_reuses = 0,
            .total_write_reuses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all read buffers
        for (self.free_read_buffers.items) |buf| {
            buf.deinit(self.allocator);
            self.allocator.destroy(buf);
        }
        for (self.used_read_buffers.items) |buf| {
            buf.deinit(self.allocator);
            self.allocator.destroy(buf);
        }

        // Free all write buffers
        for (self.free_write_buffers.items) |buf| {
            buf.deinit(self.allocator);
            self.allocator.destroy(buf);
        }
        for (self.used_write_buffers.items) |buf| {
            buf.deinit(self.allocator);
            self.allocator.destroy(buf);
        }

        self.free_read_buffers.deinit(self.allocator);
        self.used_read_buffers.deinit(self.allocator);
        self.free_write_buffers.deinit(self.allocator);
        self.used_write_buffers.deinit(self.allocator);
    }

    /// Acquire a read buffer
    pub fn acquireReadBuffer(self: *Self) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.config.enable_buffer_pooling) {
            return self.allocator.alloc(u8, self.config.read_buffer_size);
        }

        // Try to reuse a free buffer
        if (self.free_read_buffers.items.len > 0) {
            const buffer = self.free_read_buffers.items[self.free_read_buffers.items.len - 1];
            _ = self.free_read_buffers.pop();
            buffer.header.in_use = true;
            try self.used_read_buffers.append(self.allocator, buffer);
            self.total_read_reuses += 1;
            return buffer.data;
        }

        // Allocate new buffer if under limit
        if (self.used_read_buffers.items.len < self.config.max_read_buffers) {
            const buffer = try self.allocator.create(Buffer);
            buffer.* = try Buffer.init(self.allocator, self.config.read_buffer_size);
            buffer.header.in_use = true;
            try self.used_read_buffers.append(self.allocator, buffer);
            self.total_read_allocations += 1;
            return buffer.data;
        }

        // Pool exhausted, allocate temporary
        return self.allocator.alloc(u8, self.config.read_buffer_size);
    }

    /// Release a read buffer
    pub fn releaseReadBuffer(self: *Self, data: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.config.enable_buffer_pooling) {
            self.allocator.free(data);
            return;
        }

        // Find buffer in used list
        for (self.used_read_buffers.items, 0..) |buffer, i| {
            if (buffer.data.ptr == data.ptr) {
                buffer.header.in_use = false;
                _ = self.used_read_buffers.orderedRemove(i);

                // Return to free list
                if (self.free_read_buffers.items.len < self.config.max_read_buffers) {
                    self.free_read_buffers.append(self.allocator, buffer) catch {
                        buffer.deinit(self.allocator);
                        self.allocator.destroy(buffer);
                    };
                } else {
                    buffer.deinit(self.allocator);
                    self.allocator.destroy(buffer);
                }
                return;
            }
        }

        // Not found in pool, free it
        self.allocator.free(data);
    }

    /// Acquire a write buffer
    pub fn acquireWriteBuffer(self: *Self) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.config.enable_buffer_pooling) {
            return self.allocator.alloc(u8, self.config.write_buffer_size);
        }

        // Try to reuse a free buffer
        if (self.free_write_buffers.popOrNull()) |buffer| {
            buffer.header.in_use = true;
            try self.used_write_buffers.append(buffer);
            self.total_write_reuses += 1;
            return buffer.data;
        }

        // Allocate new buffer if under limit
        if (self.used_write_buffers.items.len < self.config.max_write_buffers) {
            const buffer = try self.allocator.create(Buffer);
            buffer.* = try Buffer.init(self.allocator, self.config.write_buffer_size);
            buffer.header.in_use = true;
            try self.used_write_buffers.append(buffer);
            self.total_write_allocations += 1;
            return buffer.data;
        }

        // Pool exhausted, allocate temporary
        return self.allocator.alloc(u8, self.config.write_buffer_size);
    }

    /// Release a write buffer
    pub fn releaseWriteBuffer(self: *Self, data: []u8) void {
        if (!self.config.enable_buffer_pooling) {
            self.allocator.free(data);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Find buffer in used list
        for (self.used_write_buffers.items, 0..) |buffer, i| {
            if (buffer.data.ptr == data.ptr) {
                buffer.header.in_use = false;
                _ = self.used_write_buffers.orderedRemove(i);

                // Return to free list
                if (self.free_write_buffers.items.len < self.config.max_write_buffers) {
                    self.free_write_buffers.append(buffer) catch {
                        buffer.deinit(self.allocator);
                        self.allocator.destroy(buffer);
                    };
                } else {
                    buffer.deinit(self.allocator);
                    self.allocator.destroy(buffer);
                }
                return;
            }
        }

        self.allocator.free(data);
    }

    /// Get statistics
    pub fn getStats(self: *Self) BufferStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .free_read_buffers = self.free_read_buffers.items.len,
            .used_read_buffers = self.used_read_buffers.items.len,
            .free_write_buffers = self.free_write_buffers.items.len,
            .used_write_buffers = self.used_write_buffers.items.len,
            .total_read_allocations = self.total_read_allocations,
            .total_write_allocations = self.total_write_allocations,
            .total_read_reuses = self.total_read_reuses,
            .total_write_reuses = self.total_write_reuses,
        };
    }

    /// Reset buffer manager (release all used buffers)
    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Move all used buffers to free
        while (self.used_read_buffers.popOrNull()) |buffer| {
            buffer.header.in_use = false;
            self.free_read_buffers.append(buffer) catch {
                buffer.deinit(self.allocator);
                self.allocator.destroy(buffer);
            };
        }

        while (self.used_write_buffers.popOrNull()) |buffer| {
            buffer.header.in_use = false;
            self.free_write_buffers.append(buffer) catch {
                buffer.deinit(self.allocator);
                self.allocator.destroy(buffer);
            };
        }
    }

    /// Pre-allocate buffers
    pub fn preallocate(self: *Self, read_count: usize, write_count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < read_count and self.free_read_buffers.items.len < self.config.max_read_buffers) : (i += 1) {
            const buffer = try self.allocator.create(Buffer);
            buffer.* = try Buffer.init(self.allocator, self.config.read_buffer_size);
            buffer.header.in_use = false;
            try self.free_read_buffers.append(buffer);
        }

        i = 0;
        while (i < write_count and self.free_write_buffers.items.len < self.config.max_write_buffers) : (i += 1) {
            const buffer = try self.allocator.create(Buffer);
            buffer.* = try Buffer.init(self.allocator, self.config.write_buffer_size);
            buffer.header.in_use = false;
            try self.free_write_buffers.append(buffer);
        }
    }
};

/// Buffer statistics
pub const BufferStats = struct {
    free_read_buffers: usize,
    used_read_buffers: usize,
    free_write_buffers: usize,
    used_write_buffers: usize,
    total_read_allocations: usize,
    total_write_allocations: usize,
    total_read_reuses: usize,
    total_write_reuses: usize,

    pub fn getReuseRate(stats: BufferStats) f64 {
        const total_read = stats.total_read_allocations + stats.total_read_reuses;
        const total_write = stats.total_write_allocations + stats.total_write_reuses;

        if (total_read + total_write == 0) return 0.0;

        const reuses = @as(f64, @floatFromInt(stats.total_read_reuses + stats.total_write_reuses));
        const total = @as(f64, @floatFromInt(total_read + total_write));

        return (reuses / total) * 100.0;
    }
};

/// Ring buffer for circular buffer operations
pub fn RingBuffer(comptime T: type) type {
    return struct {
        data: []T,
        head: usize,
        tail: usize,
        capacity: usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const data = try allocator.alloc(T, capacity);
            return .{
                .data = data,
                .head = 0,
                .tail = 0,
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        /// Write data to ring buffer
        pub fn write(self: *Self, items: []const T) !usize {
            const available = self.availableWrite();
            const to_write = @min(items.len, available);

            var written: usize = 0;
            for (items[0..to_write]) |item| {
                self.data[self.head] = item;
                self.head = (self.head + 1) % self.capacity;
                written += 1;
            }

            return written;
        }

        /// Read data from ring buffer
        pub fn read(self: *Self, buffer: []T) !usize {
            const available = self.availableRead();
            const to_read = @min(buffer.len, available);

            for (0..to_read) |i| {
                buffer[i] = self.data[self.tail];
                self.tail = (self.tail + 1) % self.capacity;
            }

            return to_read;
        }

        /// Get available space for writing
        pub fn availableWrite(self: Self) usize {
            if (self.head >= self.tail) {
                return self.capacity - (self.head - self.tail) - 1;
            }
            return self.tail - self.head - 1;
        }

        /// Get available data for reading
        pub fn availableRead(self: Self) usize {
            if (self.head >= self.tail) {
                return self.head - self.tail;
            }
            return self.capacity - self.tail + self.head;
        }

        /// Check if buffer is empty
        pub fn isEmpty(self: Self) bool {
            return self.head == self.tail;
        }

        /// Check if buffer is full
        pub fn isFull(self: Self) bool {
            return (self.head + 1) % self.capacity == self.tail;
        }

        /// Clear buffer
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }

        /// Get fill percentage
        pub fn fillPercentage(self: Self) f64 {
            const used = self.availableRead();
            return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.capacity)) * 100.0;
        }
    };
}

/// Zero-copy buffer wrapper
pub const ZeroCopyBuffer = struct {
    data: []u8,
    owner: ?*const ZeroCopyBuffer,

    pub fn fromSlice(input: []const u8) ZeroCopyBuffer {
        return .{
            .data = @constCast(input),
            .owner = null,
        };
    }

    pub fn copy(input: []const u8, allocator: std.mem.Allocator) !ZeroCopyBuffer {
        const data = try allocator.dupe(u8, input);
        return .{
            .data = data,
            .owner = null,
        };
    }

    pub fn deinit(self: *ZeroCopyBuffer, allocator: std.mem.Allocator) void {
        if (self.owner == null) {
            allocator.free(self.data);
        }
    }

    pub fn slice(self: *ZeroCopyBuffer, start: usize, end: usize) !ZeroCopyBuffer {
        if (start > end or end > self.data.len) {
            return error.InvalidRange;
        }

        return .{
            .data = self.data[start..end],
            .owner = self,
        };
    }

    pub fn len(self: ZeroCopyBuffer) usize {
        return self.data.len;
    }

    pub fn isEmpty(self: ZeroCopyBuffer) bool {
        return self.data.len == 0;
    }
};

test "BufferManager basic usage" {
    const allocator = std.testing.allocator;
    const config = BufferConfig{
        .read_buffer_size = 1024,
        .write_buffer_size = 512,
        .max_read_buffers = 5,
        .max_write_buffers = 5,
    };

    var manager = BufferManager.init(allocator, config);
    defer manager.deinit();

    // Pre-allocate
    try manager.preallocate(2, 2);

    const stats = manager.getStats();
    try std.testing.expect(stats.free_read_buffers == 2);
    try std.testing.expect(stats.free_write_buffers == 2);

    // Acquire read buffer
    const read_buf = try manager.acquireReadBuffer();
    try std.testing.expect(read_buf.len == 1024);

    // Release read buffer
    manager.releaseReadBuffer(read_buf);

    // Check reuse stats
    const final_stats = manager.getStats();
    try std.testing.expect(final_stats.total_read_reuses > 0);
}

test "RingBuffer" {
    const allocator = std.testing.allocator;
    var ring = try RingBuffer(u8).init(allocator, 10);
    defer ring.deinit();

    const data = "Hello";
    const written = try ring.write(data);
    try std.testing.expect(written == 5);

    var read_buf: [10]u8 = undefined;
    const read = try ring.read(&read_buf);
    try std.testing.expect(read == 5);
    try std.testing.expectEqualStrings(data, read_buf[0..read]);

    try std.testing.expect(ring.isEmpty());
}

test "ZeroCopyBuffer" {
    const allocator = std.testing.allocator;

    const data = "Hello, World!";
    var buf = try ZeroCopyBuffer.copy(data, allocator);
    defer buf.deinit(allocator);

    try std.testing.expectEqualStrings(data, buf.data);

    const sub = try buf.slice(7, 12);
    try std.testing.expectEqualStrings("World", sub.data);
}
