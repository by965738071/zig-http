const std = @import("std");
const http = std.http;
const fs = std.fs;
const mem = std.mem;
const Io = std.Io;
const Context = @import("context.zig").Context;
/// Static file server configuration
pub const StaticConfig = struct {
    /// Root directory for static files
    root: []const u8,
    /// Prefix for URL (e.g., "/static")
    prefix: []const u8 = "",
    /// Enable directory listing
    enable_directory_listing: bool = false,
    /// Enable caching headers
    enable_cache: bool = true,
    /// Custom index file names (default: ["index.html", "index.htm"])
    index_files: []const []const u8 = &.{ "index.html", "index.htm" },
    /// Maximum file size to serve
    max_file_size: u64 = std.math.maxInt(u64),
};

/// Static file server
pub const StaticServer = struct {
    allocator: std.mem.Allocator,
    config: StaticConfig,
    mime_types: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, config: StaticConfig) !StaticServer {
        var mime_types = std.StringHashMap([]const u8).init(allocator);

        // Initialize common MIME types
        try initMimeTypes(&mime_types);

        return .{
            .allocator = allocator,
            .config = config,
            .mime_types = mime_types,
        };
    }

    pub fn deinit(server: *StaticServer) void {
        server.mime_types.deinit();
    }

    /// Initialize common MIME type mappings
    fn initMimeTypes(map: *std.StringHashMap([]const u8)) !void {
        const extensions = [_][]const u8{
            ".html",        "text/html; charset=utf-8",
            ".htm",         "text/html; charset=utf-8",
            ".css",         "text/css; charset=utf-8",
            ".js",          "application/javascript; charset=utf-8",
            ".mjs",         "application/javascript; charset=utf-8",
            ".json",        "application/json; charset=utf-8",
            ".xml",         "application/xml; charset=utf-8",
            ".png",         "image/png",
            ".jpg",         "image/jpeg",
            ".jpeg",        "image/jpeg",
            ".gif",         "image/gif",
            ".svg",         "image/svg+xml",
            ".ico",         "image/x-icon",
            ".webp",        "image/webp",
            ".pdf",         "application/pdf",
            ".zip",         "application/zip",
            ".gz",          "application/gzip",
            ".txt",         "text/plain; charset=utf-8",
            ".md",          "text/markdown; charset=utf-8",
            ".markdown",    "text/markdown; charset=utf-8",
            ".woff",        "font/woff",
            ".woff2",       "font/woff2",
            ".ttf",         "font/ttf",
            ".eot",         "application/vnd.ms-fontobject",
            ".mp4",         "video/mp4",
            ".webm",        "video/webm",
            ".mp3",         "audio/mpeg",
            ".wav",         "audio/wav",
            ".ogg",         "audio/ogg",
            ".wasm",        "application/wasm",
            ".webmanifest", "application/manifest+json",
        };

        inline for (extensions) |item| {
            const eq = std.mem.indexOfScalar(u8, item, ',');
            const ext = if (eq) |e| item[0..e] else item;
            const mime = if (eq) |e| item[e + 2 ..] else item;
            try map.put(ext, mime);
        }
    }

    /// Get MIME type for a file extension
    pub fn getMimeType(server: *StaticServer, path: []const u8) []const u8 {
        const ext = getExtension(path);
        return server.mime_types.get(ext) orelse "application/octet-stream";
    }

    /// Get file extension
    fn getExtension(path: []const u8) []const u8 {
        const last_dot = mem.lastIndexOfScalar(u8, path, '.');
        return if (last_dot) |idx| path[idx + 1 ..] else "";
    }

    /// Resolve safe file path (prevent directory traversal)
    pub fn resolvePath(server: *StaticServer, url_path: []const u8) ![]const u8 {
        var resolved = std.ArrayListUnmanaged(u8){};
        errdefer resolved.deinit(server.allocator);

        var it = mem.splitScalar(u8, url_path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0 or segment.len == 1 and segment[0] == '.') {
                // Skip empty segments and dot segments (security)
                continue;
            }
            if (mem.eql(u8, segment, "..")) {
                return error.PathTraversalDetected;
            }
            try resolved.append(server.allocator, '/');
            try resolved.appendSlice(server.allocator, segment);
        }

        // Prepend root directory
        const full_path = try std.fs.path.join(
            server.allocator,
            &.{ server.config.root, resolved.items },
        );
        return full_path;
    }

    /// Serve a static file
    pub fn serveFile(server: *StaticServer, ctx: *Context, file_path: []const u8) !bool {
        _ = @typeInfo(@TypeOf(ctx.response));

        // Open file - use new API with io
        const file = try std.Io.Dir.cwd().openFile(ctx.io, file_path, .{});
        defer file.close(ctx.io);

        const stat = try file.stat(ctx.io);
        const size = stat.size;

        // Check file size limit
        if (size > server.config.max_file_size) {
            ctx.response.setStatus(http.Status.payload_too_large);
            try ctx.text("File too large");
            return false;
        }

        // Get MIME type
        const mime = server.getMimeType(file_path);

        // Set headers
        if (server.config.enable_cache) {
            try ctx.response.setHeader("Cache-Control", "public, max-age=3600");
            try ctx.response.setHeader("ETag", try generateETag(file, stat));
        }

        try ctx.response.setHeader("Content-Type", mime);
        try ctx.response.setHeader("Accept-Ranges", "bytes");

        // Check for Range header
        const range_header = ctx.getHeader("Range");
        if (range_header) |range_str| {
            if (try handleRangeRequest(ctx, file, size, range_str)) {
                return true;
            }
        }

        // Read and send file using Io.File.Reader
        var buffer: [65536]u8 = undefined; // 64KB buffer
        var bytes_read: u64 = 0;
        while (bytes_read < size) {
            const to_read = @min(buffer.len, size - bytes_read);
            var read_buf = [_][]u8{buffer[0..to_read]};
            const n = try std.Io.File.readStreaming(file, ctx.io, &read_buf);
            //const n = try ctx.io.vtable.fileReadStreaming(ctx.io.userdata, file, &read_buf);
            try ctx.response.writeAll(buffer[0..n]);
            bytes_read += n;
        }

        return true;
    }

    /// Handle Range request for partial content
    fn handleRangeRequest(ctx: anytype, file: std.Io.File, size: u64, range_str: []const u8) !bool {
        _ = file;

        // Parse "bytes=start-end" format
        if (!mem.startsWith(u8, range_str, "bytes=")) return false;

        const range_spec = range_str["bytes=".len..];

        const dash_idx = mem.indexOfScalar(u8, range_spec, '-');
        if (dash_idx == null) return false;

        const start_str = range_spec[0..dash_idx.?];
        const end_str = if (dash_idx.? + 1 < range_spec.len) range_spec[dash_idx.? + 1 ..] else "";

        const start = std.fmt.parseInt(u64, start_str, 10) catch return false;
        const parsed_end = if (end_str.len > 0) std.fmt.parseInt(u64, end_str, 10) catch null else null;
        var end = parsed_end orelse size - 1;

        // Validate range
        if (start >= size) {
            ctx.response.setStatus(http.Status.range_not_satisfiable);
            try ctx.text("Invalid range");
            return false;
        }

        if (end >= size) end = size - 1;

        // TODO: Range support requires seek capability which may not be available in std.Io.File
        // For now, we'll serve the entire file instead of partial content
        // This is a temporary workaround for Zig 0.16-dev API changes
        return false;
    }

    /// Generate ETag for file
    fn generateETag(file: std.Io.File, stat: std.Io.File.Stat) ![]const u8 {
        // Simple ETag based on size and mtime
        _ = file;
        const etag = try std.fmt.allocPrint(std.heap.page_allocator, "\"{x}-{x}\"", .{ stat.mtime, stat.size });
        return etag;
    }

    /// Serve directory listing
    pub fn serveDirectory(server: *StaticServer, ctx: anytype, dir_path: []const u8) !bool {
        _ = @typeInfo(@TypeOf(ctx.response));
        _ = ctx.response.writer;

        const dir = try std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{});
        defer dir.close(ctx.io);

        try ctx.html("<!DOCTYPE html>\n<html><head><title>Directory Listing</title></head>\n<body>\n");

        try ctx.html("<h1>Index of ");
        try ctx.text(dir_path);
        try ctx.html("</h1>\n<ul>\n");

        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            const name = entry.name;
            const is_dir = entry.kind == .directory;

            const suffix = if (is_dir) "/" else "";
            const item = try std.fmt.allocPrint(server.allocator, "<li><a href=\"{s}{s}\">{s}{s}</a></li>\n", .{ name, suffix, name, suffix });
            try ctx.response.writeAll(item);
        }

        try ctx.html("</ul>\n</body></html>\n");
        return true;
    }

    /// Handle static file request
    pub fn handle(server: *StaticServer, ctx: *Context) !bool {
        // Remove prefix from URL path
        const url_path = if (server.config.prefix.len > 0 and
            mem.startsWith(u8, ctx.request.head.target, server.config.prefix))
            ctx.request.head.target[server.config.prefix.len..]
        else
            ctx.request.head.target;

        // Resolve safe file path
        const file_path = resolvePath(server, url_path) catch {
            ctx.response.setStatus(http.Status.bad_request);
            try ctx.text("Invalid path");
            return false;
        };

        // Check if path exists - use new API with io
        std.Io.Dir.cwd().access(ctx.io, file_path, .{}) catch {
            ctx.response.setStatus(http.Status.not_found);
            try ctx.text("File not found");
            return false;
        };

        // Get file info - use new API with io
        const file_info = std.Io.Dir.cwd().statFile(ctx.io, file_path, .{}) catch {
            ctx.response.setStatus(http.Status.not_found);
            try ctx.text("File not found");
            return false;
        };

        // Serve directory or file
        switch (file_info.kind) {
            .directory => {
                if (server.config.enable_directory_listing) {
                    return try serveDirectory(server, ctx, file_path);
                }

                // Try to serve index file
                for (server.config.index_files) |index_name| {
                    const index_path = try std.fs.path.join(server.allocator, &.{ file_path, index_name });
                    std.Io.Dir.cwd().access(ctx.io, index_path, .{}) catch continue;

                    // Found index file, serve it
                    return try serveFile(server, ctx, index_path);
                }

                ctx.response.setStatus(http.Status.forbidden);
                try ctx.text("Directory listing disabled");
                return false;
            },
            .file => {
                return try serveFile(server, ctx, file_path);
            },
            else => {
                ctx.response.setStatus(http.Status.not_found);
                try ctx.text("File not found");
                return false;
            },
        }
    }
};

test "getMimeType" {
    const allocator = std.testing.allocator;
    var server = try StaticServer.init(allocator, .{ .root = "." });
    defer server.deinit();

    try std.testing.expectEqualStrings("text/html; charset=utf-8", server.getMimeType("index.html"));
    try std.testing.expectEqualStrings("image/png", server.getMimeType("image.png"));
    try std.testing.expectEqualStrings("application/json", server.getMimeType("data.json"));
}

test "resolvePath security" {
    const allocator = std.testing.allocator;
    var server = try StaticServer.init(allocator, .{ .root = "/safe" });
    defer server.deinit();

    // Should reject path traversal
    const result = server.resolvePath("../../../etc/passwd");
    try std.testing.expectError(error.PathTraversalDetected, result);

    // Should resolve normally
    const normal = try server.resolvePath("test/file.txt");
    try std.testing.expectEqualStrings("/safe/test/file.txt", normal);
}
