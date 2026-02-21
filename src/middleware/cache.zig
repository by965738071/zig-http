const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;
const Io = std.Io;

/// Cache entry with expiration
const CacheEntry = struct {
    data: []const u8,
    content_type: []const u8,
    expires_at_ns: i64,
    created_at_ns: i64,
    hit_count: usize,
};

/// Simple in-memory cache middleware
pub const CacheMiddleware = struct {
    cache: std.StringHashMap(*CacheEntry),
    mutex: std.Io.Mutex,
    ttl_ns: u64, // Time-to-live in nanoseconds
    max_entries: usize,
    max_entry_size: usize,

    /// Cache configuration
    pub const Config = struct {
        ttl_seconds: u64 = 300, // 5 minutes default
        max_entries: usize = 1000,
        max_entry_size: usize = 10 * 1024 * 1024, // 10MB
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) CacheMiddleware {
        return .{
            .cache = std.StringHashMap(*CacheEntry).init(allocator),
            .mutex = std.Io.Mutex.init,
            .ttl_ns = config.ttl_seconds * 1_000_000_000,
            .max_entries = config.max_entries,
            .max_entry_size = config.max_entry_size,
        };
    }

    pub fn deinit(self: *CacheMiddleware, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            const cache_entry = entry.value_ptr.*;
            allocator.free(cache_entry.data);
            allocator.free(cache_entry.content_type);
            allocator.destroy(cache_entry);
        }
        self.cache.deinit();
    }

    pub fn process(self: *CacheMiddleware, ctx: *Context, io: std.Io) !Middleware.NextAction {
        // Only cache GET requests
        if (!std.mem.eql(u8, ctx.method, "GET")) {
            return .@"continue";
        }

        // Check for cache hit
        if (self.getFromCache(ctx)) |data| {
            try ctx.setHeader("X-Cache", "HIT");
            try ctx.setHeader("Content-Type", data.content_type);
            try ctx.write(data.data);
            return .respond;
        }

        // Set cache miss header
        try ctx.setHeader("X-Cache", "MISS");

        return .@"continue";
    }

    fn getFromCache(self: *CacheMiddleware, ctx: *Context) ?*const CacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ns = std.time.nanoTimestamp();

        // Get entry from cache
        const entry = self.cache.get(ctx.path) orelse return null;

        // Check if entry has expired
        if (now_ns > entry.expires_at_ns) {
            // Remove expired entry
            self.cache.remove(ctx.path);
            self.freeEntry(ctx.allocator, entry);
            return null;
        }

        // Update hit count
        entry.hit_count += 1;

        return entry;
    }

    pub fn storeInCache(self: *CacheMiddleware, allocator: std.mem.Allocator, path: []const u8, data: []const u8, content_type: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if entry size exceeds maximum
        if (data.len > self.max_entry_size) {
            return;
        }

        // Evict entries if cache is full
        if (self.cache.count() >= self.max_entries) {
            self.evictOldest(allocator);
        }

        // Create cache entry
        const entry = try allocator.create(CacheEntry);
        const now_ns = std.time.nanoTimestamp();

        entry.* = .{
            .data = try allocator.dupe(u8, data),
            .content_type = try allocator.dupe(u8, content_type),
            .expires_at_ns = now_ns + @as(i64, @intCast(self.ttl_ns)),
            .created_at_ns = now_ns,
            .hit_count = 0,
        };

        // Store in cache (replace existing if present)
        const gop = try self.cache.getOrPut(path);
        if (gop.found_existing) {
            // Free old entry
            const old_entry = gop.value_ptr.*;
            self.freeEntry(allocator, old_entry);
        } else {
            // Duplicate path key
            gop.key_ptr.* = try allocator.dupe(u8, path);
        }
        gop.value_ptr.* = entry;

        std.log.debug("Cached: {s} ({d} bytes, TTL: {d}s)", .{
            path,
            data.len,
            @divTrunc(self.ttl_ns, 1_000_000_000),
        });
    }

    fn evictOldest(self: *CacheMiddleware, allocator: std.mem.Allocator) void {
        var oldest_entry: ?*const CacheEntry = null;
        var oldest_key: ?[]const u8 = null;

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (oldest_entry == null or entry.value_ptr.*.created_at_ns < oldest_entry.?.created_at_ns) {
                oldest_entry = entry.value_ptr.*;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_entry) |entry| {
            if (oldest_key) |key| {
                self.cache.remove(key);
                self.freeEntry(allocator, entry);
                std.log.debug("Evicted oldest cache entry: {s}", .{key});
            }
        }
    }

    fn freeEntry(self: *CacheMiddleware, allocator: std.mem.Allocator, entry: *CacheEntry) void {
        allocator.free(entry.data);
        allocator.free(entry.content_type);
        allocator.destroy(entry);
    }

    pub fn clearExpired(self: *CacheMiddleware, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ns = std.time.nanoTimestamp();
        var keys_to_remove = std.ArrayList([]const u8).init(allocator);
        defer keys_to_remove.deinit();

        // Find expired entries
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (now_ns > entry.value_ptr.*.expires_at_ns) {
                keys_to_remove.append(entry.key_ptr.*) catch {};
            }
        }

        // Remove expired entries
        for (keys_to_remove.items) |key| {
            const entry = self.cache.get(key).?;
            self.cache.remove(key);
            self.freeEntry(allocator, entry);
            allocator.free(key);
        }

        if (keys_to_remove.items.len > 0) {
            std.log.debug("Cleared {d} expired cache entries", .{keys_to_remove.items.len});
        }
    }

    pub fn getStats(self: *CacheMiddleware) struct {
        size: usize,
        total_hits: usize,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total_hits: usize = 0;
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            total_hits += entry.value_ptr.*.hit_count;
        }

        return .{
            .size = self.cache.count(),
            .total_hits = total_hits,
        };
    }
};
