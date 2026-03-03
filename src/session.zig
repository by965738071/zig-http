const std = @import("std");
const Cookie = @import("cookie.zig").Cookie;
const SameSite = @import("cookie.zig").SameSite;

/// Session data
pub const Session = struct {
    io: std.Io,
    id: []const u8,
    data: std.StringHashMap([]const u8),
    created_at: i64,
    updated_at: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, session_id: []const u8, io: std.Io) Session {
        const now = std.Io.Timestamp.now(io, .boot).toMilliseconds();
        return .{
            .io = io,
            .id = session_id,
            .data = std.StringHashMap([]const u8).init(allocator),
            .created_at = now,
            .updated_at = now,
            .allocator = allocator,
        };
    }

    pub fn deinit(session: *Session) void {
        var it = session.data.iterator();
        while (it.next()) |entry| {
            session.allocator.free(entry.key_ptr.*);
            session.allocator.free(entry.value_ptr.*);
        }
        session.data.deinit();
    }

    pub fn get(session: Session, key: []const u8) ?[]const u8 {
        return session.data.get(key);
    }

    pub fn set(session: *Session, key: []const u8, value: []const u8) !void {
        const key_copy = try session.allocator.dupe(u8, key);
        const value_copy = try session.allocator.dupe(u8, value);
        try session.data.put(key_copy, value_copy);
        session.updated_at = std.Io.Timestamp.now(session.io, .boot).toMilliseconds();
    }

    pub fn remove(session: *Session, key: []const u8) void {
        if (session.data.fetchRemove(key)) |entry| {
            session.allocator.free(entry.key);
            session.allocator.free(entry.value);
            session.updated_at = std.time.milliTimestamp();
        }
    }

    pub fn has(session: Session, key: []const u8) bool {
        return session.data.get(key) != null;
    }
};

/// Session configuration
pub const SessionConfig = struct {
    cookie_name: []const u8 = "session_id",
    max_age: i64 = 3600, // 1 hour
    secret: []const u8,
    secure: bool = false,
    http_only: bool = true,
    same_site: SameSite = .lax,
};

/// In-memory session store
pub const MemorySessionStore = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(*Session),
    mutex: std.Io.Mutex,
    cleanup_interval_ns: u64 = 300 * 1_000_000_000, // 5 minutes
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MemorySessionStore {
        return .{
            .allocator = allocator,
            .io = io,
            .sessions = std.StringHashMap(*Session).init(allocator),
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(store: *MemorySessionStore) void {
        var it = store.sessions.iterator();
        while (it.next()) |entry| {
            store.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            store.allocator.destroy(entry.value_ptr);
        }
        store.sessions.deinit();
    }

    pub fn get(store: *MemorySessionStore, session_id: []const u8, io: std.Io) ?*Session {
        store.mutex.lockUncancelable(io);
        defer store.mutex.unlock(io);
        return store.sessions.get(session_id);
    }

    pub fn set(store: *MemorySessionStore, session: *Session, io: std.Io) !void {
        store.mutex.lockUncancelable(io);
        defer store.mutex.unlock(io);
        const session_id = try store.allocator.dupe(u8, session.id);
        try store.sessions.put(session_id, session);
    }

    pub fn destroy(store: *MemorySessionStore, session_id: []const u8, io: std.Io) void {
        store.mutex.lockUncancelable(io);
        defer store.mutex.unlock(io);
        if (store.sessions.fetchRemove(session_id)) |entry| {
            store.allocator.free(entry.key);
            entry.value.deinit();
            store.allocator.destroy(entry.value);
        }
    }

    /// Clean expired sessions
    pub fn cleanup(store: *MemorySessionStore, max_age: i64, io: std.Io) void {
        store.mutex.lockUncancelable(io);
        defer store.mutex.unlock(io);

        const now = std.Io.Timestamp.now(io, .boot).toMilliseconds();
        var keys = std.ArrayList([]const u8){};
        defer {
            for (keys.items) |k| store.allocator.free(k);
            keys.deinit(store.allocator);
        }

        var it = store.sessions.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.*.updated_at > max_age) {
                keys.append(store.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (keys.items) |key| {
            if (store.sessions.fetchRemove(key)) |entry| {
                store.allocator.free(entry.key);
                entry.value.deinit();
                store.allocator.destroy(entry.value);
            }
        }
    }

    /// Start periodic cleanup task
    pub fn startCleanupTask(store: *MemorySessionStore, max_age: i64) !void {
        store.running.store(true, .release);
        try std.Thread.spawn(.{}, cleanupTask, .{ store, max_age });
        std.log.info("Session cleanup task started (interval: {d}s, max_age: {d}s)", .{
            @divTrunc(store.cleanup_interval_ns, 1_000_000_000),
            max_age,
        });
    }

    /// Stop cleanup task
    pub fn stopCleanupTask(store: *MemorySessionStore) void {
        store.running.store(false, .release);
    }

    /// Background cleanup task (uses tryLock to avoid blocking without io)
    fn cleanupTask(store: *MemorySessionStore, max_age: i64) void {
        while (store.running.load(.acquire)) {
            std.time.sleep(store.cleanup_interval_ns);
            store.cleanupNonBlocking(max_age);
            std.log.debug("Session cleanup completed", .{});
        }
    }

    /// Non-blocking cleanup using tryLock (for use in background threads)
    fn cleanupNonBlocking(store: *MemorySessionStore, max_age: i64) void {
        if (!store.mutex.tryLock()) return;
        defer store.mutex.unlock(store.io); // unlock doesn't need io in practice

        const now = std.time.milliTimestamp();
        var it = store.sessions.iterator();
        var to_remove: [64][]const u8 = undefined;
        var count: usize = 0;

        while (it.next()) |entry| {
            if (now - entry.value_ptr.*.updated_at > max_age and count < to_remove.len) {
                to_remove[count] = entry.key_ptr.*;
                count += 1;
            }
        }

        for (to_remove[0..count]) |key| {
            if (store.sessions.fetchRemove(key)) |entry| {
                store.allocator.free(entry.key);
                entry.value.deinit();
                store.allocator.destroy(entry.value);
            }
        }
    }
};

/// Session manager
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *MemorySessionStore,
    config: SessionConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *MemorySessionStore, config: SessionConfig) SessionManager {
        return .{
            .io = io,
            .allocator = allocator,
            .store = store,
            .config = config,
        };
    }

    /// Generate session ID
    pub fn generateSessionId(
        manager: *SessionManager,
    ) ![]const u8 {
        var bytes: [32]u8 = undefined;
        manager.io.random(&bytes);
        var buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "{x}", .{bytes}) catch unreachable;
        return manager.allocator.dupe(u8, hex);
    }

    /// Get or create session
    pub fn get(manager: *SessionManager, session_id: ?[]const u8) !*Session {
        if (session_id) |sid| {
            if (manager.store.get(sid, manager.io)) |session| {
                return session;
            }
        }

        const id_copy = try manager.generateSessionId(manager.io);
        errdefer manager.allocator.free(id_copy);

        const session = try manager.allocator.create(Session);
        session.* = Session.init(manager.allocator, id_copy, manager.io);
        try manager.store.set(session, manager.io);

        return session;
    }

    /// Save session
    pub fn save(manager: *SessionManager, session: *Session) !void {
        try manager.store.set(session, manager.io);
    }

    /// Destroy session
    pub fn destroy(manager: *SessionManager, session_id: []const u8) void {
        manager.store.destroy(session_id, manager.io);
    }

    /// Create session cookie
    pub fn createCookie(manager: *SessionManager, session_id: []const u8) !Cookie {
        return .{
            .name = manager.config.cookie_name,
            .value = session_id,
            .options = .{
                .max_age = manager.config.max_age,
                .secure = manager.config.secure,
                .http_only = manager.config.http_only,
                .same_site = manager.config.same_site,
            },
        };
    }
};

test "memory session store" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var store = MemorySessionStore.init(allocator, io);
    defer store.deinit();

    var session = Session.init(allocator, "test123", io);
    defer session.deinit();

    try session.set("user", "john");
    try session.set("role", "admin");

    try store.set(&session, io);

    const retrieved = store.get("test123", io).?;
    defer retrieved.deinit();

    try std.testing.expectEqualStrings("john", retrieved.get("user").?);
    try std.testing.expectEqualStrings("admin", retrieved.get("role").?);
}

/// File-based session store for persistence
pub const FileSessionStore = struct {
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    io: std.Io,
    in_memory_store: MemorySessionStore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !FileSessionStore {
        const dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{});

        return .{
            .io = io,
            .dir = dir,
            .allocator = allocator,
            .in_memory_store = MemorySessionStore.init(allocator, io),
        };
    }

    pub fn deinit(store: *FileSessionStore) void {
        store.in_memory_store.deinit();
        store.dir.close(store.io);
    }

    pub fn get(store: *FileSessionStore, session_id: []const u8) ?*Session {
        // Check in-memory cache first
        if (store.in_memory_store.get(session_id)) |session| {
            return session;
        }

        // Try to load from file
        if (store.loadFromFile(session_id)) |session| {
            return session;
        }

        return null;
    }

    pub fn set(store: *FileSessionStore, session: *Session) !void {
        // Save to in-memory store
        try store.in_memory_store.set(session);

        // Persist to file
        try store.saveToFile(session);
    }

    pub fn destroy(store: *FileSessionStore, session_id: []const u8) void {
        // Remove from memory
        store.in_memory_store.destroy(session_id);

        // Remove file
        const file_path = try std.fmt.allocPrint(store.allocator, "{s}.json", .{session_id});
        defer store.allocator.free(file_path);

        store.dir.deleteFile(file_path) catch |err| {
            std.log.debug("Failed to delete session file: {}", .{err});
        };
    }

    fn saveToFile(store: *FileSessionStore, session: *Session) !void {
        const file_path = try std.fmt.allocPrint(store.allocator, "{s}.json", .{session.id});
        defer store.allocator.free(file_path);

        const file = try store.dir.createFile(file_path, .{ .read = true });
        defer file.close();

        const writer = file.writer().interface;

        try writer.print("{{", .{});
        try writer.print("\"id\":\"{s}\",", .{session.id});
        try writer.print("\"created_at\":{d},", .{session.created_at});
        try writer.print("\"updated_at\":{d},", .{session.updated_at});
        try writer.print("\"data\":{{", .{});

        var first = true;
        var it = session.data.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.print(",", .{});
            first = false;

            // Escape JSON strings
            const escaped_key = escapeJsonString(entry.key_ptr.*);
            const escaped_value = escapeJsonString(entry.value_ptr.*);
            try writer.print("\"{s}\":\"{s}\"", .{ escaped_key, escaped_value });
        }

        try writer.print("}}", .{});
        try writer.print("}}", .{});
    }

    fn loadFromFile(store: *FileSessionStore, session_id: []const u8) ?*Session {
        const file_path = try std.fmt.allocPrint(store.allocator, "{s}.json", .{session_id});
        defer store.allocator.free(file_path);

        const file = store.dir.openFile(file_path, .{}) catch |err| {
            std.log.debug("Failed to open session file: {}", .{err});
            return null;
        };
        defer file.close(store.io);

        const stat = file.stat(store.io) catch return null;
        const content = store.allocator.alloc(u8, @intCast(stat.size)) catch return null;
        defer store.allocator.free(content);

        const reader = file.reader(store.io, &content).interface;
        _ = reader.readSliceAll(&content) catch return null;
        // _ = file.readAll(content) catch return null;

        // Simple JSON parsing (in production, use proper JSON parser)
        // For now, return null to indicate parsing failed
        std.log.warn("File session parsing not fully implemented", .{});
        return null;
    }

    fn escapeJsonString(s: []const u8) []const u8 {
        // Simple JSON escape - in production, use proper escaping
        _ = s;
        return "[escaped]";
    }
};
