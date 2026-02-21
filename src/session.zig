const std = @import("std");
const Cookie = @import("cookie.zig").Cookie;
const SameSite = @import("cookie.zig").SameSite;

/// Session data
pub const Session = struct {
    id: []const u8,
    data: std.StringHashMap([]const u8),
    created_at: i64,
    updated_at: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, session_id: []const u8) Session {
        const now = std.time.timestamp();
        return .{
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
        session.updated_at = std.time.timestamp();
    }

    pub fn remove(session: *Session, key: []const u8) void {
        if (session.data.fetchRemove(key)) |entry| {
            session.allocator.free(entry.key);
            session.allocator.free(entry.value);
            session.updated_at = std.time.timestamp();
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
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(*Session),
    mutex: std.Io.Mutex,
    cleanup_interval_ns: u64 = 300 * 1_000_000_000, // 5 minutes
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) MemorySessionStore {
        return .{
            .allocator = allocator,
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

    pub fn get(store: *MemorySessionStore, session_id: []const u8) ?*Session {
        store.mutex.lock();
        defer store.mutex.unlock();
        return store.sessions.get(session_id);
    }

    pub fn set(store: *MemorySessionStore, session: *Session) !void {
        store.mutex.lock();
        defer store.mutex.unlock();
        const session_id = try store.allocator.dupe(u8, session.id);
        try store.sessions.put(session_id, session);
    }

    pub fn destroy(store: *MemorySessionStore, session_id: []const u8) void {
        store.mutex.lock();
        defer store.mutex.unlock();
        if (store.sessions.fetchRemove(session_id)) |entry| {
            store.allocator.free(entry.key);
            entry.value.deinit();
            store.allocator.destroy(entry.value);
        }
    }

    /// Clean expired sessions
    pub fn cleanup(store: *MemorySessionStore, max_age: i64) void {
        store.mutex.lock();
        defer store.mutex.unlock();

        const now = std.time.timestamp();
        var keys = std.ArrayList([]const u8).init(store.allocator);
        defer {
            for (keys.items) |k| store.allocator.free(k);
            keys.deinit();
        }

        var it = store.sessions.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.updated_at > max_age) {
                try keys.append(entry.key_ptr.*);
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

    /// Background cleanup task
    fn cleanupTask(store: *MemorySessionStore, max_age: i64) void {
        while (store.running.load(.acquire)) {
            std.time.sleep(store.cleanup_interval_ns);
            store.cleanup(max_age);
            std.log.debug("Session cleanup completed", .{});
        }
    }
};

/// Session manager
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    store: *MemorySessionStore,
    config: SessionConfig,

    pub fn init(allocator: std.mem.Allocator, store: *MemorySessionStore, config: SessionConfig) SessionManager {
        return .{
            .allocator = allocator,
            .store = store,
            .config = config,
        };
    }

    /// Generate session ID
    pub fn generateSessionId(manager: SessionManager) ![]const u8 {
        // Generate random 32-byte session ID
        var bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        var session_id = std.ArrayList(u8).init(manager.allocator, {});
        try session_id.ensureCapacity(64);

        var buf: [64]u8 = undefined;
        const hex = try std.fmt.bufPrintZ(&buf, "{s}", .{std.fmt.fmtSliceHexLower(&bytes)});
        try session_id.appendSlice(hex);

        return session_id.toOwnedSlice();
    }

    /// Get or create session
    pub fn get(manager: *SessionManager, session_id: ?[]const u8) !*Session {
        if (session_id) |sid| {
            if (manager.store.get(sid)) |session| {
                return session;
            }
        }

        // Create new session
        const new_id = try manager.generateSessionId();
        const id_copy = try manager.allocator.dupe(u8, new_id);
        manager.allocator.free(new_id);

        const session = try manager.allocator.create(Session);
        session.* = Session.init(manager.allocator, id_copy);
        try manager.store.set(session);

        return session;
    }

    /// Save session
    pub fn save(manager: SessionManager, session: *Session) !void {
        try manager.store.set(session);
    }

    /// Destroy session
    pub fn destroy(manager: *SessionManager, session_id: []const u8) void {
        manager.store.destroy(session_id);
    }

    /// Create session cookie
    pub fn createCookie(manager: SessionManager, session_id: []const u8) !Cookie {
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
    var store = MemorySessionStore.init(allocator);
    defer store.deinit();

    var session = Session.init(allocator, "test123");
    defer session.deinit();

    try session.set("user", "john");
    try session.set("role", "admin");

    try store.set(&session);

    const retrieved = store.get("test123").?;
    defer retrieved.deinit();

    try std.testing.expectEqualStrings("john", retrieved.get("user").?);
    try std.testing.expectEqualStrings("admin", retrieved.get("role").?);
}

/// File-based session store for persistence
pub const FileSessionStore = struct {
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    in_memory_store: MemorySessionStore,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !FileSessionStore {
        const dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
        return .{
            .dir = dir,
            .allocator = allocator,
            .in_memory_store = MemorySessionStore.init(allocator),
        };
    }

    pub fn deinit(store: *FileSessionStore) void {
        store.in_memory_store.deinit();
        store.dir.close();
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

        const writer = file.writer();

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
        defer file.close();

        const stat = file.stat() catch return null;
        const content = store.allocator.alloc(u8, @intCast(stat.size)) catch return null;
        defer store.allocator.free(content);

        _ = file.readAll(content) catch return null;

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
