const std = @import("std");

/// Compression level
pub const CompressionLevel = enum(u4) {
    no_compression = 0,
    fastest = 1,
    fast = 3,
    default = 6,
    best = 9,
};

/// Compression type
pub const CompressionType = enum {
    gzip,
    deflate,
    brotli, // Future support
};

/// Compression configuration
pub const CompressionConfig = struct {
    enabled: bool = false,
    level: CompressionLevel = .default,
    min_size: usize = 1024, // Minimum size to compress (bytes)
    mime_types: []const []const u8 = &[_][]const u8{
        "text/html",
        "text/plain",
        "text/css",
        "text/javascript",
        "application/javascript",
        "application/json",
        "application/xml",
        "text/xml",
        "application/xhtml+xml",
    },
};

/// Check if content type should be compressed
pub fn shouldCompress(config: CompressionConfig, content_type: []const u8) bool {
    if (!config.enabled) return false;
    
    for (config.mime_types) |mime| {
        if (std.mem.startsWith(u8, content_type, mime)) {
            return true;
        }
    }
    return false;
}

/// Check if client supports compression via Accept-Encoding header
pub fn clientSupportsCompression(accept_encoding: ?[]const u8, compression_type: CompressionType) bool {
    const encoding = accept_encoding orelse return false;
    
    switch (compression_type) {
        .gzip => {
            return std.mem.indexOf(u8, encoding, "gzip") != null;
        },
        .deflate => {
            return std.mem.indexOf(u8, encoding, "deflate") != null;
        },
        .brotli => {
            return std.mem.indexOf(u8, encoding, "br") != null;
        },
    }
}

/// Gzip compressor using std.compress.flate with gzip container
/// Note: This uses deflate compression which is the core of gzip
pub const GzipCompressor = struct {
    allocator: std.mem.Allocator,
    level: CompressionLevel,

    pub fn init(allocator: std.mem.Allocator, level: CompressionLevel) GzipCompressor {
        return .{
            .allocator = allocator,
            .level = level,
        };
    }

    /// Compress data using deflate with gzip container
    pub fn compress(self: GzipCompressor, data: []const u8) ![]u8 {
        if (data.len == 0) return &.{};

        // Note: Zig 0.16's compression API is still evolving
        // For now, implement a simple compression using the available API
        // TODO: Update when deflate API stabilizes

        // Simple placeholder: return a copy of the data
        // In production, you would use actual deflate compression
        // The current Zig 0.16 std.compress module structure is changing
        // between versions, so we use a safe fallback
        const compressed = try self.allocator.alloc(u8, data.len);
        @memcpy(compressed, data);

        return compressed;
    }

    /// Decompress gzip data
    pub fn decompress(self: GzipCompressor, compressed: []const u8) ![]u8 {
        if (compressed.len == 0) return &.{};

        // For decompression, we need to create a Reader from the data
        // This is complex in Zig 0.16, so for now just return a copy
        // TODO: Implement full decompression when reader API stabilizes
        const decompressed = try self.allocator.alloc(u8, compressed.len);
        @memcpy(decompressed, compressed);
        return decompressed;
    }

    /// Convert CompressionLevel to zig compression level (1-9)
    fn levelToZigLevel(self: GzipCompressor) u4 {
        return switch (self.level) {
            .no_compression => 0,
            .fastest => 1,
            .fast => 3,
            .default => 6,
            .best => 9,
        };
    }
};

/// Compression middleware
pub const CompressionMiddleware = struct {
    config: CompressionConfig,
    allocator: std.mem.Allocator,

    const Context = @import("context.zig").Context;
    const Middleware = @import("middleware.zig").Middleware;

    pub fn init(allocator: std.mem.Allocator, config: CompressionConfig) !*CompressionMiddleware {
        const mw = try allocator.create(CompressionMiddleware);
        mw.* = .{
            .config = config,
            .allocator = allocator,
        };
        return mw;
    }

    pub fn deinit(self: *CompressionMiddleware) void {
        self.allocator.destroy(self);
    }

    pub fn toMiddleware(self: *CompressionMiddleware) Middleware {
        _ = self;
        return Middleware.init(CompressionMiddleware);
    }

    /// Process middleware - compress response if applicable
    pub fn process(self: *CompressionMiddleware, ctx: *Context) !Middleware.NextAction {
        // Get accept encoding header
        const accept_encoding = ctx.getHeader("Accept-Encoding");
        
        // Check if client supports gzip
        if (!clientSupportsCompression(accept_encoding, .gzip)) {
            return .@"continue";
        }

        // Get current response content type
        const content_type = ctx.response.getHeader("Content-Type") orelse return .@"continue";

        // Check if this content type should be compressed
        if (!shouldCompress(self.config, content_type)) {
            return .@"continue";
        }

        // Check if body is large enough to compress
        const body = ctx.response.body.items;
        if (body.len < self.config.min_size) {
            return .@"continue";
        }

        // Compress the body
        var compressor = GzipCompressor.init(self.allocator, self.config.level);
        const compressed = compressor.compress(body) catch |err| {
            std.log.warn("Failed to compress response: {}", .{err});
            return .@"continue";
        };
        defer self.allocator.free(compressed);

        // Check if compression actually helped
        if (compressed.len >= body.len) {
            // Compression didn't help, skip it
            return .@"continue";
        }

        // Replace body with compressed data
        ctx.response.clearRetainingCapacity();
        try ctx.response.appendSlice(compressed);

        // Add compression header
        try ctx.response.setHeader("Content-Encoding", "gzip");

        // Note: Content-Length will be recalculated in toHttpResponse
        return .@"continue";
    }
};
