/// Example demonstrating Server-Sent Events (SSE) and chunked streaming
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = @import("context.zig").Context;
const StreamingWriter = @import("streaming.zig").StreamingWriter;
const StreamingType = @import("streaming.zig").StreamingType;
const sendStreamingHeaders = @import("streaming.zig").sendStreamingHeaders;
const Io = std.Io;
const http = std.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Streaming Example starting on {s}:{d}", .{ "127.0.0.1", 8083 });

    var server = try HTTPServer.init(allocator, .{
        .port = 8083,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Add routes
    server.get("/", handleHome);
    server.get("/stream/sse", handleSSE);
    server.get("/stream/chunked", handleChunked);
    server.get("/stream/progress", handleProgress);

    std.log.info("\nTest with curl:");
    std.log.info("  curl -N http://127.0.0.1:8083/stream/sse");
    std.log.info("  curl -N http://127.0.0.1:8083/stream/chunked");
    std.log.info("  curl -N http://127.0.0.1:8083/stream/progress\n");

    try server.start(io);
}

fn handleHome(ctx: *Context) !void {
    try ctx.html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>Streaming Examples</title>
        \\  <style>
        \\    body { font-family: Arial, sans-serif; margin: 20px; }
        \\    .section { margin: 20px 0; padding: 15px; border: 1px solid #ddd; }
        \\    .log { background: #f5f5f5; padding: 10px; font-family: monospace; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <h1>Streaming Response Examples</h1>
        \\  <div class="section">
        \\    <h2>Server-Sent Events (SSE)</h2>
        \\    <div id="sse-log" class="log">Connecting...</div>
        \\  </div>
        \\  <div class="section">
        \\    <h2>Chunked Transfer</h2>
        \\    <div id="chunked-log" class="log">Connecting...</div>
        \\  </div>
        \\  <script>
        \\    // SSE Example
        \\    const sseEventSource = new EventSource('/stream/sse');
        \\    sseEventSource.onmessage = (e) => {
        \\      document.getElementById('sse-log').innerHTML += e.data + '<br>';
        \\    };
        \\    
        \\    // Chunked Example
        \\    fetch('/stream/chunked')
        \\      .then(r => {
        \\        const reader = r.body.getReader();
        \\        const decoder = new TextDecoder();
        \\        document.getElementById('chunked-log').innerHTML = '';
        \\        function read() {
        \\          reader.read().then(({done, value}) => {
        \\            if (done) return;
        \\            document.getElementById('chunked-log').innerHTML += decoder.decode(value);
        \\            read();
        \\          });
        \\        }
        \\        read();
        \\      });
        \\  </script>
        \\</body>
        \\</html>
    );
}

// Custom handler for SSE streaming
pub fn handleSSERequest(server: *HTTPServer, request: *http.Server.Request, writer: anytype) !void {
    const io = server.io;
    const allocator = server.allocator;

    // Send SSE headers
    try sendStreamingHeaders(writer, .sse, request);

    // Get stream from request
    const stream = request.stream orelse return error.NoStream;

    var sw = StreamingWriter.init(allocator, io, stream, writer, .{
        .stream_type = .sse,
        .event_name = "message",
        .retry_interval = 3000,
    });
    defer sw.deinit();

    // Send periodic events
    var counter: usize = 0;
    var timer = try std.time.Timer.start();

    while (counter < 10) : (counter += 1) {
        // Send event
        const message = try std.fmt.allocPrint(allocator, "Event {d} at {d}ms", .{ counter, timer.read() / 1000000 });
        defer allocator.free(message);
        try sw.writeSSE(message);

        // Wait 1 second
        std.time.sleep(1_000_000_000); // 1 second in nanoseconds
    }

    // Send final event
    try sw.writeSSE("Stream complete - closing connection");
}

pub fn handleChunkedRequest(server: *HTTPServer, request: *http.Server.Request, writer: anytype) !void {
    const io = server.io;
    const allocator = server.allocator;

    // Send chunked headers
    try sendStreamingHeaders(writer, .chunked, request);

    // Get stream from request
    const stream = request.stream orelse return error.NoStream;

    var sw = StreamingWriter.init(allocator, io, stream, writer, .{
        .stream_type = .chunked,
    });
    defer sw.deinit();

    // Send chunks
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const chunk = try std.fmt.allocPrint(allocator, "Chunk {d}: This is some data\n", .{i});
        defer allocator.free(chunk);
        try sw.writeChunk(chunk);
        std.time.sleep(500_000_000); // 500ms
    }

    try sw.close();
}

pub fn handleProgressRequest(server: *HTTPServer, request: *http.Server.Request, writer: anytype) !void {
    const io = server.io;
    const allocator = server.allocator;

    // Send SSE headers
    try sendStreamingHeaders(writer, .sse, request);

    // Get stream from request
    const stream = request.stream orelse return error.NoStream;

    var sw = StreamingWriter.init(allocator, io, stream, writer, .{
        .stream_type = .sse,
        .event_name = "progress",
    });
    defer sw.deinit();

    // Simulate file upload/download progress
    var progress: usize = 0;
    while (progress <= 100) : (progress += 10) {
        const message = try std.fmt.allocPrint(allocator, "{d}", .{progress});
        defer allocator.free(message);
        try sw.writeSSE(message);
        std.time.sleep(300_000_000); // 300ms
    }

    try sw.writeSSE("complete");
}

// For now, use simple handlers (we'll need to modify HTTPServer to support proper streaming handlers)
fn handleSSE(ctx: *Context) !void {
    try ctx.setStatus(http.Status.ok);
    try ctx.setHeader("Content-Type", "text/event-stream");
    try ctx.setHeader("Cache-Control", "no-cache");
    try ctx.setHeader("Connection", "keep-alive");
    try ctx.setHeader("X-Accel-Buffering", "no");
    
    try ctx.text("SSE endpoint - see handleSSERequest for implementation");
}

fn handleChunked(ctx: *Context) !void {
    try ctx.setStatus(http.Status.ok);
    try ctx.setHeader("Content-Type", "text/plain");
    try ctx.setHeader("Transfer-Encoding", "chunked");
    
    try ctx.text("Chunked endpoint - see handleChunkedRequest for implementation");
}

fn handleProgress(ctx: *Context) !void {
    try ctx.setStatus(http.Status.ok);
    try ctx.setHeader("Content-Type", "text/event-stream");
    try ctx.setHeader("Cache-Control", "no-cache");
    
    try ctx.text("Progress endpoint - see handleProgressRequest for implementation");
}
