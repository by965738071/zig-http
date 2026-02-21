const std = @import("std");

// Counter for generating sequential IDs
var request_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Generate a unique request ID
pub fn generateRequestId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    _ = io; // Reserved for future use
    const counter = request_counter.fetchAdd(1, .monotonic);
    // Simple ID based on counter
    return std.fmt.allocPrint(allocator, "req-{d:0>10}", .{counter});
}

/// Generate a short random ID (8 chars)
pub fn generateShortId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    _ = io; // Reserved for future use
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var buf: [8]u8 = undefined;
    const counter = request_counter.fetchAdd(1, .monotonic);
    var rng = std.Random.DefaultPrng.init(counter);
    const random = rng.random();

    for (0..8) |i| {
        buf[i] = chars[random.uintLessThan(usize, chars.len)];
    }

    return allocator.dupe(u8, &buf);
}

/// Validate URL path for directory traversal attacks
pub fn isPathSafe(path: []const u8) bool {
    // Check for ../ patterns
    if (std.mem.indexOf(u8, path, "..")) |_| {
        return false;
    }

    // Check for absolute paths
    if (path.len > 0 and path[0] == '/') {
        return false;
    }

    return true;
}

/// Validate filename for security
pub fn isFilenameSafe(filename: []const u8) bool {
    if (filename.len == 0) return false;

    // Check for path separators
    if (std.mem.indexOf(u8, filename, "/") != null) return false;
    if (std.mem.indexOf(u8, filename, "\\") != null) return false;

    // Check for dangerous patterns
    if (std.mem.indexOf(u8, filename, "..") != null) return false;

    // Check for null bytes
    if (std.mem.indexOfScalar(u8, filename, 0) != null) return false;

    return true;
}

/// Sanitize string for logging (remove sensitive data)
pub fn sanitizeForLog(input: []const u8) []const u8 {
    // Simple implementation: return as-is
    // Could be extended to mask passwords, tokens, etc.
    return input;
}

/// Validate HTTP method
pub fn isValidMethod(method: []const u8) bool {
    const valid_methods = [_][]const u8{
        "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD", "TRACE", "CONNECT",
    };

    for (valid_methods) |valid| {
        if (std.ascii.eqlIgnoreCase(method, valid)) {
            return true;
        }
    }

    return false;
}

/// Validate HTTP header name
pub fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;

    // Header names must start with a letter
    if (!std.ascii.isAlpha(name[0])) return false;

    // Header names can contain letters, digits, and hyphens
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') {
            return false;
        }
    }

    return true;
}

/// Validate HTTP header value
pub fn isValidHeaderValue(value: []const u8) bool {
    // Header values can contain most printable characters
    // but shouldn't contain control characters
    for (value) |c| {
        if (c < 32 and c != '\t') {
            return false;
        }
    }

    return true;
}

/// Validate URL encoding
pub fn isUrlEncoded(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%') {
            // Must have at least 2 more characters for hex
            if (i + 2 >= input.len) return false;

            // Check hex characters
            if (!std.ascii.isHexDigit(input[i + 1])) return false;
            if (!std.ascii.isHexDigit(input[i + 2])) return false;

            i += 3;
        } else if (std.ascii.isAlphanumeric(input[i]) or input[i] == '-' or input[i] == '_' or input[i] == '.' or input[i] == '~') {
            i += 1;
        } else {
            return false;
        }
    }

    return true;
}

/// Check for SQL injection patterns (basic check)
pub fn containsSqlInjection(input: []const u8) bool {
    const patterns = [_][]const u8{
        "' OR '",
        "' UNION ",
        "DROP ",
        "DELETE ",
        "INSERT ",
        "UPDATE ",
        "SELECT ",
        "exec(",
        "eval(",
        "script:",
        "javascript:",
    };

    const lower = try std.ascii.allocLowerString(std.heap.page_allocator, input);
    defer std.heap.page_allocator.free(lower);

    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern)) |_| {
            return true;
        }
    }

    return false;
}

/// Check for XSS patterns (basic check)
pub fn containsXss(input: []const u8) bool {
    const patterns = [_][]const u8{
        "<script",
        "javascript:",
        "onload=",
        "onerror=",
        "onclick=",
        "onmouseover=",
        "onfocus=",
        "onblur=",
        "<iframe",
        "<object",
        "<embed",
    };

    const lower = try std.ascii.allocLowerString(std.heap.page_allocator, input);
    defer std.heap.page_allocator.free(lower);

    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern)) |_| {
            return true;
        }
    }

    return false;
}

/// Sanitize HTML to prevent XSS
pub fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (input) |c| {
        switch (c) {
            '<' => try result.appendSlice("&lt;"),
            '>' => try result.appendSlice("&gt;"),
            '&' => try result.appendSlice("&amp;"),
            '"' => try result.appendSlice("&quot;"),
            '\'' => try result.appendSlice("&apos;"),
            else => try result.append(c),
        }
    }

    return result.toOwnedSlice();
}
