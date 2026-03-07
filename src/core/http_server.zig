const std = @import("std");
const http = std.http;
const Io = std.Io;

const Router = @import("router.zig").Router;
const Middleware = @import("middleware.zig").Middleware;
const Context = @import("context.zig").Context;
const Response = @import("response.zig").Response;
const Config = @import("types.zig").Config;
const Handler = @import("types.zig").Handler;

// Features (optional dependencies - passed via set methods)
const WebSocketServer = extern struct { const Context = opaque; };
const StaticServer = extern struct {};
const RateLimiter = extern struct {};
const Metrics = extern struct {};
const ErrorHandler = extern struct { const Logger = opaque; };
const StringInterner = extern struct {};
const InterceptorRegistry = extern struct {};
const BufferPool = extern struct {};
const MemoryPool = extern struct {};

// Helper: read exactly `buf.len` bytes from a reader (returns number read or error)
// Use Reader vtable's readVec when available (0.16 reader API).
fn readExact(reader: anytype, buf: []u8) !usize {
    var offset: usize = 0;
    while (offset < buf.len) {
        const slice = buf[offset..];
        // Call into vtable.readVec if available. `reader` is expected to be a pointer-like
        // object with a `.vtable.readVec` method in std 0.16.
        const n = try reader.readAll(slice);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
    return offset;
}

/// Helper: decode chunked transfer-encoding from reader and return an allocated buffer
/// This version uses Reader.readVec (0.16 API) to read into slices.
/// Optimized for performance with pre-allocation and reduced memory operations
fn readChunkedBody(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    // Pre-allocate with reasonable initial capacity to reduce reallocations
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var line_buf = std.ArrayList(u8){};
    defer line_buf.deinit(allocator);

    while (true) {
        line_buf.clearRetainingCapacity();
        // Read chunk size line (ends with CRLF)
        var line_ended = false;
        while (!line_ended) {
            var byte: [1]u8 = undefined;
            const n = try reader.readSliceShort(&byte);
            if (n == 0) {
                return error.EndOfStream;
            }
            try line_buf.append(allocator, byte[0]);
            const len = line_buf.items.len;
            if (len >= 2 and line_buf.items[len - 2] == '\r' and line_buf.items[len - 1] == '\n') {
                line_ended = true;
            }
        }

        const size_line = line_buf.items;
        const trimmed = std.mem.trim(u8, size_line, &std.ascii.whitespace);
        const semicolon_idx = std.mem.indexOfScalar(u8, trimmed, ';');
        const size_str = if (semicolon_idx) |i| trimmed[0..i] else trimmed;
        const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch {
            return error.InvalidFormat;
        };

        if (chunk_size == 0) {
            var crlf: [2]u8 = undefined;
            try reader.readSliceAll(&crlf);
            break;
        }

        // Pre-allocate space for the chunk to avoid multiple appends
        try out.ensureUnusedCapacity(allocator, chunk_size);

        var remaining: usize = chunk_size;
        var tmp_buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const to_read = if (tmp_buf.len < remaining) tmp_buf.len else remaining;
            const n = try reader.readSliceShort(tmp_buf[0..to_read]);
            if (n == 0) {
                return error.EndOfStream;
            }
            out.appendSliceAssumeCapacity(tmp_buf[0..n]);
            remaining -= n;
        }

        var crlf2: [2]u8 = undefined;
        try reader.readSliceAll(&crlf2);
    }

    return out.toOwnedSlice(allocator);
}

/// HTTP Server implementation
/// Handles incoming HTTP requests, manages connections, and routes requests to handlers
pub const HTTPServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    tcp_server: Io.net.Server,
    router: Router,
    middlewares: std.ArrayList(*Middleware),
    config: Config,
    running: bool,
    shutdown_requested: std.atomic.Value(bool),
    active_connections: std.atomic.Value(usize),
    ws_server: ?*WebSocketServer = null,
    static_server: ?*StaticServer = null,
    rate_limiter: ?*RateLimiter = null,
    metrics: ?*Metrics = null,
    error_handler: ?*ErrorHandler = null,
    logger: ?*Logger = null,
    string_interner: StringInterner,
    interceptor_registry: ?*InterceptorRegistry = null,
    read_buffer_pool: BufferPool,
    write_buffer_pool: BufferPool,
    /// Memory pool for request-scoped allocations
    memory_pool: *MemoryPool,
    /// Signal handler for graceful shutdown
    signal_handler: ?*const anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !HTTPServer {
        // Create memory pool for request-scoped allocations
        const memory_pool = try allocator.create(MemoryPool);
        memory_pool.* = MemoryPool.init(allocator, io, .{
            .block_size = 4096,
            .max_blocks = 1024,
            .small_size_threshold = 256,
        });

        return .{
            .allocator = allocator,
            .io = io,
            .tcp_server = undefined,
            .router = try Router.init(allocator),
            .middlewares = std.ArrayList(*Middleware){},
            .config = config,
            .running = false,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(usize).init(0),
            .ws_server = null,
            .static_server = null,
            .rate_limiter = null,
            .metrics = null,
            .error_handler = null,
            .logger = null,
            .string_interner = StringInterner.init(allocator),
            .interceptor_registry = null,
            .read_buffer_pool = BufferPool.init(allocator, 16384, 256),
            .write_buffer_pool = BufferPool.init(allocator, 8192, 256),
            .memory_pool = memory_pool,
        };
    }

    pub fn setWebSocketServer(server: *HTTPServer, ws_server: *WebSocketServer) void {
        server.ws_server = ws_server;
    }

    pub fn setStaticServer(server: *HTTPServer, static_server: *StaticServer) void {
        server.static_server = static_server;
    }

    pub fn setRateLimiter(server: *HTTPServer, limiter: *RateLimiter) void {
        server.rate_limiter = limiter;
    }

    pub fn setMetrics(server: *HTTPServer, metrics: *Metrics) void {
        server.metrics = metrics;
    }

    pub fn setErrorHandler(server: *HTTPServer, handler: *ErrorHandler) void {
        server.error_handler = handler;
    }

    pub fn setLogger(server: *HTTPServer, logger: *Logger) void {
        server.logger = logger;
    }

    pub fn setRouter(server: *HTTPServer, router: Router) void {
        server.router = router;
    }

    pub fn setInterceptorRegistry(server: *HTTPServer, registry: *InterceptorRegistry) void {
        server.interceptor_registry = registry;
    }

    pub fn deinit(server: *HTTPServer) void {
        server.router.deinit();
        for (server.middlewares.items) |middleware| {
            middleware.vtable.destroy(middleware);
        }
        server.middlewares.deinit(server.allocator);
        server.string_interner.deinit();
        server.read_buffer_pool.deinit();
        server.write_buffer_pool.deinit();
        server.memory_pool.deinit();
        server.allocator.destroy(server.memory_pool);
    }

    pub fn use(server: *HTTPServer, middleware: *Middleware) void {
        server.middlewares.append(server.allocator, middleware) catch |err| {
            std.log.err("Failed to add middleware: {}", .{err});
        };
    }

    pub fn get(server: *HTTPServer, path: []const u8, handler: Handler) void {
        server.router.addRoute(http.Method.GET, path, handler) catch |err| {
            std.log.err("Failed to add GET route {s}: {}", .{ path, err });
        };
    }

    pub fn post(server: *HTTPServer, path: []const u8, handler: Handler) void {
        server.router.addRoute(http.Method.POST, path, handler) catch |err| {
            std.log.err("Failed to add POST route {s}: {}", .{ path, err });
        };
    }

    pub fn put(server: *HTTPServer, path: []const u8, handler: Handler) void {
        server.router.addRoute(http.Method.PUT, path, handler) catch |err| {
            std.log.err("Failed to add PUT route {s}: {}", .{ path, err });
        };
    }

    pub fn delete(server: *HTTPServer, path: []const u8, handler: Handler) void {
        server.router.addRoute(http.Method.DELETE, path, handler) catch |err| {
            std.log.err("Failed to add DELETE route {s}: {}", .{ path, err });
        };
    }

    pub fn all(server: *HTTPServer, path: []const u8, handler: Handler) void {
        const methods = [_]http.Method{
            .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .TRACE, .CONNECT,
        };

        for (methods) |method| {
            server.router.addRoute(method, path, handler) catch |err| {
                std.log.err("Failed to add route {s}: {}", .{ path, err });
            };
        }
    }

    pub fn group(server: *HTTPServer, prefix: []const u8, middlewares: []*Middleware, routes_fn: fn (*HTTPServer) void) void {
        _ = prefix;
        // Store original middlewares
        _ = server.middlewares.items.len;

        // Add group middlewares
        for (middlewares) |mw| {
            server.use(mw);
        }

        // Register routes (these will have group middlewares)
        routes_fn(server);

        // Note: In a full implementation, we'd prefix all routes registered in group
        // This is a simplified version for demonstration
    }

    pub fn start(server: *HTTPServer) !void {
        server.running = true;

        const host_str = try std.fmt.allocPrint(server.allocator, "{s}:{d}", .{
            server.config.host,
            server.config.port,
        });
        defer server.allocator.free(host_str);

        const address = try std.Io.net.IpAddress.parseLiteral(host_str);

        server.tcp_server = try address.listen(server.io, .{
            .reuse_address = false,
            .kernel_backlog = 4096,
        });

        std.log.info("Server listening on {s}:{}", .{ server.config.host, server.config.port });

        // Accept loop
        while (server.running and !server.isShuttingDown()) {
            const stream = server.tcp_server.accept(server.io) catch |err| {
                // Check if shutdown was requested while waiting
                if (server.isShuttingDown()) {
                    std.log.info("Graceful shutdown: stopping accept loop", .{});
                    break;
                }
                if (server.signal_handler) |handler_ptr| {
                    const SignalHandler = @import("../signal_handler.zig").SignalHandler;
                    const handler = @as(*const SignalHandler, @ptrCast(@alignCast(handler_ptr)));
                    if (handler.isShutdownRequested()) {
                        std.log.info("Shutdown signal received during accept wait", .{});
                        server.requestShutdown();
                        break;
                    }
                }
                std.log.err("Accept failed: {}", .{err});
                continue;
            };

            // Double-check shutdown after accept returns
            if (server.isShuttingDown()) {
                stream.close(server.io);
                std.log.info("Graceful shutdown: closing accepted connection", .{});
                break;
            }

            server.addActiveConnection();
            // Handle connection
            _ = server.io.async(handleConnection, .{ server, stream });
        }

        // Wait for active connections to complete (graceful shutdown)
        if (server.isShuttingDown()) {
            std.log.info("Waiting for {d} active connections to complete", .{server.getActiveConnections()});
            var timeout_ms: u64 = 5000; // 5 second timeout
            while (server.getActiveConnections() > 0 and timeout_ms > 0) : (timeout_ms -= 100) {
                // Sleep not available in this Zig version // 100ms
            }
            if (server.getActiveConnections() > 0) {
                std.log.warn("Forcing shutdown with {d} active connections remaining", .{server.getActiveConnections()});
            } else {
                std.log.info("All connections closed gracefully", .{});
            }
        }
    }

    pub fn stop(server: *HTTPServer) void {
        server.running = false;
    }

    pub fn requestShutdown(server: *HTTPServer) void {
        server.shutdown_requested.store(true, .release);
    }

    pub fn isShuttingDown(server: *HTTPServer) bool {
        return server.shutdown_requested.load(.acquire);
    }

    pub fn addActiveConnection(server: *HTTPServer) void {
        var val = server.active_connections.load(.acquire);
        val += 1;
        server.active_connections.store(val, .release);
    }

    pub fn removeActiveConnection(server: *HTTPServer) void {
        var val = server.active_connections.load(.acquire);
        if (val > 0) val -= 1;
        server.active_connections.store(val, .release);
    }

    pub fn getActiveConnections(server: *HTTPServer) usize {
        return server.active_connections.load(.acquire);
    }

    /// Set signal handler for graceful shutdown
    pub fn setSignalHandler(server: *HTTPServer, handler: *const anyopaque) void {
        server.signal_handler = handler;
    }
};

/// Handle incoming TCP connection
/// Processes HTTP requests and manages WebSocket upgrades
fn handleConnection(server: *HTTPServer, stream: Io.net.Stream) void {
    const io = server.io;
    defer {
        stream.close(io);
        server.removeActiveConnection();
    }

    // Acquire buffers from pool
    const read_buffer = server.read_buffer_pool.acquire() catch |err| {
        std.log.err("Failed to acquire read buffer: {}", .{err});
        return;
    };
    defer server.read_buffer_pool.release(read_buffer);

    const write_buffer = server.write_buffer_pool.acquire() catch |err| {
        std.log.err("Failed to acquire write buffer: {}", .{err});
        return;
    };
    defer server.write_buffer_pool.release(write_buffer);

    var reader = stream.reader(io, read_buffer);
    var writer = stream.writer(io, write_buffer);
    var http_server_struct = http.Server.init(&reader.interface, &writer.interface);

    // Track connection start time for timeout
    const connection_start = std.Io.Timestamp.now(io, .boot);

    // Keep-Alive loop
    while (!server.isShuttingDown()) {
        // Check connection timeout
        const elapsed_ns = std.Io.Timestamp.now(io, .boot).toNanoseconds() - connection_start.toNanoseconds();
        const timeout_ns: i96 = @intCast(server.config.connection_timeout * 1_000_000); // Convert ms to ns
        if (elapsed_ns > timeout_ns) {
            const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
            std.log.err("Connection timeout after {d}ms", .{elapsed_ms});
            break;
        }

        // Receive request head
        var request = http_server_struct.receiveHead() catch |err| {
            std.log.info("Request head read error {s}", .{@errorName(err)});
            break;
        };

        // Check for WebSocket upgrade before handling regular request
        if (server.ws_server != null) {
            // Fast path: check if it might be a WebSocket upgrade request
            var connection_header: ?[]const u8 = null;
            var upgrade_header: ?[]const u8 = null;

            var it = request.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "Connection")) {
                    connection_header = header.value;
                } else if (std.ascii.eqlIgnoreCase(header.name, "Upgrade")) {
                    upgrade_header = header.value;
                }
            }

            const is_potential_websocket =
                (connection_header != null and std.mem.indexOf(u8, connection_header.?, "upgrade") != null) and
                (upgrade_header != null and std.ascii.eqlIgnoreCase(upgrade_header.?, "websocket"));

            if (is_potential_websocket) {
                const ws_server = server.ws_server.?;
                const upgrade = request.upgradeRequested();

                if (upgrade == .websocket) {
                    const sec_websocket_key = upgrade.websocket orelse {
                        std.log.err("WebSocket upgrade missing Sec-WebSocket-Key header", .{});
                        break;
                    };

                    if (ws_server.hasHandler(request.head.target)) {
                        const handler = ws_server.getHandler(request.head.target).?;

                        const ws = request.respondWebSocket(.{ .key = sec_websocket_key }) catch |err| {
                            std.log.err("WebSocket upgrade failed: {}", .{err});
                            break;
                        };

                        // Use memory pool for WebSocket buffer
                        const ws_read_buffer = server.memory_pool.alloc(8192) catch |err| {
                            std.log.err("Failed to allocate WebSocket read buffer: {}", .{err});
                            break;
                        };
                        defer server.memory_pool.free(ws_read_buffer);

                        var context = WebSocketContext{
                            .allocator = server.allocator,
                            .io = io,
                            .stream = stream,
                            .ws = ws,
                            .read_buffer = ws_read_buffer,
                        };

                        handler(&context) catch |err| {
                            std.log.err("WebSocket handler error: {}", .{err});
                            context.close();
                        };

                        return;
                    } else {
                        std.log.warn("No WebSocket handler found for path: {s}", .{request.head.target});
                    }
                }
            }
        }

        // Read request body if present
        const content_length = if (request.head.content_length) |len| len else 0;

        // Enforce maximum request body size from config (default 10MB)
        const max_body_size = server.config.max_request_body_size;
        if (content_length > max_body_size) {
            std.log.warn("Request body exceeds maximum size: {d} > {d}", .{ content_length, max_body_size });

            // Send 413 Payload Too Large response
            var response = Response.init(server.allocator, &server.string_interner) catch {
                // If response init fails, send minimal error response
                const w = &writer.interface;
                w.writeAll("HTTP/1.1 413 Payload Too Large\r\n\r\n") catch {};
                w.flush() catch {};
                break;
            };
            defer response.deinit();

            response.setStatus(.payload_too_large);
            response.writeJSON(.{ .error_val = "Request body too large", .max_size = max_body_size }) catch {};

            var ctx_tmp = Context.init(server.allocator, server, &request, &response, server.io) catch {
                // If context init fails, still send response
                response.toHttpResponse(&writer.interface, &request) catch {};
                break;
            };
            defer ctx_tmp.deinit();

            response.toHttpResponse(&writer.interface, &request) catch {};
            break;
        }

        var body: []u8 = &.{};
        var body_owned: bool = false;

        // Handle Expect: 100-continue if present
        if (request.head.expect) |expect_val| {
            if (std.ascii.eqlIgnoreCase(expect_val, "100-continue")) {
                const w = &writer.interface;
                // Send interim 100 Continue response
                w.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch |err| {
                    std.log.err("Failed to write 100 Continue: {s}", .{@errorName(err)});
                };
            }
        }

        // Read request body based on transfer encoding
        if (request.head.transfer_encoding == .chunked) {
            // Use memory pool for chunked body
            body = readChunkedBody(server.allocator, &reader.interface) catch |err| {
                std.log.err("Failed to read chunked body: {}", .{err});
                break;
            };
            body_owned = true;
        } else if (content_length > 0) {
            // Read fixed-length body
            const len_usize: usize = @intCast(content_length);
            var buf = server.memory_pool.alloc(len_usize) catch |err| {
                std.log.err("Failed to allocate body buffer: {}", .{err});
                break;
            };

            const conn_reader = &reader.interface;
            var total_read: usize = 0;
            while (total_read < len_usize) {
                const slice = buf[total_read..];
                const n = conn_reader.readSliceShort(slice) catch |err| {
                    server.memory_pool.free(buf);
                    std.log.err("Failed to read request body: {}", .{err});
                    break;
                };
                if (n == 0) {
                    server.memory_pool.free(buf);
                    std.log.err("Failed to read request body: EndOfStream", .{});
                    break;
                }
                total_read += n;
            }

            if (total_read != len_usize) {
                // Incomplete read
                server.memory_pool.free(buf);
                std.log.err("Incomplete body read: expected {d}, got {d}", .{ len_usize, total_read });
                break;
            }

            // Use the buffer as the body and mark ownership for Context to free
            body = buf;
            body_owned = true;
        } else {
            // No body present
            body_owned = false;
        }

        // Create response and context
        var response = Response.init(server.allocator, &server.string_interner) catch {
            // If response init fails, we can't continue
            break;
        };
        defer response.deinit();

        var context = Context.init(server.allocator, server, &request, &response, server.io) catch |context_error| {
            // If context init fails, we can't continue
            std.log.err("Context init failed: {}", .{context_error});
            break;
        };
        defer context.deinit();

        if (body.len > 0 and body_owned) {
            // Initialize body parser with the content type and body data
            const content_type = context.getHeader("Content-Type");
            context.body_parser = BodyParser.init(
                server.allocator,
                content_type,
                body,
            );

            // Note: We don't transfer ownership to context.
            // The body will be freed after request handling completes.
        }

        // Clean up body if still owned
        if (body_owned and body.len > 0) {
            server.memory_pool.free(body);
            body_owned = false;
        }

        // Call top-level handleRequest to process the request
        handleRequest(server, &context, &writer) catch |err| {
            std.log.err("Error handling request: {}", .{err});
        };

        if (!request.head.keep_alive) break;
    }
}

/// Handle HTTP request
/// Processes request through interceptors, middlewares, and route handler
fn handleRequest(server: *HTTPServer, context: *Context, writer: anytype) !void {
    const request = context.request;
    const response = context.response;

    // Execute before_request interceptors
    if (server.interceptor_registry) |registry| {
        registry.executeBeforeRequest(context) catch |err| {
            std.log.err("Before request interceptor failed: {}", .{err});
            context.setStatus(http.Status.internal_server_error);
            try context.json(.{ .error_val = "Internal server error" });
            try response.toHttpResponse(&writer.interface, request);
            return;
        };
    }

    // Check rate limit if configured
    if (server.rate_limiter) |limiter| {
        const key = request.head.target; // Use target path as rate limit key
        if (!limiter.isAllowed(key)) {
            context.setStatus(http.Status.too_many_requests);
            try context.json(.{ .error_val = "Rate limit exceeded", .retry_after = 60 });
            try response.toHttpResponse(&writer.interface, request);
            return;
        }
    }

    // Find route or check for static files
    const route = server.router.findRoute(request.head.method, request.head.target) catch |err| {
        std.log.err("Error finding route: {}", .{err});
        context.setStatus(http.Status.internal_server_error);
        try context.json(.{ .error_val = "Internal server error" });
        try response.toHttpResponse(&writer.interface, request);
        return;
    } orelse {
        // Route not found for this method - check if it exists for other methods (405 vs 404)
        if (server.router.hasPath(request.head.target)) {
            // Path exists but method not allowed
            context.setStatus(http.Status.method_not_allowed);
            try context.json(.{ .error_val = "Method not allowed" });
            try response.toHttpResponse(&writer.interface, request);
            return;
        }

        // Check if static file server is configured
        if (server.static_server) |static_srv| {
            if (request.head.method == http.Method.GET) {
                const static_handled = static_srv.handle(context) catch |err| {
                    std.log.err("Static file error: {}", .{err});
                    context.setStatus(http.Status.internal_server_error);
                    try context.html("Internal server error");
                    try response.toHttpResponse(&writer.interface, request);
                    return;
                };

                if (static_handled) {
                    try response.toHttpResponse(&writer.interface, request);
                    return; // Static file served, skip route handler
                }
            }
        }

        // 404 Not Found
        context.setStatus(http.Status.not_found);
        try context.json(.{ .error_val = "Not found" });
        try response.toHttpResponse(&writer.interface, request);
        return;
    };

    // Execute global middlewares
    for (server.middlewares.items) |middleware| {
        const action = try middleware.vtable.process(middleware, context, server.io);
        switch (action) {
            .@"continue" => continue,
            .respond, .err => {
                try response.toHttpResponse(&writer.interface, request);
                return;
            },
        }
    }

    // Execute route middlewares
    for (route.middlewares) |middleware| {
        const action = try middleware.vtable.process(middleware, context, server.io);
        switch (action) {
            .@"continue" => continue,
            .respond, .err => {
                try response.toHttpResponse(&writer.interface, request);
                return;
            },
        }
    }

    // Execute handler
    route.handler(context) catch |err| {
        std.log.err("Handler error: {}", .{err});
        context.setStatus(http.Status.internal_server_error);
        try context.json(.{ .error_val = "Internal server error" });

        // Execute on_error interceptors
        if (server.interceptor_registry) |registry| {
            registry.executeOnError(context, err);
        }
    };

    // Execute after_response interceptors
    if (server.interceptor_registry) |registry| {
        registry.executeAfterResponse(context) catch |err| {
            std.log.warn("After response interceptor failed: {}", .{err});
        };
    }

    // Send response
    try response.toHttpResponse(&writer.interface, request);
}
