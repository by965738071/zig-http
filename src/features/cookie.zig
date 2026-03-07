const std = @import("std");

/// Cookie options
pub const CookieOptions = struct {
    max_age: ?i64 = null,
    expires: ?i64 = null,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = "/",
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
};

/// SameSite attribute
pub const SameSite = enum {
    strict,
    lax,
    none,
};

/// Cookie struct
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    options: CookieOptions = .{},

    /// Serialize cookie to string
    pub fn toString(cookie: Cookie, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8){};
        try buffer.appendSlice(allocator, cookie.name);
        try buffer.append(allocator, '=');
        try buffer.appendSlice(allocator, cookie.value);

        if (cookie.options.max_age) |ma| {
            try buffer.appendSlice(allocator, "; Max-Age=");
            try buffer.print(allocator, "{d}", .{ma});
        }

        if (cookie.options.expires) |exp| {
            try buffer.appendSlice(allocator, "; Expires=");
            try buffer.print(allocator, "{d}", .{exp});
        }

        if (cookie.options.domain) |d| {
            try buffer.appendSlice(allocator, "; Domain=");
            try buffer.appendSlice(allocator, d);
        }

        if (cookie.options.path) |p| {
            try buffer.appendSlice(allocator, "; Path=");
            try buffer.appendSlice(allocator, p);
        }

        if (cookie.options.secure) {
            try buffer.appendSlice(allocator, "; Secure");
        }

        if (cookie.options.http_only) {
            try buffer.appendSlice(allocator, "; HttpOnly");
        }

        if (cookie.options.same_site) |ss| {
            try buffer.appendSlice(allocator, "; SameSite=");
            const ss_str = switch (ss) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            };
            try buffer.appendSlice(allocator, ss_str);
        }

        return buffer.toOwnedSlice(allocator);
    }
};

/// Cookie jar for parsing and managing cookies
pub const CookieJar = struct {
    allocator: std.mem.Allocator,
    cookies: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .allocator = allocator,
            .cookies = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(jar: *CookieJar) void {
        var it = jar.cookies.iterator();
        while (it.next()) |entry| {
            jar.allocator.free(entry.key_ptr.*);
            jar.allocator.free(entry.value_ptr.*);
        }
        jar.cookies.deinit();
    }

    /// Parse cookies from Cookie header
    pub fn parse(jar: *CookieJar, header_value: []const u8) !void {
        var it = std.mem.splitScalar(u8, header_value, ';');
        while (it.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, &std.ascii.whitespace);
            const eq = std.mem.indexOfScalar(u8, trimmed, '=');

            if (eq) |idx| {
                const name = trimmed[0..idx];
                const value = trimmed[idx + 1 ..];

                const name_copy = try jar.allocator.dupe(u8, name);
                const value_copy = try jar.allocator.dupe(u8, value);
                try jar.cookies.put(name_copy, value_copy);
            }
        }
    }

    /// Get cookie value by name
    pub fn get(jar: CookieJar, name: []const u8) ?[]const u8 {
        return jar.cookies.get(name);
    }

    /// Set cookie
    pub fn set(jar: *CookieJar, name: []const u8, value: []const u8) !void {
        const name_copy = try jar.allocator.dupe(u8, name);
        const value_copy = try jar.allocator.dupe(u8, value);
        try jar.cookies.put(name_copy, value_copy);
    }

    /// Check if cookie exists
    pub fn has(jar: CookieJar, name: []const u8) bool {
        return jar.cookies.get(name) != null;
    }

    /// Remove cookie
    pub fn remove(jar: *CookieJar, name: []const u8) void {
        if (jar.cookies.fetchRemove(name)) |entry| {
            jar.allocator.free(entry.key);
            jar.allocator.free(entry.value);
        }
    }

    /// Get all cookie names
    pub fn getNames(jar: CookieJar, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8){};
        defer names.deinit(allocator);
        var it = jar.cookies.keyIterator();
        while (it.next()) |key| {
            try names.append(allocator, try allocator.dupe(u8, key.*));
        }
        return names.toOwnedSlice(allocator);
    }
};

test "parse cookies" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    const header = "session_id=abc123; user=john; theme=dark";
    try jar.parse(header);

    try std.testing.expectEqualStrings("abc123", jar.get("session_id").?);
    try std.testing.expectEqualStrings("john", jar.get("user").?);
    try std.testing.expectEqualStrings("dark", jar.get("theme").?);
    try std.testing.expect(jar.has("session_id"));
}

test "cookie serialization" {
    const allocator = std.testing.allocator;

    const cookie = Cookie{
        .name = "session_id",
        .value = "abc123",
        .options = .{
            .max_age = 3600,
            .http_only = true,
            .secure = true,
            .same_site = .lax,
        },
    };

    const str = try cookie.toString(allocator);
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "session_id=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "Max-Age=3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "SameSite=Lax") != null);
}
