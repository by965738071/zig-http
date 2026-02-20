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
        // Explicitly insert known mappings to avoid parsing heuristics
        try map.put(".html", "text/html; charset=utf-8");
        try map.put(".htm", "text/html; charset=utf-8");
        try map.put(".css", "text/css; charset=utf-8");
        try map.put(".js", "application/javascript; charset=utf-8");
        try map.put(".mjs", "application/javascript; charset=utf-8");
        try map.put(".json", "application/json; charset=utf-8");
        try map.put(".xml", "application/xml; charset=utf-8");
        try map.put(".png", "image/png");
        try map.put(".jpg", "image/jpeg");
        try map.put(".jpeg", "image/jpeg");
        try map.put(".gif", "image/gif");
        try map.put(".svg", "image/svg+xml");
        try map.put(".ico", "image/x-icon");
        try map.put(".webp", "image/webp");
        try map.put(".pdf", "application/pdf");
        try map.put(".zip", "application/zip");
        try map.put(".gz", "application/gzip");
        try map.put(".txt", "text/plain; charset=utf-8");
        try map.put(".md", "text/markdown; charset=utf-8");
        try map.put(".markdown", "text/markdown; charset=utf-8");
        try map.put(".woff", "font/woff");
        try map.put(".woff2", "font/woff2");
        try map.put(".ttf", "font/ttf");
        try map.put(".eot", "application/vnd.ms-fontobject");
        try map.put(".mp4", "video/mp4");
        try map.put(".webm", "video/webm");
        try map.put(".mp3", "audio/mpeg");
        try map.put(".wav", "audio/wav");
        try map.put(".ogg", "audio/ogg");
        try map.put(".wasm", "application/wasm");
        try map.put(".webmanifest", "application/manifest+json");
    }

    /// Get MIME type for a file extension
    pub fn getMimeType(server: *StaticServer, path: []const u8) []const u8 {
        const ext = getExtension(path);
        return server.mime_types.get(ext) orelse "application/octet-stream";
    }

    /// Get file extension
    fn getExtension(path: []const u8) []const u8 {
        // Return extension including the leading dot (e.g., ".txt")
        const last_dot = mem.lastIndexOfScalar(u8, path, '.');
        return if (last_dot) |idx| path[idx..] else "";
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
            const etag = try generateETag(server.allocator, stat);
            defer server.allocator.free(etag);
            try ctx.response.setHeader("ETag", etag);
        }

        try ctx.response.setHeader("Content-Type", mime);
        try ctx.response.setHeader("Accept-Ranges", "bytes");

        // Check for Range header
        const range_header = ctx.getHeader("Range");
        if (range_header) |range_str| {
            if (try handleRangeRequest(server, ctx, file, file_path, size, range_str)) {
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
    fn handleRangeRequest(server: *StaticServer, ctx: *Context, file: std.Io.File, file_path: []const u8, size: u64, range_str: []const u8) !bool {
        // Only support simple single-range of the form: bytes=start-end
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
        if (end < start) {
            ctx.response.setStatus(http.Status.range_not_satisfiable);
            try ctx.text("Invalid range");
            return false;
        }

        const chunk_len: u64 = end - start + 1;

        // Set Partial Content response and headers
        ctx.response.setStatus(http.Status.partial_content);
        // Content-Range: bytes start-end/size
        const cr = try std.fmt.allocPrint(ctx.allocator, "bytes {d}-{d}/{d}", .{ start, end, size });
        defer ctx.allocator.free(cr);
        try ctx.response.setHeader("Content-Range", cr);

        try ctx.response.setHeader("Accept-Ranges", "bytes");
        const cl = try std.fmt.allocPrint(ctx.allocator, "{d}", .{chunk_len});
        defer ctx.allocator.free(cl);
        try ctx.response.setHeader("Content-Length", cl);

        // Stream the required range. If File API doesn't expose seek, we skip bytes by reading and discarding.
        var buffer: [65536]u8 = undefined;
        var to_skip: u64 = start;
        while (to_skip > 0) {
            // compute a read length as usize (buffer.len is usize, to_skip is u64)
            const read_len_usize = @min(buffer.len, @intCast(usize, to_skip));
            var read_buf = [_][]u8{buffer[0..read_len_usize]};
            const n = try std.Io.File.readStreaming(file, ctx.io, &read_buf);
            if (n == 0) break;
            // n is usize; to_skip is u64 -> cast n to u64 before subtracting
            to_skip -= @intCast(u64, n);
        }

        var remaining: u64 = chunk_len;
        while (remaining > 0) {
            // compute a read length as usize (buffer.len is usize, remaining is u64)
            const read_len_usize = @min(buffer.len, @intCast(usize, remaining));
            var read_buf = [_][]u8{buffer[0..read_len_usize]};
            const n = try std.Io.File.readStreaming(file, ctx.io, &read_buf);
            if (n == 0) break;
            try ctx.response.writeAll(buffer[0..n]);
            // n is usize; remaining is u64 -> cast n to u64 before subtracting
            remaining -= @intCast(u64, n);
        }

        return true;
    }

    /// Generate ETag for file
    fn generateETag(allocator: std.mem.Allocator, stat: std.Io.File.Stat) ![]const u8 {
        // Simple ETag based on mtime and size (using server allocator so the caller can free)
        const etag = try std.fmt.allocPrint(allocator, "\"{x}-{x}\"", .{ stat.mtime, stat.size });
        return etag;
    }

    /// Serve directory listing
    pub fn serveDirectory(server: *StaticServer, ctx: anytype, dir_path: []const u8) !bool {
        _ = @typeInfo(@TypeOf(ctx.response));
        // writer field removed

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
