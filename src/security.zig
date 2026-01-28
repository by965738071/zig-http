const std = @import("std");

/// Security configuration
pub const SecurityConfig = struct {
    max_request_size: usize = 10 * 1024 * 1024, // 10MB default
    allowed_origins: ?[]const []const u8 = null, // CORS allowed origins
    trusted_proxies: ?[]const []const u8 = null, // Trusted proxy IPs
    enable_csrf: bool = false,
};

/// IP whitelist/blacklist manager
pub const IPFilter = struct {
    allocator: std.mem.Allocator,
    whitelist: std.StringHashMap(void),
    blacklist: std.StringHashMap(void),
    mode: Mode,

    pub const Mode = enum {
        none, // No filtering
        whitelist, // Only allow listed IPs
        blacklist, // Block listed IPs
    };

    pub fn init(allocator: std.mem.Allocator, mode: Mode) IPFilter {
        return .{
            .allocator = allocator,
            .whitelist = std.StringHashMap(void).init(allocator),
            .blacklist = std.StringHashMap(void).init(allocator),
            .mode = mode,
        };
    }

    pub fn deinit(filter: *IPFilter) void {
        var it = filter.whitelist.iterator();
        while (it.next()) |entry| {
            filter.allocator.free(entry.key_ptr.*);
        }
        filter.whitelist.deinit();

        it = filter.blacklist.iterator();
        while (it.next()) |entry| {
            filter.allocator.free(entry.key_ptr.*);
        }
        filter.blacklist.deinit();
    }

    /// Add IP to whitelist
    pub fn addToWhitelist(filter: *IPFilter, ip: []const u8) !void {
        const ip_copy = try filter.allocator.dupe(u8, ip);
        try filter.whitelist.put(ip_copy, {});
    }

    /// Add IP to blacklist
    pub fn addToBlacklist(filter: *IPFilter, ip: []const u8) !void {
        const ip_copy = try filter.allocator.dupe(u8, ip);
        try filter.blacklist.put(ip_copy, {});
    }

    /// Check if IP is allowed
    pub fn isAllowed(filter: IPFilter, ip: []const u8) bool {
        switch (filter.mode) {
            .none => return true,
            .whitelist => {
                // Only allow if in whitelist
                return filter.whitelist.contains(ip);
            },
            .blacklist => {
                // Allow unless in blacklist
                return !filter.blacklist.contains(ip);
            },
        }
    }
};

/// Request size limiter
pub const SizeLimiter = struct {
    max_size: usize,

    pub fn init(max_size: usize) SizeLimiter {
        return .{ .max_size = max_size };
    }

    /// Check if size is allowed
    pub fn isAllowed(limiter: SizeLimiter, size: usize) bool {
        return size <= limiter.max_size;
    }
};

/// CSRF token manager
pub const CSRFManager = struct {
    allocator: std.mem.Allocator,
    tokens: std.StringHashMap(i64),
    secret: []const u8,
    token_ttl: i64,

    pub fn init(allocator: std.mem.Allocator, secret: []const u8, token_ttl: i64) CSRFManager {
        return .{
            .allocator = allocator,
            .tokens = std.StringHashMap(i64).init(allocator),
            .secret = secret,
            .token_ttl = token_ttl,
        };
    }

    pub fn deinit(manager: *CSRFManager) void {
        var it = manager.tokens.iterator();
        while (it.next()) |entry| {
            manager.allocator.free(entry.key_ptr.*);
        }
        manager.tokens.deinit();
    }

    /// Generate CSRF token
    pub fn generateToken(manager: *CSRFManager, session_id: []const u8) ![]const u8 {
        // Simple token generation using HMAC
        var hasher = std.crypto.auth.hmac.sha2.HmacSha256.init(manager.secret);
        hasher.update(session_id);
        hasher.update(&std.mem.toBytes(std.time.timestamp()));
        const mac = hasher.finalize();

        const token = try manager.allocator.alloc(u8, mac.len * 2);
        for (mac, 0..) |byte, i| {
            const hex = "0123456789abcdef"[byte >> 4];
            token[i * 2] = hex;
            const hex2 = "0123456789abcdef"[byte & 0x0f];
            token[i * 2 + 1] = hex2;
        }

        try manager.tokens.put(token, std.time.timestamp());
        return token;
    }

    /// Validate CSRF token
    pub fn validateToken(manager: *CSRFManager, token: []const u8) bool {
        const created_at = manager.tokens.get(token) orelse return false;
        const now = std.time.timestamp();

        // Check if token expired
        if (now - created_at > manager.token_ttl) {
            _ = manager.tokens.remove(token);
            manager.allocator.free(token);
            return false;
        }

        return true;
    }

    /// Clean up expired tokens
    pub fn cleanup(manager: *CSRFManager) void {
        const now = std.time.timestamp();
        var keys = std.ArrayList([]const u8).init(manager.allocator);
        defer {
            for (keys.items) |k| manager.allocator.free(k);
            keys.deinit();
        }

        var it = manager.tokens.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.* > manager.token_ttl) {
                keys.append(entry.key_ptr.*) catch {};
            }
        }

        for (keys.items) |key| {
            if (manager.tokens.fetchRemove(key)) |entry| {
                manager.allocator.free(entry.key);
            }
        }
    }
};
