/// Example demonstrating static file serving
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const StaticServer = @import("static_server.zig").StaticServer;
const Context = @import("context.zig").Context;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Static File Server Example starting on {s}:{d}", .{ "127.0.0.1", 8082 });

    var server = try HTTPServer.init(allocator, .{
        .port = 8082,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Initialize static file server
    var static_srv = try StaticServer.init(allocator, .{
        .root = "./public",
        .prefix = "/static",
        .enable_directory_listing = true,
        .enable_cache = true,
        .max_file_size = 10 * 1024 * 1024, // 10MB limit
    });
    defer static_srv.deinit();

    // Set static server to HTTP server
    server.setStaticServer(&static_srv);

    // Add a custom handler for API routes
    server.get("/api/info", apiInfo);

    // Start the server
    try server.start(io);
}

/// API endpoint showing server info
fn apiInfo(ctx: *Context) !void {
    const features = [_][]const u8{
        "Static file serving",
        "Directory listing",
        "Range support",
        "MIME type detection",
        "ETag caching",
        "Path traversal protection",
    };
    const endpoints = [_][]const u8{
        "GET /static/* - Serve static files",
        "GET /api/info - Server information",
    };
    try ctx.json(.{
        .server = "zig-http static file server",
        .version = "0.2.0",
        .features = features,
        .endpoints = endpoints,
    });
}
