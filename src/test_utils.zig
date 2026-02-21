const std = @import("std");
const utils = @import("utils.zig");

/// Simple assertion helpers
pub const Assert = struct {
    pub fn equal(expected: anytype, actual: anytype) !void {
        if (!std.meta.eql(expected, actual)) {
            return error.AssertionFailed;
        }
    }

    pub fn isTrue(value: bool) !void {
        if (!value) {
            return error.AssertionFailed;
        }
    }

    pub fn isFalse(value: bool) !void {
        if (value) {
            return error.AssertionFailed;
        }
    }

    pub fn contains(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) == null) {
            return error.AssertionFailed;
        }
    }

    pub fn notContains(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) != null) {
            return error.AssertionFailed;
        }
    }
};

/// Test cases

pub fn testPathSafetyValidation() !void {
    try Assert.isTrue(utils.isPathSafe("valid/path"));
    try Assert.isTrue(utils.isPathSafe("another/path"));
    try Assert.isFalse(utils.isPathSafe("../escape"));
    try Assert.isFalse(utils.isPathSafe("/absolute/path"));
}

pub fn testFilenameSafetyValidation() !void {
    try Assert.isTrue(utils.isFilenameSafe("file.txt"));
    try Assert.isTrue(utils.isFilenameSafe("file-name_123.txt"));
    try Assert.isFalse(utils.isFilenameSafe("../file.txt"));
    try Assert.isFalse(utils.isFilenameSafe("file/with/slashes.txt"));
}

pub fn testHttpMethodValidation() !void {
    try Assert.isTrue(utils.isValidMethod("GET"));
    try Assert.isTrue(utils.isValidMethod("POST"));
    try Assert.isFalse(utils.isValidMethod("INVALID"));
}

pub fn testSqlInjectionDetection() !void {
    try Assert.isTrue(utils.containsSqlInjection("' OR '1'='1'"));
    try Assert.isTrue(utils.containsSqlInjection("SELECT * FROM users"));
    try Assert.isFalse(utils.containsSqlInjection("normal text"));
}

pub fn testXssDetection() !void {
    try Assert.isTrue(utils.containsXss("<script>alert('xss')</script>"));
    try Assert.isTrue(utils.containsXss("javascript:void(0)"));
    try Assert.isFalse(utils.containsXss("normal text"));
}

pub fn testHtmlEscaping() !void {
    const allocator = std.testing.allocator;
    const escaped = try utils.escapeHtml(allocator, "<script>alert('xss')</script>");
    defer allocator.free(escaped);

    try Assert.notContains(escaped, "<script>");
    try Assert.contains(escaped, "&lt;");
}
