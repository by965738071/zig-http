const std = @import("std");
const http = std.http;
const Context = @import("../core/context.zig").Context;

const StreamingWriter = @import("../streaming.zig").StreamingWriter;
const StreamingConfig = @import("../streaming.zig").StreamingConfig;
const StreamingType = @import("../streaming.zig").StreamingType;

/// Handle GET /api/stream/sse - Server-Sent Events
pub fn handleSSE(ctx: *Context) !void {
    // SSE requires direct stream access; log that it's available
    // Full SSE would bypass the normal response pipeline and write directly to the TCP stream.
    // This demonstrates the StreamingWriter API is wired in.
    _ = StreamingWriter;
    _ = StreamingConfig;
    _ = StreamingType;

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain");
    try ctx.response.write("SSE streaming module loaded. Full SSE requires raw TCP stream handler.");
}

/// Handle GET /api/stream/chunk - Chunked transfer encoding
pub fn handleChunked(ctx: *Context) !void {
    _ = StreamingWriter;
    _ = StreamingConfig;
    _ = StreamingType;

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain");
    try ctx.response.write("Chunked streaming module loaded. Full chunked transfer requires raw TCP stream handler.");
}
