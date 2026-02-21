/// Memory pool implementation
/// Provides efficient memory allocation for small objects and reduces fragmentation
const std = @import("std");

/// Memory pool configuration
pub const PoolConfig = struct {
    block_size: usize = 4096,           // Size of each memory block
    max_blocks: usize = 1024,            // Maximum number of blocks
    small_size_threshold: usize = 256,   // Threshold for small object optimization
};

/// Memory pool for fixed-size allocations
pub const MemoryPool = struct {
    blocks: std.ArrayList([]u8),
    free_list: std.ArrayList(usize),
    config: PoolConfig,
    allocator: std.mem.Allocator,
    used_blocks: usize,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) MemoryPool {
        return .{
            .blocks = std.ArrayList([]u8){},
            .free_list = std.ArrayList(usize){},
            .config = config,
            .allocator = allocator,
            .used_blocks = 0,
        };
    }

    pub fn deinit(self: *MemoryPool) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block);
        }
        self.blocks.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    /// Allocate memory from pool
    pub fn alloc(self: *MemoryPool, size: usize) ![]u8 {
        if (size > self.config.block_size) {
            // Too large for pool, allocate directly
            return self.allocator.alloc(u8, size);
        }

        // Try to reuse a block from free list
        if (self.free_list.items.len > 0) {
            const index = self.free_list.items[self.free_list.items.len - 1];
            _ = self.free_list.pop();
            const block = self.blocks.items[index];
            @memset(block, 0);
            return block[0..size];
        }

        // Allocate a new block
        if (self.used_blocks >= self.config.max_blocks) {
            return error.OutOfMemory;
        }

        const block = try self.allocator.alloc(u8, self.config.block_size);
        try self.blocks.append(self.allocator, block);
        self.used_blocks += 1;

        @memset(block, 0);
        return block[0..size];
    }

    /// Free memory back to pool
    pub fn free(self: *MemoryPool, ptr: []u8) void {
        if (ptr.len > self.config.block_size) {
            // Allocated directly, free it
            self.allocator.free(ptr);
            return;
        }

        // Find the block and add to free list
        for (self.blocks.items, 0..) |block, i| {
            if (ptr.ptr >= block.ptr and ptr.ptr < block.ptr + block.len) {
                self.free_list.append(self.allocator, i) catch {};
                return;
            }
        }
    }

    /// Reset pool (clear all allocations)
    pub fn reset(self: *MemoryPool) void {
        self.free_list.clearRetainingCapacity();
        for (self.blocks.items) |block| {
            @memset(block, 0);
        }
    }

    /// Get usage statistics
    pub fn getStats(self: MemoryPool) PoolStats {
        return .{
            .total_blocks = self.blocks.items.len,
            .used_blocks = self.used_blocks,
            .free_blocks = self.free_list.items.len,
            .block_size = self.config.block_size,
            .total_bytes = self.blocks.items.len * self.config.block_size,
        };
    }

    /// Check if memory is from pool
    pub fn isFromPool(self: MemoryPool, ptr: []const u8) bool {
        for (self.blocks.items) |block| {
            if (ptr.ptr >= block.ptr and ptr.ptr < block.ptr + block.len) {
                return true;
            }
        }
        return false;
    }
};

/// Pool statistics
pub const PoolStats = struct {
    total_blocks: usize,
    used_blocks: usize,
    free_blocks: usize,
    block_size: usize,
    total_bytes: usize,
};

/// Arena allocator wrapper for request-scoped allocations
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent_allocator: std.mem.Allocator) RequestArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .parent_allocator = parent_allocator,
        };
    }

    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset arena (free all allocations)
    pub fn reset(self: *RequestArena) void {
        _ = self.arena.reset(.{ .retain_capacity = true });
    }

    /// Get current usage
    pub fn getUsage(self: RequestArena) usize {
        var total: usize = 0;
        var it = self.arena.state.buffer_list;
        while (it) |node| {
            total += node.data.len;
            it = node.next;
        }
        return total;
    }
};

/// Object pool for reusing objects
pub fn ObjectPool(comptime T: type) type {
    return struct {
        objects: std.ArrayList(*T),
        allocator: std.mem.Allocator,
        max_objects: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, max_objects: usize) Self {
            return .{
                .objects = std.ArrayList(*T).init(allocator),
                .allocator = allocator,
                .max_objects = max_objects,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.objects.items) |obj| {
                obj.deinit();
                self.allocator.destroy(obj);
            }
            self.objects.deinit();
        }

        /// Acquire an object from pool
        pub fn acquire(self: *Self) !*T {
            if (self.objects.popOrNull()) |obj| {
                obj.reset();
                return obj;
            }

            const obj = try self.allocator.create(T);
            obj.* = try T.init();
            return obj;
        }

        /// Release an object back to pool
        pub fn release(self: *Self, obj: *T) void {
            if (self.objects.items.len < self.max_objects) {
                self.objects.append(obj) catch {};
            } else {
                obj.deinit();
                self.allocator.destroy(obj);
            }
        }

        /// Get pool size
        pub fn len(self: Self) usize {
            return self.objects.items.len;
        }

        /// Get available objects
        pub fn available(self: Self) usize {
            return self.objects.items.len;
        }
    };
}

/// Fixed-size buffer pool for connections
pub const BufferPool = struct {
    buffers: std.ArrayList([]u8),
    free_buffers: std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    buffer_size: usize,
    max_buffers: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize, max_buffers: usize) BufferPool {
        return .{
            .buffers = std.ArrayList([]u8){},
            .free_buffers = std.ArrayList([]u8){},
            .allocator = allocator,
            .buffer_size = buffer_size,
            .max_buffers = max_buffers,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.buffers.deinit(self.allocator);
        self.free_buffers.deinit(self.allocator);
    }

    /// Acquire a buffer
    pub fn acquire(self: *BufferPool) ![]u8 {
        if (self.free_buffers.items.len > 0) {
            const buffer = self.free_buffers.items[self.free_buffers.items.len - 1];
            _ = self.free_buffers.pop();
            return buffer;
        }

        if (self.buffers.items.len >= self.max_buffers) {
            return error.OutOfMemory;
        }

        const buffer = try self.allocator.alloc(u8, self.buffer_size);
        try self.buffers.append(buffer);
        return buffer;
    }

    /// Release a buffer back to pool
    pub fn release(self: *BufferPool, buffer: []u8) void {
        if (buffer.len != self.buffer_size) {
            return;
        }

        // Check if buffer is from this pool
        for (self.buffers.items) |b| {
            if (b.ptr == buffer.ptr) {
                self.free_buffers.append(self.allocator, buffer) catch {};
                return;
            }
        }
    }

    /// Get pool statistics
    pub fn getStats(self: BufferPool) BufferPoolStats {
        return .{
            .total_buffers = self.buffers.items.len,
            .free_buffers = self.free_buffers.items.len,
            .buffer_size = self.buffer_size,
            .total_bytes = self.buffers.items.len * self.buffer_size,
        };
    }

    /// Reset pool
    pub fn reset(self: *BufferPool) void {
        self.free_buffers.clearRetainingCapacity();
        self.free_buffers.clearAndFree(self.allocator);
    }
};

/// Buffer pool statistics
pub const BufferPoolStats = struct {
    total_buffers: usize,
    free_buffers: usize,
    buffer_size: usize,
    total_bytes: usize,
};

/// Stack allocator for small, short-lived allocations
pub const StackAllocator = struct {
    base_ptr: [*]u8,
    current_ptr: [*]u8,
    end_ptr: [*]u8,

    pub fn init(buffer: []u8) StackAllocator {
        return .{
            .base_ptr = buffer.ptr,
            .current_ptr = buffer.ptr,
            .end_ptr = buffer.ptr + buffer.len,
        };
    }

    /// Allocate memory from stack
    pub fn alloc(self: *StackAllocator, size: usize, alignment: u29) ![]u8 {
        // Align current pointer
        const aligned_addr = std.mem.alignForward(usize, @intFromPtr(self.current_ptr), alignment);
        const aligned_ptr = @as([*]u8, @ptrFromInt(aligned_addr));

        // Check if enough space
        if (aligned_ptr + size > self.end_ptr) {
            return error.OutOfMemory;
        }

        self.current_ptr = aligned_ptr + size;
        return aligned_ptr[0..size];
    }

    /// Reset stack allocator
    pub fn reset(self: *StackAllocator) void {
        self.current_ptr = self.base_ptr;
    }

    /// Mark a position for reset
    pub fn mark(self: StackAllocator) [*]u8 {
        return self.current_ptr;
    }

    /// Reset to marked position
    pub fn resetToMark(self: *StackAllocator, mark_pos: [*]u8) void {
        std.debug.assert(mark_pos >= self.base_ptr and mark_pos <= self.end_ptr);
        self.current_ptr = mark_pos;
    }

    /// Get remaining space
    pub fn remaining(self: StackAllocator) usize {
        return @intFromPtr(self.end_ptr) - @intFromPtr(self.current_ptr);
    }
};

test "MemoryPool basic usage" {
    const allocator = std.testing.allocator;
    const config = PoolConfig{
        .block_size = 1024,
        .max_blocks = 10,
    };

    var pool = MemoryPool.init(allocator, config);
    defer pool.deinit();

    // Allocate small buffer
    const buf1 = try pool.alloc(512);
    std.testing.expect(buf1.len == 512);

    // Free and reuse
    pool.free(buf1);

    const buf2 = try pool.alloc(256);
    std.testing.expect(buf2.len == 256);

    // Stats
    const stats = pool.getStats();
    std.testing.expect(stats.total_blocks == 1);

    pool.free(buf2);
}

test "RequestArena" {
    const allocator = std.testing.allocator;
    var arena = RequestArena.init(allocator);
    defer arena.deinit();

    // Allocate some data
    _ = try arena.allocator().alloc(u8, 100);
    _ = try arena.allocator().alloc(u8, 200);

    // Check usage
    const usage = arena.getUsage();
    std.testing.expect(usage >= 300);

    // Reset
    arena.reset();

    // Usage should be minimal now
    const new_usage = arena.getUsage();
    std.testing.expect(new_usage < usage);
}

test "BufferPool" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator, 1024, 10);
    defer pool.deinit();

    // Acquire buffers
    const buf1 = try pool.acquire();
    const buf2 = try pool.acquire();

    std.testing.expect(buf1.len == 1024);
    std.testing.expect(buf2.len == 1024);

    // Release one
    pool.release(buf1);

    const stats = pool.getStats();
    std.testing.expect(stats.total_buffers == 2);
    std.testing.expect(stats.free_buffers == 1);
}

test "StackAllocator" {
    var buffer: [4096]u8 = undefined;
    var stack = StackAllocator.init(&buffer);

    const data1 = try stack.alloc(100, 1);
    std.testing.expect(data1.len == 100);

    const data2 = try stack.alloc(200, 4);
    std.testing.expect(data2.len == 200);

    // Mark and reset
    const mark = stack.mark();

    const data3 = try stack.alloc(100, 1);
    std.testing.expect(data3.len == 100);

    stack.resetToMark(mark);

    std.testing.expect(stack.remaining() > 100);
}
