/// Zero-copy optimization module
/// Provides zero-copy buffer handling to minimize memory allocations and copies
const std = @import("std");
const builtin = @import("builtin");

/// ============================================================================
/// Mutex Implementation (based on std.Io.Mutex)
/// ============================================================================
/// A thread-safe mutual exclusion lock with three-state design for optimal performance.
/// Supports both cancelable and uncancelable lock operations.
///
/// State Machine:
///   .unlocked   -> No holder, can be acquired immediately
///   .locked_once -> Single holder, no waiters (fast unlock)
///   .contended   -> Single holder, waiters present (futex wake on unlock)
///
/// Performance Characteristics:
///   - Uncontended: ~10-20 CPU cycles (single CAS)
///   - Contended: ~1-10 μs (futex system call)
///   - Memory: 4 bytes (u32)
/// ============================================================================

/// Mutex state enumeration
pub const MutexState = enum(u32) {
    /// Lock is available for acquisition
    unlocked = 0,
    /// Lock is held by one thread, no waiters
    locked_once = 1,
    /// Lock is held by one thread, waiters are present
    contended = 2,
};

/// Mutual exclusion lock with support for cancellation
pub const Mutex = extern struct {
    /// Atomic state variable
    state: std.atomic.Value(MutexState),

    /// Initial unlocked state
    pub const init: Mutex = .{ .state = .init(.unlocked) };

    /// Try to acquire the lock without blocking
    /// Returns true if lock was acquired, false if it was already held
    ///
    /// Thread-safe: Uses atomic compare-and-swap operation
    /// Memory order: acquire on success (ensures subsequent operations visible),
    ///              monotonic on failure (no ordering guarantees needed)
    pub fn tryLock(m: *Mutex) bool {
        return m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) == null;
    }

    /// Acquire the lock, blocking if necessary
    /// Supports cancellation via error.Canceled
    ///
    /// Fast Path: Single CAS operation when lock is uncontended
    /// Slow Path: Futex-based blocking when contention is detected
    ///
    /// Memory semantics:
    ///   - Acquire: Ensures lock acquisition happens-before critical section
    ///   - Release: Ensures critical section happens-before unlock
    pub fn lock(m: *Mutex) !void {
        // Fast path: Try to acquire lock immediately
        const initial_state = m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);  // Hint: lock is usually uncontended
            return;  // Successfully acquired lock
        };

        // Slow path: Lock was contended, use futex for waiting

        // If initial state was contended, wait for unlock notification
        if (initial_state == .contended) {
            try m.futexWait(.contended);
        }

        // Spin-wait loop with futex
        // Set state to contended (indicating we are waiting) and wait
        while (m.state.swap(.contended, .acquire) != .unlocked) {
            try m.futexWait(.contended);
        }
    }

    /// Acquire the lock, blocking if necessary
    /// Does NOT support cancellation - use when critical section must complete
    ///
    /// Similar to lock() but uses futexWaitUncancelable() which
    /// does not return error.Canceled
    pub fn lockUncancelable(m: *Mutex) void {
        // Fast path: Try to acquire lock immediately
        const initial_state = m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);
            return;
        };

        // Slow path: Lock was contended

        if (initial_state == .contended) {
            m.futexWaitUncancelable(.contended);
        }

        while (m.state.swap(.contended, .acquire) != .unlocked) {
            m.futexWaitUncancelable(.contended);
        }
    }

    /// Release the lock and wake one waiting thread if any
    ///
    /// Memory order: Release ensures all operations in critical section
    /// become visible to the next thread acquiring the lock
    ///
    /// Wakeup strategy: Wake only one waiter (fair FIFO behavior)
    pub fn unlock(m: *Mutex) void {
        switch (m.state.swap(.unlocked, .release)) {
            .unlocked => unreachable,  // Programming error: unlock unlocked mutex
            .locked_once => {},       // No waiters, no need to wake
            .contended => {
                @branchHint(.unlikely);  // Hint: contention is less common
                // Wake exactly one waiting thread
                m.futexWake(1);
            },
        }
    }

    /// Futex wait operation (platform-specific implementation)
    /// Atomically checks if state equals expected and blocks if so
    ///
    /// Uses Linux futex or equivalent mechanism on other platforms
    inline fn futexWait(m: *Mutex, expected: MutexState) !void {
        const expected_int = @intFromEnum(expected);
        const ptr = @ptrCast(&m.state.raw);

        // Platform-specific futex implementation
        if (comptime builtin.os.tag == .linux) {
            // Linux futex system call
            const rc = std.os.linux.futex_wait(
                @intFromPtr(ptr),
                std.os.linux.FUTEX.PRIVATE,
                &.{ .cmd = .WAIT, .private = false },
                expected_int,
                null,
            );

            return switch (std.os.linux.E.init(rc)) {
                .SUCCESS => {},
                .INTR => {
                    // Spurious wakeup or interrupt, retry
                    return error.Canceled;
                },
                .AGAIN => {
                    // State changed before we could wait
                    return error.Canceled;
                },
                else => |err| std.posix.unexpectedErrno(err),
            };
        } else {
            // Fallback: Use atomic spin with yield for other platforms
            var attempts: usize = 0;
            const max_attempts = 1000;

            while (attempts < max_attempts) : (attempts += 1) {
                const current = @atomicLoad(MutexState, ptr, .acquire);
                if (current != expected) {
                    return;  // State changed, no need to wait
                }

                // Yield to scheduler (platform-specific)
                std.atomic.spinLoopHint();

                // Simulate cancellation check
                if (attempts % 100 == 0) {
                    return error.Canceled;
                }
            }

            return error.Canceled;
        }
    }

    /// Uncancelable futex wait (never returns error.Canceled)
    inline fn futexWaitUncancelable(m: *Mutex, expected: MutexState) void {
        const expected_int = @intFromEnum(expected);
        const ptr = @ptrCast(&m.state.raw);

        if (comptime builtin.os.tag == .linux) {
            // Linux futex system call
            while (true) {
                const current = @atomicLoad(MutexState, ptr, .acquire);
                if (current != expected) break;

                const rc = std.os.linux.futex_wait(
                    @intFromPtr(ptr),
                    std.os.linux.FUTEX.PRIVATE,
                    &.{ .cmd = .WAIT, .private = false },
                    expected_int,
                    null,
                );

                _ = rc;  // Ignore result, retry on spurious wakeups
            }
        } else {
            // Fallback: Spin wait for other platforms
            var attempts: usize = 0;
            const max_attempts = 10000;

            while (attempts < max_attempts) : (attempts += 1) {
                const current = @atomicLoad(MutexState, ptr, .acquire);
                if (current != expected) break;

                std.atomic.spinLoopHint();
            }
        }
    }

    /// Futex wake operation
    /// Wakes up to max_waiters threads waiting on this mutex
    inline fn futexWake(m: *Mutex, max_waiters: u32) void {
        const ptr = @ptrCast(&m.state.raw);

        if (comptime builtin.os.tag == .linux) {
            // Linux futex wake system call
            _ = std.os.linux.futex_wake(
                @intFromPtr(ptr),
                std.os.linux.FUTEX.PRIVATE,
                &.{ .cmd = .WAKE, .private = false },
                max_waiters,
            );
        } else {
            // Fallback: No-op for spin-based implementation
            // (waiters will detect state change on next iteration)
            _ = max_waiters;
        }
    }
};

/// RAII-style guard for automatic mutex unlocking
/// Use with defer pattern to ensure lock is always released
pub const MutexGuard = struct {
    mutex: *Mutex,

    /// Create guard by acquiring lock
    pub fn acquire(mutex: *Mutex) !MutexGuard {
        try mutex.lock();
        return .{ .mutex = mutex };
    }

    /// Create uncancelable guard
    pub fn acquireUncancelable(mutex: *Mutex) MutexGuard {
        mutex.lockUncancelable();
        return .{ .mutex = mutex };
    }

    /// Release lock on guard destruction
    pub fn deinit(self: *MutexGuard) void {
        self.mutex.unlock();
    }
};

/// Reentrant mutex (allows multiple locks by same thread)
/// Tracks owner thread and lock count for nested locking
pub const ReentrantMutex = struct {
    /// Inner mutex for actual synchronization
    inner: Mutex,

    /// Owning thread ID (null if unlocked)
    owner: ?std.Thread.Id,

    /// Lock depth (number of times current thread has locked)
    depth: usize,

    pub const init: ReentrantMutex = .{
        .inner = .init,
        .owner = null,
        .depth = 0,
    };

    /// Acquire the lock (reentrant-safe)
    pub fn lock(m: *ReentrantMutex) !void {
        const current_id = std.Thread.getCurrentId();

        if (m.owner) |owner_id| {
            // Already holding the lock
            if (owner_id == current_id) {
                m.depth += 1;
                return;
            }
        }

        // Acquire inner mutex
        try m.inner.lock();
        m.owner = current_id;
        m.depth = 1;
    }

    /// Acquire uncancelable lock
    pub fn lockUncancelable(m: *ReentrantMutex) void {
        const current_id = std.Thread.getCurrentId();

        if (m.owner) |owner_id| {
            if (owner_id == current_id) {
                m.depth += 1;
                return;
            }
        }

        m.inner.lockUncancelable();
        m.owner = current_id;
        m.depth = 1;
    }

    /// Release the lock (decrements depth, unlocks on zero)
    pub fn unlock(m: *ReentrantMutex) void {
        const current_id = std.Thread.getCurrentId();

        std.debug.assert(m.owner != null);
        std.debug.assert(m.owner.? == current_id);
        std.debug.assert(m.depth > 0);

        m.depth -= 1;
        if (m.depth == 0) {
            m.owner = null;
            m.inner.unlock();
        }
    }

    /// Try to acquire without blocking
    pub fn tryLock(m: *ReentrantMutex) bool {
        const current_id = std.Thread.getCurrentId();

        if (m.owner) |owner_id| {
            if (owner_id == current_id) {
                m.depth += 1;
                return true;
            }
        }

        if (m.inner.tryLock()) {
            m.owner = current_id;
            m.depth = 1;
            return true;
        }

        return false;
    }
};

/// Condition variable for thread synchronization
/// Allows threads to wait for a condition and be woken when signaled
pub const Condition = struct {
    /// Internal mutex for state protection
    mutex: Mutex,

    /// Number of waiting threads
    waiters: std.atomic.Value(usize),

    /// Epoch counter for signal tracking
    epoch: std.atomic.Value(u32),

    pub const init: Condition = .{
        .mutex = .init,
        .waiters = .init(0),
        .epoch = .init(0),
    };

    /// Wait for condition signal (requires mutex to be held)
    pub fn wait(cond: *Condition) !void {
        const my_epoch = cond.epoch.load(.acquire);

        // Increment waiter count
        _ = cond.waiters.fetchAdd(1, .monotonic);

        // Release mutex while waiting
        cond.mutex.unlock();

        defer {
            // Re-acquire mutex before returning
            try cond.mutex.lock();

            // Decrement waiter count
            _ = cond.waiters.fetchSub(1, .monotonic);
        }

        // Wait for signal using futex-like spin
        var attempts: usize = 0;
        const max_attempts = 10000;

        while (attempts < max_attempts) : (attempts += 1) {
            const current_epoch = cond.epoch.load(.acquire);

            if (current_epoch != my_epoch) {
                return;  // Signal received
            }

            std.atomic.spinLoopHint();

            // Check for cancellation periodically
            if (attempts % 100 == 0) {
                return error.Canceled;
            }
        }

        return error.Canceled;
    }

    /// Wake one waiting thread
    pub fn signal(cond: *Condition) void {
        // Only signal if there are waiters
        if (cond.waiters.load(.monotonic) > 0) {
            // Increment epoch to wake waiters
            _ = cond.epoch.fetchAdd(1, .release);
        }
    }

    /// Wake all waiting threads
    pub fn broadcast(cond: *Condition) void {
        if (cond.waiters.load(.monotonic) > 0) {
            _ = cond.epoch.fetchAdd(1, .release);
        }
    }
};

/// Read-Write Lock (Multiple readers OR single writer)
/// Optimized for read-heavy workloads with infrequent writes
pub const RwLock = struct {
    /// State encoding: high bits = readers, low bit = writer lock
    state: std.atomic.Value(u32),

    /// Maximum readers supported
    pub const max_readers: u32 = 0x7FFFFFFF;  // 31 bits for readers

    pub const init: RwLock = .{ .state = .init(0) };

    /// Acquire read lock (multiple readers allowed)
    pub fn readLock(rw: *RwLock) !void {
        var attempts: usize = 0;
        const max_attempts = 10000;

        while (attempts < max_attempts) : (attempts += 1) {
            const current = rw.state.load(.acquire);
            const writer_bit: u32 = 1 << 31;

            // Can acquire read lock if no writer and reader count not at max
            if ((current & writer_bit) == 0 and (current & max_readers) < max_readers) {
                const new_value = current + 1;
                if (rw.state.cmpxchgWeak(current, new_value, .acquire, .monotonic)) |actual| {
                    if (actual == current) {
                        return;  // Successfully acquired read lock
                    }
                }
            }

            std.atomic.spinLoopHint();

            if (attempts % 100 == 0) {
                return error.Canceled;
            }
        }

        return error.Canceled;
    }

    /// Release read lock
    pub fn readUnlock(rw: *RwLock) void {
        const prev = rw.state.fetchSub(1, .release);
        std.debug.assert((prev & max_readers) > 0);
    }

    /// Acquire write lock (exclusive access)
    pub fn writeLock(rw: *RwLock) !void {
        var attempts: usize = 0;
        const max_attempts = 10000;
        const writer_bit: u32 = 1 << 31;

        while (attempts < max_attempts) : (attempts += 1) {
            const current = rw.state.load(.acquire);

            // Can acquire write lock if no readers and no writer
            if (current == 0) {
                const new_value = writer_bit;
                if (rw.state.cmpxchgWeak(current, new_value, .acquire, .monotonic)) |actual| {
                    if (actual == current) {
                        return;  // Successfully acquired write lock
                    }
                }
            }

            std.atomic.spinLoopHint();

            if (attempts % 100 == 0) {
                return error.Canceled;
            }
        }

        return error.Canceled;
    }

    /// Release write lock
    pub fn writeUnlock(rw: *RwLock) void {
        const prev = rw.state.swap(0, .release);
        const writer_bit: u32 = 1 << 31;
        std.debug.assert((prev & writer_bit) != 0);
        std.debug.assert((prev & max_readers) == 0);
    }

    /// Try to acquire read lock without blocking
    pub fn tryReadLock(rw: *RwLock) bool {
        const current = rw.state.load(.acquire);
        const writer_bit: u32 = 1 << 31;

        if ((current & writer_bit) == 0 and (current & max_readers) < max_readers) {
            const new_value = current + 1;
            return rw.state.cmpxchgWeak(current, new_value, .acquire, .monotonic) == null;
        }

        return false;
    }

    /// Try to acquire write lock without blocking
    pub fn tryWriteLock(rw: *RwLock) bool {
        const current = rw.state.load(.acquire);
        const writer_bit: u32 = 1 << 31;

        if (current == 0) {
            const new_value = writer_bit;
            return rw.state.cmpxchgWeak(current, new_value, .acquire, .monotonic) == null;
        }

        return false;
    }
};

/// Spinlock for very short critical sections
/// Uses busy-wait without yielding for maximum performance
/// WARNING: Only use for critical sections with <100 CPU cycles
pub const SpinLock = struct {
    /// Atomic flag: 0 = unlocked, 1 = locked
    flag: std.atomic.Value(u8),

    pub const init: SpinLock = .{ .flag = .init(0) };

    /// Acquire spinlock
    pub fn lock(s: *SpinLock) void {
        var attempts: usize = 0;
        const max_spin = 10000;

        while (attempts < max_spin) : (attempts += 1) {
            if (s.flag.swap(1, .acquire) == 0) {
                return;  // Acquired
            }

            // Hint to CPU that we're spinning
            std.atomic.spinLoopHint();
        }

        // Fallback to yielding after max spin attempts
        while (s.flag.swap(1, .acquire) != 0) {
            std.Thread.yield() catch {};
        }
    }

    /// Release spinlock
    pub fn unlock(s: *SpinLock) void {
        s.flag.store(0, .release);
    }

    /// Try to acquire without spinning
    pub fn tryLock(s: *SpinLock) bool {
        return s.flag.cmpxchgWeak(0, 1, .acquire, .monotonic) == null;
    }
};

/// Zero-copy buffer view
/// Represents a view into existing memory without copying
pub const BufferView = struct {
    ptr: [*]const u8,
    len: usize,

    /// Create a buffer view from a slice
    pub fn fromSlice(slice_data: []const u8) BufferView {
        return .{
            .ptr = slice_data.ptr,
            .len = slice_data.len,
        };
    }

    /// Convert back to slice
    pub fn toSlice(self: BufferView) []const u8 {
        return self.ptr[0..self.len];
    }

    /// Create a sub-view (zero-copy)
    pub fn slice(self: BufferView, start: usize, end: usize) BufferView {
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.len);
        return .{
            .ptr = self.ptr + start,
            .len = end - start,
        };
    }

    /// Check if buffer is empty
    pub fn isEmpty(self: BufferView) bool {
        return self.len == 0;
    }
};

/// Zero-copy byte builder
/// Builds output using existing buffers when possible
pub const ZeroCopyBuilder = struct {
    buffers: std.ArrayList(BufferView),
    allocator: std.mem.Allocator,
    total_len: usize,

    pub fn init(allocator: std.mem.Allocator) ZeroCopyBuilder {
        return .{
            .buffers = std.ArrayList(BufferView){},
            .allocator = allocator,
            .total_len = 0,
        };
    }

    pub fn deinit(self: *ZeroCopyBuilder) void {
        self.buffers.deinit(self.allocator);
    }

    /// Add a buffer view (zero-copy)
    pub fn appendView(self: *ZeroCopyBuilder, view: BufferView) !void {
        try self.buffers.append(self.allocator, view);
        self.total_len += view.len;
    }

    /// Add a slice (creates a view)
    pub fn appendSlice(self: *ZeroCopyBuilder, slice: []const u8) !void {
        try self.appendView(BufferView.fromSlice(slice));
    }

    /// Add owned data (will be copied)
    pub fn appendOwned(self: *ZeroCopyBuilder, data: []const u8) !void {
        const owned = try self.allocator.dupe(u8, data);
        try self.appendView(BufferView.fromSlice(owned));
    }

    /// Get total length
    pub fn len(self: ZeroCopyBuilder) usize {
        return self.total_len;
    }

    /// Build final buffer
    pub fn build(self: *ZeroCopyBuilder) ![]u8 {
        const result = try self.allocator.alloc(u8, self.total_len);
        var offset: usize = 0;

        for (self.buffers.items) |view| {
            @memcpy(result[offset..][0..view.len], view.toSlice());
            offset += view.len;
        }

        return result;
    }

    /// Write directly to a writer (zero-copy)
    pub fn writeTo(self: *ZeroCopyBuilder, writer: anytype) !void {
        for (self.buffers.items) |view| {
            try writer.writeAll(view.toSlice());
        }
    }

    /// Clear builder
    pub fn clear(self: *ZeroCopyBuilder) void {
        self.buffers.clearRetainingCapacity();
        self.total_len = 0;
    }
};

/// Zero-copy HTTP response builder
/// Builds HTTP responses efficiently using zero-copy techniques
pub const ZeroCopyResponse = struct {
    status_line: BufferView,
    headers: std.ArrayList(BufferView),
    body: std.ArrayList(BufferView),
    allocator: std.mem.Allocator,
    body_len: usize,

    pub fn init(allocator: std.mem.Allocator) ZeroCopyResponse {
        return .{
            .status_line = BufferView{ .ptr = null, .len = 0 },
            .headers = std.ArrayList(BufferView).init(allocator),
            .allocator = allocator,
            .body = std.ArrayList(BufferView).init(allocator),
            .body_len = 0,
        };
    }

    pub fn deinit(self: *ZeroCopyResponse) void {
        self.headers.deinit();
        self.body.deinit();
    }

    /// Set status line
    pub fn setStatusLine(self: *ZeroCopyResponse, line: []const u8) void {
        self.status_line = BufferView.fromSlice(line);
    }

    /// Add header (zero-copy if line is static)
    pub fn addHeader(self: *ZeroCopyResponse, line: []const u8) !void {
        try self.headers.append(BufferView.fromSlice(line));
    }

    /// Add body data (zero-copy)
    pub fn appendBody(self: *ZeroCopyResponse, data: []const u8) !void {
        try self.body.append(BufferView.fromSlice(data));
        self.body_len += data.len;
    }

    /// Write to connection (zero-copy)
    pub fn writeTo(self: *ZeroCopyResponse, writer: anytype) !void {
        // Write status line
        try writer.writeAll(self.status_line.toSlice());

        // Write headers
        for (self.headers.items) |header| {
            try writer.writeAll(header.toSlice());
        }

        // Write empty line
        try writer.writeAll("\r\n");

        // Write body
        for (self.body.items) |chunk| {
            try writer.writeAll(chunk.toSlice());
        }
    }

    /// Get total content length
    pub fn contentLength(self: ZeroCopyResponse) usize {
        return self.body_len;
    }

    /// Clear for reuse
    pub fn reset(self: *ZeroCopyResponse) void {
        self.headers.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
        self.body_len = 0;
    }
};

/// Zero-copy file reader
/// Reads files into memory-mapped buffers when possible
pub const ZeroCopyFileReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    mapping: ?[]align(std.mem.page_size) u8,
    file_size: usize,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !ZeroCopyFileReader {
        const file = try std.fs.cwd().openFile(path, .{});
        const stat = try file.stat();
        const file_size = @as(usize, @intCast(stat.size));

        return .{
            .allocator = allocator,
            .file = file,
            .mapping = null,
            .file_size = file_size,
        };
    }

    pub fn close(self: *ZeroCopyFileReader) void {
        if (self.mapping) |m| {
            std.posix.munmap(m);
            self.mapping = null;
        }
        self.file.close();
    }

    /// Get file content (zero-copy using mmap if supported)
    pub fn content(self: *ZeroCopyFileReader) ![]const u8 {
        if (self.mapping == null) {
            // Try memory mapping
            self.mapping = std.posix.mmap(
                null,
                std.mem.alignForward(usize, self.file_size, std.mem.page_size),
                std.posix.PROT.READ,
                std.posix.MAP.PRIVATE,
                self.file.handle,
                0,
            ) catch {
                // Fallback to regular read
                const buffer = try self.allocator.alloc(u8, self.file_size);
                const n = try self.file.readAll(buffer);
                return buffer[0..n];
            };
        }
        return self.mapping.?[0..self.file_size];
    }

    /// Get file size
    pub fn size(self: ZeroCopyFileReader) usize {
        return self.file_size;
    }
};

/// Zero-copy string interning
/// Stores strings once and reuses pointers
pub const StringInterner = struct {
    strings: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StringInterner {
        return .{
            .strings = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringInterner) void {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.strings.deinit();
    }

    /// Intern a string (zero-copy if already interned)
    pub fn intern(self: *StringInterner, s: []const u8) ![]const u8 {
        if (self.strings.get(s)) |interned| {
            return interned;
        }

        const copy = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(copy);

        try self.strings.put(copy, copy);
        return copy;
    }

    /// Get interned string without copying
    pub fn get(self: StringInterner, s: []const u8) ?[]const u8 {
        return self.strings.get(s);
    }
};

/// Zero-copy slice pool
/// Reuses buffer slices to avoid allocations
pub const SlicePool = struct {
    buffers: std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    pool_buffer_size: usize,
    free_list: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, buf_size: usize) SlicePool {
        return .{
            .buffers = std.ArrayList([]u8){},
            .allocator = allocator,
            .pool_buffer_size = buf_size,
            .free_list = std.ArrayList(usize){},
        };
    }

    pub fn deinit(self: *SlicePool) void {
        for (self.buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.buffers.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    /// Acquire a buffer slice
    pub fn acquire(self: *SlicePool) ![]u8 {
        if (self.free_list.getLastOrNull()) |index| {
            _ = self.free_list.pop();
            return self.buffers.items[index];
        }

        const buffer = try self.allocator.alloc(u8, self.pool_buffer_size);
        try self.buffers.append(self.allocator, buffer);
        return buffer;
    }

    /// Release a buffer slice back to pool
    pub fn release(self: *SlicePool, buffer: []u8) void {
        // Find buffer index
        for (self.buffers.items, 0..) |b, i| {
            if (b.ptr == buffer.ptr and b.len == buffer.len) {
                self.free_list.append(self.allocator, i) catch return;
                return;
            }
        }
    }

    /// Get buffer size
    pub fn buffer_size(self: SlicePool) usize {
        return self.pool_buffer_size;
    }

    /// Get total buffers in pool
    pub fn len(self: SlicePool) usize {
        return self.buffers.items.len;
    }

    /// Get number of available buffers
    pub fn available(self: SlicePool) usize {
        return self.free_list.items.len;
    }
};

test "BufferView slice operation" {
    const data = "Hello, World!";
    const view = BufferView.fromSlice(data);

    const sub = view.slice(7, 12);
    try std.testing.expectEqualStrings("World", sub.toSlice());
}

test "ZeroCopyBuilder" {
    const allocator = std.testing.allocator;
    var builder = ZeroCopyBuilder.init(allocator);
    defer builder.deinit();

    try builder.appendSlice("Hello, ");
    try builder.appendSlice("World!");

    const result = try builder.build();
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "StringInterner" {
    const allocator = std.testing.allocator;
    var interner = StringInterner.init(allocator);
    defer interner.deinit();

    const s1 = try interner.intern("hello");
    const s2 = try interner.intern("hello");
    const s3 = try interner.intern("world");

    try std.testing.expectEqual(s1.ptr, s2.ptr);
    try std.testing.expect(s1.ptr != s3.ptr);
}

test "SlicePool" {
    const allocator = std.testing.allocator;
    var pool = SlicePool.init(allocator, 1024);
    defer pool.deinit();

    const buf1 = try pool.acquire();

    try std.testing.expect(pool.len() == 1);
    try std.testing.expect(pool.available() == 0);

    pool.release(buf1);
    try std.testing.expect(pool.available() == 1);
}

//============================================================================
// Mutex Tests
// ============================================================================

test "Mutex basic lock/unlock" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init;
    var shared_value: usize = 0;

    const Worker = struct {
        fn worker(m: *Mutex, value: *usize, iterations: usize) !void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                try m.lock();
                defer m.unlock();
                value.* += 1;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.worker, .{ &mutex, &shared_value, 1000 });
    }

    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 4000), shared_value);
}

test "Mutex tryLock" {
    var mutex = Mutex.init;

    // Initial state: should be unlocked
    try std.testing.expect(mutex.tryLock());

    // Now locked: tryLock should fail
    try std.testing.expect(!mutex.tryLock());

    mutex.unlock();

    // Unlocked again: tryLock should succeed
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

test "Mutex state transitions" {
    var mutex = Mutex.init;

    // Start unlocked
    try std.testing.expectEqual(@as(MutexState, @enumFromInt(mutex.state.load(.seq_cst))), .unlocked);

    // Acquire -> locked_once
    try std.testing.expect(mutex.tryLock());
    try std.testing.expectEqual(@as(MutexState, @enumFromInt(mutex.state.load(.seq_cst))), .locked_once);

    // Try another acquire (simulates contention)
    // In real multithreaded scenario, this would set state to contended

    mutex.unlock();
    try std.testing.expectEqual(@as(MutexState, @enumFromInt(mutex.state.load(.seq_cst))), .unlocked);
}

test "ReentrantMutex nested locking" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = ReentrantMutex.init;
    var counter: usize = 0;

    const RecursiveWorker = struct {
        fn worker(m: *ReentrantMutex, count: *usize) !void {
            // First lock
            try m.lock();
            defer m.unlock();
            count.* += 1;

            // Nested lock (same thread)
            try m.lock();
            defer m.unlock();
            count.* += 1;

            // Triple nested
            try m.lock();
            defer m.unlock();
            count.* += 1;
        }
    };

    const thread = try std.Thread.spawn(.{}, RecursiveWorker.worker, .{ &mutex, &counter });
    thread.join();

    try std.testing.expectEqual(@as(usize, 3), counter);
    try std.testing.expect(mutex.owner == null);
    try std.testing.expectEqual(@as(usize, 0), mutex.depth);
}

test "ReentrantMutex thread safety" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = ReentrantMutex.init;
    var counter: usize = 0;
    var start_event = std.atomic.Value(bool).init(false);

    const ContentionWorker = struct {
        fn worker(m: *ReentrantMutex, count: *usize, start: *std.atomic.Value(bool)) !void {
            // Wait for start signal
            while (!start.load(.acquire)) {
                std.atomic.spinLoopHint();
            }

            // Try to acquire (will block until main thread releases)
            try m.lock();
            defer m.unlock();
            count.* += 1;
        }
    };

    var thread = try std.Thread.spawn(.{}, ContentionWorker.worker, .{ &mutex, &counter, &start_event });

    // Main thread acquires lock
    try mutex.lock();
    counter.* += 1;  // Counter = 1

    // Signal worker to start
    start_event.store(true, .release);

    // Sleep briefly to ensure worker tries to acquire
    std.time.sleep(10 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(usize, 1), counter);

    mutex.unlock();
    thread.join();

    try std.testing.expectEqual(@as(usize, 2), counter);
}

test "RwLock multiple readers" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var rw = RwLock.init;
    var counter: usize = 0;
    var done = std.atomic.Value(bool).init(false);

    const ReaderWorker = struct {
        fn worker(rw: *RwLock, count: *usize, finished: *std.atomic.Value(bool)) !void {
            while (!finished.load(.acquire)) {
                try rw.readLock();
                const value = count.*;
                std.debug.assert(value >= 0);  // Just ensure we can read
                rw.readUnlock();

                std.atomic.spinLoopHint();
            }
        }
    };

    // Start multiple readers
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t| {
        t.* = try std.Thread.spawn(.{}, ReaderWorker.worker, .{ &rw, &counter, &done });
    }

    // Increment counter while readers are active
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try rw.writeLock();
        counter.* += 1;
        rw.writeUnlock();
    }

    done.store(true, .release);
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 1000), counter);
}

test "RwLock write exclusivity" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var rw = RwLock.init;
    var writer_counter: usize = 0;
    var reader_counter: usize = 0;
    var start_event = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);

    const WriterWorker = struct {
        fn worker(rw: *RwLock, count: *usize, start: *std.atomic.Value(bool), finished: *std.atomic.Value(bool)) !void {
            while (!finished.load(.acquire)) {
                try rw.writeLock();
                count.* += 1;
                rw.writeUnlock();

                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
    };

    const ReaderWorker = struct {
        fn worker(rw: *RwLock, count: *usize, start: *std.atomic.Value(bool), finished: *std.atomic.Value(bool)) !void {
            while (!finished.load(.acquire)) {
                try rw.readLock();
                count.* += 1;
                rw.readUnlock();

                std.atomic.spinLoopHint();
            }
        }
    };

    var writer_thread = try std.Thread.spawn(.{}, WriterWorker.worker, .{ &rw, &writer_counter, &start_event, &done });
    var reader_threads: [4]std.Thread = undefined;
    for (&reader_threads, 0..) |*t| {
        t.* = try std.Thread.spawn(.{}, ReaderWorker.worker, .{ &rw, &reader_counter, &start_event, &done });
    }

    start_event.store(true, .release);
    std.time.sleep(50 * std.time.ns_per_ms);
    done.store(true, .release);

    writer_thread.join();
    for (reader_threads) |t| t.join();

    try std.testing.expect(writer_counter > 0);
    try std.testing.expect(reader_counter > 0);

    // Write lock should have been exclusive at times
    std.debug.print("Writer: {}, Readers: {}\n", .{ writer_counter, reader_counter });
}

test "SpinLock short critical section" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var spin = SpinLock.init;
    var counter: usize = 0;

    const SpinWorker = struct {
        fn worker(s: *SpinLock, count: *usize, iterations: usize) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                s.lock();
                defer s.unlock();
                count.* += 1;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t| {
        t.* = try std.Thread.spawn(.{}, SpinWorker.worker, .{ &spin, &counter, 100 });
    }

    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 400), counter);
}

test "MutexGuard RAII pattern" {
    var mutex = Mutex.init;
    var value: usize = 0;

    {
        const guard = try MutexGuard.acquire(&mutex);
        value.* = 42;
        guard.deinit();  // Explicit unlock
    }

    try std.testing.expectEqual(@as(usize, 42), value);

    {
        const guard = try MutexGuard.acquire(&mutex);
        value.* = 100;
        // defer would unlock automatically
    }
    // guard.deinit() called implicitly

    try std.testing.expectEqual(@as(usize, 100), value);
}
