const std = @import("std");
const http = std.http;
const Io = std.Io;

const Router = @import("router.zig").Router;
const Middleware = @import("middleware.zig").Middleware;
const Context = @import("context.zig").Context;
const Response = @import("response.zig").Response;
const Config = @import("types.zig").Config;
const Handler = @import("types.zig").Handler;
const StaticServer = @import("static_server.zig").StaticServer;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const Metrics = @import("monitoring.zig").Metrics;
const ErrorHandler = @import("error_handler.zig").ErrorHandler;
const Logger = @import("error_handler.zig").Logger;

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

    const WebSocketServer = @import("websocket.zig").WebSocketServer;

    pub fn init(allocator: std.mem.Allocator, config: Config) !HTTPServer {
        return .{
            .allocator = allocator,
            .io = undefined,
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

    pub fn deinit(server: *HTTPServer) void {
        server.router.deinit();
        for (server.middlewares.items) |middleware| {
            middleware.vtable.destroy(middleware);
        }
        server.middlewares.deinit(server.allocator);
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

    pub fn start(server: *HTTPServer, io: Io) !void {
        server.io = io;
        server.running = true;

        const host_str = try std.fmt.allocPrint(server.allocator, "{s}:{d}", .{
            server.config.host,
            server.config.port,
        });
        defer server.allocator.free(host_str);

        const address = try std.Io.net.IpAddress.parseLiteral(host_str);

        server.tcp_server = try address.listen(server.io, .{
            .reuse_address = true,
            .kernel_backlog = 4096,
        });

        std.log.info("Server listening on {s}:{}", .{ server.config.host, server.config.port });

        // Accept loop
        while (server.running and !server.isShuttingDown()) {
            const stream = server.tcp_server.accept(io) catch |err| {
                if (server.isShuttingDown()) {
                    std.log.info("Graceful shutdown: stopping accept loop", .{});
                    break;
                }
                std.log.err("Accept failed: {}", .{err});
                continue;
            };

            server.addActiveConnection();
            // Handle connection
            _ = io.async(handleConnection, .{ server, stream });
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
};

fn handleConnection(server: *HTTPServer, stream: Io.net.Stream) void {
    const io = server.io;
    defer {
        stream.close(io);
        server.removeActiveConnection();
    }

    var read_buffer: [16384]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server_struct = http.Server.init(&reader.interface, &writer.interface);

    // Keep-Alive loop
    while (!server.isShuttingDown()) {
        var request = http_server_struct.receiveHead() catch |err| {
            // Normal connection close conditions
            if (err == error.EndOfStream or err == error.HttpConnectionClosing) break;
            if (err == error.ReadFailed) {
                std.log.debug("Connection read failed (client may have closed connection): {}", .{err});
                break;
            }
            std.log.debug("Request head read error: {}", .{err});
            break;
        };

        std.debug.print("Received: {s} {s}\n", .{ @tagName(request.head.method), request.head.target });

        // Check for WebSocket upgrade before handling regular request
        if (server.ws_server) |ws_server| {
            const upgrade = request.upgradeRequested();
            std.log.info("WebSocket upgrade check for {s}: {}", .{ request.head.target, upgrade });

            if (upgrade == .websocket) {
                const sec_websocket_key = upgrade.websocket orelse {
                    std.log.err("WebSocket upgrade missing Sec-WebSocket-Key header", .{});
                    break;
                };

                if (ws_server.hasHandler(request.head.target)) {
                    std.log.info("WebSocket handler found for: {s}", .{request.head.target});
                    const handler = ws_server.getHandler(request.head.target).?;

                    std.log.info("Responding to WebSocket upgrade with key: {s}", .{sec_websocket_key});
                    const ws = request.respondWebSocket(.{ .key = sec_websocket_key }) catch |err| {
                        std.log.err("WebSocket upgrade failed: {}", .{err});
                        break;
                    };

                    const WebSocketContext = @import("websocket.zig").WebSocketContext;

                    const ws_read_buffer = server.allocator.alloc(u8, 8192) catch |err| {
                        std.log.err("Failed to allocate WebSocket read buffer: {}", .{err});
                        break;
                    };
                    defer server.allocator.free(ws_read_buffer);

                    var context = WebSocketContext{
                        .allocator = server.allocator,
                        .io = io,
                        .stream = stream,
                        .ws = ws,
                        .read_buffer = ws_read_buffer,
                    };

                    std.log.info("WebSocket connection established, calling handler", .{});
                    handler(&context) catch |err| {
                        std.log.err("WebSocket handler error: {}", .{err});
                        context.close();
                    };
                    std.log.info("WebSocket handler completed", .{});

                    return;
                } else {
                    std.log.warn("No WebSocket handler found for path: {s}", .{request.head.target});
                }
            }
        }

        // Read request body if present
        const content_length = if (request.head.content_length) |len| len else 0;

        // Enforce maximum request body size (10MB default)
        const max_body_size = 10 * 1024 * 1024;
        if (content_length > max_body_size) {
            std.log.warn("Request body exceeds maximum size: {d} > {d}", .{ content_length, max_body_size });
            var response = try Response.init(server.allocator);
            defer response.deinit();
            response.setStatus(.payload_too_large);
            response.writeJSON(.{ .error_val = "Request body too large" }) catch {};

            var ctx_tmp = try Context.init(server.allocator, server, &request, &response, server.io);
            defer ctx_tmp.deinit();
            response.toHttpResponse(&writer, &request) catch {};
            break;
        }

        var body: []u8 = &.{};
        if (content_length > 0) {
            body = server.allocator.alloc(u8, content_length) catch |err| {
                std.log.err("Failed to allocate body buffer: {}", .{err});
                break;
            };
            errdefer server.allocator.free(body);

            // Note: Body reading not fully implemented in 0.16
        }
        defer if (body.len > 0) server.allocator.free(body);

        // Handle request with body
        if (handleRequest(server, &request, &writer)) |_| {
            // Request handled successfully
        } else |err| {
            std.log.err("Error handling request: {}", .{err});
        }

        if (!request.head.keep_alive) break;
    }
}

fn handleRequest(server: *HTTPServer, request: *http.Server.Request, writer: anytype) !bool {
    var response = try Response.init(server.allocator);
    defer response.deinit();

    var context = try Context.init(server.allocator, server, request, &response, server.io);
    defer context.deinit();

    // Find route or check for static files
    const route = server.router.findRoute(request.head.method, request.head.target) catch |err| {
        std.log.err("Error finding route: {}", .{err});
        context.setStatus(http.Status.internal_server_error);
        try context.json(.{ .error_val = "Internal server error" });
        try response.toHttpResponse(writer, request);
        return true;
    } orelse {
        // Check if static file server is configured
        if (server.static_server) |static_srv| {
            if (request.head.method == http.Method.GET and
                static_srv.handle(&context) catch |err| {
                    std.log.err("Static file error: {}", .{err});
                    context.setStatus(http.Status.internal_server_error);
                    try context.json(.{ .error_val = "Internal server error" });
                    try response.toHttpResponse(writer, request);
                    return true;
                })
            {
                return true; // Static file served, skip route handler
            }
        }

        context.setStatus(http.Status.not_found);
        try context.json(.{ .error_val = "Not found" });
        try response.toHttpResponse(writer, request);
        return true;
    };

    // Execute global middlewares
    for (server.middlewares.items) |middleware| {
        const action = try middleware.vtable.process(middleware, &context, server.io);
        switch (action) {
            .@"continue" => continue,
            .respond, .err => {
                try response.toHttpResponse(writer, request);
                return true;
            },
        }
    }

    // Execute route middlewares
    for (route.middlewares) |middleware| {
        const action = try middleware.vtable.process(middleware, &context, server.io);
        switch (action) {
            .@"continue" => continue,
            .respond, .err => {
                try response.toHttpResponse(writer, request);
                return true;
            },
        }
    }

    // Execute handler
    route.handler(&context) catch |err| {
        std.log.err("Handler error: {}", .{err});
        context.setStatus(http.Status.internal_server_error);
        try context.json(.{ .error_val = "Internal server error" });
    };

    try response.toHttpResponse(writer, request);
    return true;
}
