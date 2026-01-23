const std = @import("std");
const http = std.http;
const Io = std.Io;

const Router = @import("router.zig").Router;
const Middleware = @import("middleware.zig").Middleware;
const Context = @import("context.zig").Context;
const Response = @import("response.zig").Response;
const Config = @import("types.zig").Config;
const Handler = @import("types.zig").Handler;

pub const HTTPServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    tcp_server: Io.net.Server,
    router: Router,
    middlewares: std.ArrayList(*Middleware),
    config: Config,
    running: bool,
    ws_server: ?*WebSocketServer = null,

    const WebSocketServer = @import("websocket.zig").WebSocketServer;

    pub fn init(allocator: std.mem.Allocator, config: Config) !HTTPServer {
        return .{
            .allocator = allocator,
            .io = undefined, // Will be set when Io is available
            .tcp_server = undefined, // Will be set when listening
            .router = try Router.init(allocator),
            .middlewares = .{},
            .config = config,
            .running = false,
            .ws_server = null,
        };
    }

    pub fn setWebSocketServer(server: *HTTPServer, ws_server: *WebSocketServer) void {
        server.ws_server = ws_server;
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
        // 修复: append 不再需要 allocator 参数
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

        // 修复 1: 使用正确的 IP 地址解析 API
        const host_str = try std.fmt.allocPrint(server.allocator, "{s}:{d}", .{
            server.config.host,
            server.config.port,
        });
        defer server.allocator.free(host_str);

        const address = try std.Io.net.IpAddress.parseLiteral(host_str);

        // 修复 2: listen 是静态函数,需要传入 io
        // 增加 kernel_backlog 队列长度,支持更多并发连接
        server.tcp_server = try address.listen(server.io, .{
            .reuse_address = true,
            .kernel_backlog = 4096, // 增加到 4096
        });

        std.log.info("Server listening on {s}:{}\n", .{ server.config.host, server.config.port });

        // Accept loop
        while (server.running) {
            // 修复 3: accept 需要 io 参数
            const stream = server.tcp_server.accept(io) catch |err| {
                std.log.err("Accept failed: {}", .{err});
                continue;
            };

            // Handle connection
            _ = io.async(handleConnection, .{ server, stream });
        }
    }

    pub fn stop(server: *HTTPServer) void {
        server.running = false;
    }
};

fn handleConnection(server: *HTTPServer, stream: Io.net.Stream) void {
    const io = server.io;
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server_struct = http.Server.init(&reader.interface, &writer.interface);

    // Keep-Alive loop
    while (true) {
        var request = http_server_struct.receiveHead() catch |err| {
            // Normal connection close conditions
            if (err == error.EndOfStream or err == error.HttpConnectionClosing) break;
            // ReadFailed 在压测时常见:客户端提前关闭连接、网络错误等
            if (err == error.ReadFailed) {
                std.log.debug("Connection read failed (client may have closed connection): {}", .{err});
                break;
            }
            std.log.err("Request failed: {}", .{err});
            break;
        };

        // 请求日志改为 debug 级别,避免压测时影响性能
        std.log.debug("Received: {s} {s}", .{ @tagName(request.head.method), request.head.target });

        // Check for WebSocket upgrade before handling regular request
        if (server.ws_server) |ws_server| {
            const upgrade = request.upgradeRequested();
            if (upgrade != .none) {
                // Check if this path has a WebSocket handler
                if (ws_server.hasHandler(request.head.target)) {
                    const handler = ws_server.getHandler(request.head.target).?;
                    const sec_websocket_key = switch (upgrade) {
                        .websocket => |key| key orelse {
                            std.log.err("WebSocket upgrade missing Sec-WebSocket-Key header", .{});
                            break;
                        },
                        else => {
                            std.log.err("Invalid WebSocket upgrade request", .{});
                            break;
                        },
                    };

                    // Perform WebSocket upgrade
                    const ws = request.respondWebSocket(.{ .key = sec_websocket_key }) catch |err| {
                        std.log.err("WebSocket upgrade failed: {}", .{err});
                        break;
                    };

                    // Create WebSocket context and run handler
                    const WebSocketContext = @import("websocket.zig").WebSocketContext;

                    // Allocate buffers for WebSocket
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

                    // Run WebSocket handler
                    handler(&context) catch |err| {
                        std.log.err("WebSocket handler error: {}", .{err});
                        context.close();
                    };

                    // WebSocket handler finished, close connection
                    return;
                }
            }
        }

        // Handle request - 传递 writer 引用
        if (handleRequest(server, &request, &writer)) |_| {
            // std.log.info("Response sent", .{});  // 压测时注释掉
        } else |err| {
            std.log.err("Error handling request: {}", .{err});
        }

        if (!request.head.keep_alive) break;
    }
}

fn handleRequest(server: *HTTPServer, request: *http.Server.Request, writer: anytype) !bool {
    var response = try Response.init(server.allocator);
    defer response.deinit();

    var context = try Context.init(server.allocator, server, request, &response);
    defer context.deinit();

    // Find route
    const route = server.router.findRoute(request.head.method, request.head.target) catch |err| {
        std.log.err("Error finding route: {}", .{err});
        context.setStatus(http.Status.internal_server_error);
        try context.json(.{ .error_val = "Internal server error" });
        try response.toHttpResponse(writer, request);
        return true;
    } orelse {
        context.setStatus(http.Status.not_found);
        try context.json(.{ .error_val = "Not found" });
        try response.toHttpResponse(writer, request);
        return true;
    };

    // Execute global middlewares
    for (server.middlewares.items) |middleware| {
        const action = try middleware.vtable.process(middleware, &context);
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
        const action = try middleware.vtable.process(middleware, &context);
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
