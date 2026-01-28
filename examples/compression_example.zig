/// Example demonstrating Gzip compression for responses
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = @import("context.zig").Context;
const CompressionMiddleware = @import("compression.zig").CompressionMiddleware;
const http = std.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Compression Example starting on {s}:{d}", .{ "127.0.0.1", 8082 });

    var server = try HTTPServer.init(allocator, .{
        .port = 8082,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Add compression middleware
    const compression_config = .{
        .enabled = true,
        .level = .default,
        .min_size = 512, // Compress responses >= 512 bytes
    };
    const compression_mw = try CompressionMiddleware.init(allocator, compression_config);
    defer compression_mw.deinit();
    server.use(&compression_mw.toMiddleware());

    // Add routes
    server.get("/", handleHome);
    server.get("/api/data", handleJSONData);
    server.get("/api/large", handleLargeJSON);
    server.get("/api/html", handleHTML);

    std.log.info("\nTest with curl (with compression):");
    std.log.info("  curl -v -H 'Accept-Encoding: gzip' http://127.0.0.1:8082/api/data");
    std.log.info("\nTest with curl (without compression):");
    std.log.info("  curl -v http://127.0.0.1:8082/api/data\n");

    try server.start(io);
}

fn handleHome(ctx: *Context) !void {
    try ctx.html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Compression Example</title></head>
        \\<body>
        \\  <h1>Gzip Compression Demo</h1>
        \\  <ul>
        \\    <li><a href="/api/data">JSON Data API</a></li>
        \\    <li><a href="/api/large">Large JSON API</a></li>
        \\    <li><a href="/api/html">HTML Content</a></li>
        \\  </ul>
        \\  <p>Send <code>Accept-Encoding: gzip</code> header to enable compression.</p>
        \\</body>
        \\</html>
    );
}

fn handleJSONData(ctx: *Context) !void {
    try ctx.json(.{
        .message = "This response will be compressed if Accept-Encoding: gzip is sent",
        .data = &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
        .metadata = .{
            .compressed = true,
            .encoding = "gzip",
        },
    });
}

fn handleLargeJSON(ctx: *Context) !void {
    // Generate a large JSON response that will definitely be compressed
    var items = std.ArrayList(std.json.Value).init(ctx.allocator);
    defer items.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try items.append(.{
            .id = i,
            .name = try std.fmt.allocPrint(ctx.allocator, "Item {d}", .{i}),
            .description = "This is a longer description to ensure the response is large enough to be compressed",
            .timestamp = std.time.timestamp(),
            .tags = &[_]std.json.Value{
                .string = "sample"),
                .string = "test"),
                .string = "data"),
            },
        });
    }

    try ctx.json(.{
        .count = items.items.len,
        .items = items.items,
    });
}

fn handleHTML(ctx: *Context) !void {
    var html_content = std.ArrayList(u8).init(ctx.allocator);
    defer html_content.deinit();

    try html_content.writer().writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8">
        \\  <title>Compression Test Page</title>
        \\</head>
        \\<body>
        \\
    );

    // Add repeated content to make it compressible
    try html_content.writer().writeAll("<h1>Compression Test</h1>\n");
    
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try html_content.writer().print(
            \\<div class="section-{d}">
            \\  <h2>Section {d}</h2>
            \\  <p>This is some repeated content that will compress well.</p>
            \\  <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>
            \\</div>
            \\
        , .{ i, i });
    }

    try html_content.writer().writeAll("</body>\n</html>");

    try ctx.html(html_content.items);
}
