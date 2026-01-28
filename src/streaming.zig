const std = @import("std");
const http = std.http;
const Io = std.Io;

/// Streaming response types
pub const StreamingType = enum {
    chunked,
    sse, // Server-Sent Events
};

/// Streaming configuration
pub const StreamingConfig = struct {
    stream_type: StreamingType,
    event_name: ?[]const u8 = null, // For SSE
    retry_interval: ?u32 = null, // For SSE
};

/// Streaming response writer
pub const StreamingWriter = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    writer: std.Io.Writer,
    config: StreamingConfig,
    closed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        stream: Io.net.Stream,
        writer: anytype,
        config: StreamingConfig,
    ) StreamingWriter {
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .writer = writer,
            .config = config,
        };
    }

    /// Write SSE event
    pub fn writeSSE(self: *StreamingWriter, data: []const u8) !void {
        if (self.closed) return error.StreamClosed;

        const w = &self.writer.interface;

        // Write event name if configured
        if (self.config.event_name) |event| {
            try w.print("event: {s}\r\n", .{event});
        }

        // Write data
        try w.print("data: {s}\r\n", .{data});

        // Write retry if configured
        if (self.config.retry_interval) |retry| {
            try w.print("retry: {d}\r\n", .{retry});
        }

        // End event
        try w.writeAll("\r\n");

        try w.flush();
    }

    /// Write chunked data
    pub fn writeChunk(self: *StreamingWriter, data: []const u8) !void {
        if (self.closed) return error.StreamClosed;

        const w = &self.writer.interface;

        // Write chunk size in hex
        try w.print("{x}\r\n", .{data.len});
        try w.writeAll(data);
        try w.writeAll("\r\n");
        try w.flush();
    }

    /// Close the stream
    pub fn close(self: *StreamingWriter) !void {
        if (self.closed) return;
        self.closed = true;

        const w = &self.writer.interface;

        switch (self.config.stream_type) {
            .chunked => {
                // Write final empty chunk
                try w.writeAll("0\r\n\r\n");
                try w.flush();
            },
            .sse => {
                // No special close needed for SSE
                try w.flush();
            },
        }
    }

    /// Deinit streaming writer
    pub fn deinit(self: *StreamingWriter) void {
        if (!self.closed) {
            self.close() catch {};
        }
    }
};

/// Streaming middleware for setting up streaming responses
pub const StreamingMiddleware = struct {
    allocator: std.mem.Allocator,

    const Context = @import("context.zig").Context;
    const Middleware = @import("middleware.zig").Middleware;

    pub fn init(allocator: std.mem.Allocator) StreamingMiddleware {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamingMiddleware) void {
        _ = self;
    }

    pub fn toMiddleware(self: *StreamingMiddleware) Middleware {
        return Middleware.init(StreamingMiddleware);
    }

    pub fn process(self: *StreamingMiddleware, ctx: *Context) !Middleware.NextAction {
        _ = self;
        _ = ctx;
        return .@"continue";
    }
};

/// Helper to send streaming response headers
pub fn sendStreamingHeaders(
    writer: anytype,
    stream_type: StreamingType,
    request: *http.Server.Request,
) !void {
    const w = &writer.interface;

    // Status line
    try w.print("HTTP/1.1 200 OK\r\n");

    switch (stream_type) {
        .chunked => {
            try w.writeAll("Transfer-Encoding: chunked\r\n");
            try w.print("Content-Type: text/plain\r\n");
        },
        .sse => {
            try w.writeAll("Content-Type: text/event-stream\r\n");
            try w.writeAll("Cache-Control: no-cache\r\n");
            try w.writeAll("Connection: keep-alive\r\n");
            try w.writeAll("X-Accel-Buffering: no\r\n"); // Disable nginx buffering
        },
    }

    try w.print("connection: {s}\r\n", .{if (request.head.keep_alive) "keep-alive" else "close"});
    try w.writeAll("\r\n");

    try w.flush();
}
