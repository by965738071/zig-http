const std = @import("std");
const httpServer = @import("http_server.zig").HTTPServer;
const router = @import("router.zig").Router;
const http = std.http;
const Context = @import("context.zig").Context;
const AuthMiddleware = @import("middleware/auth.zig").AuthMiddleware;
const XSSMiddleware = @import("middleware/xss.zig").XSSMiddleware;
const CSRFMiddleware = @import("middleware/csrf.zig").CSRFMiddleware;
const LoggingMiddleware = @import("middleware/logging.zig").LoggingMiddleware;
const WebSocketServer = @import("websocket.zig").WebSocketServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Zig HTTP Server starting on {s}:{d}", .{ "127.0.0.1", 8080 });
    std.log.info("Components: HTTPServer, Router, Middleware, Context, Response", .{});
    std.log.info("Middlewares: XSS, CSRF, Auth", .{});
    std.log.info("WebSocket: Echo server at /ws/echo", .{});
    std.log.info("Press Ctrl+C to stop the server", .{});

    // Initialize WebSocket server
    var ws_server = WebSocketServer.init(allocator);
    defer ws_server.deinit();

    try ws_server.handle("/ws/echo", websocketEchoHandler);

    var route = try router.init(allocator);
    defer route.deinit();

    try route.addRoute(http.Method.GET, "/abc", handlerHello);

    try route.addRoute(http.Method.GET, "/abc/bcd", handlerBcd);

    // WebSocket test page
    try route.addRoute(http.Method.GET, "/ws", handlerWebSocketPage);

    var server = try httpServer.init(allocator, .{
        .port = 8080,
        .host = "127.0.0.1",
    });
    server.setWebSocketServer(&ws_server);

    var logger_middleware = try LoggingMiddleware.init(allocator);
    defer logger_middleware.deinit();
    server.use(&logger_middleware.middleware);

    // 创建并添加安全中间件
    var xss_middleware = try XSSMiddleware.init(allocator, true);
    defer xss_middleware.deinit();
    server.use(&xss_middleware.middleware);

    var csrf_middleware = try CSRFMiddleware.init(allocator, .{
        .secret = "csrf-secret-key-change-in-production",
        .token_lifetime_sec = 3600,
    });
    defer csrf_middleware.deinit();
    server.use(&csrf_middleware.middleware);

    // 创建并添加 AuthMiddleware
    var auth_middleware = try AuthMiddleware.init(allocator, "my-secret-token");
    defer auth_middleware.deinit();
    // 添加跳过认证的路径白名单
    try auth_middleware.skipPath("/abc");
    try auth_middleware.skipPath("/ws");
    try auth_middleware.skipPath("/ws/echo");
    server.use(&auth_middleware.middleware);

    server.setRouter(route);
    server.start(io) catch |err| {
        std.log.err("Error starting server: {}", .{err});
        return err;
    };
    defer server.deinit();
}

fn handlerHello(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON("Hello, World!");
}

fn handlerBcd(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON("Hello from /abc/bcd!");
}

// WebSocket echo handler
fn websocketEchoHandler(ws: *@import("websocket.zig").WebSocketContext) !void {
    std.log.info("WebSocket client connected", .{});

    // Send welcome message
    try ws.sendText("Welcome to WebSocket echo server!");

    while (true) {
        var msg = try ws.receive();
        defer ws.freeMessage(&msg);

        switch (msg.opcode) {
            .text, .binary => {
                std.log.debug("Received {s} message: {s}", .{
                    @tagName(msg.opcode),
                    msg.data,
                });

                // Echo back
                if (msg.opcode == .text) {
                    try ws.sendText(msg.data);
                } else {
                    try ws.sendBinary(msg.data);
                }
            },
            .ping => {
                try ws.pong(msg.data);
            },
            .connection_close => {
                std.log.info("Client requested close", .{});
                return;
            },
            else => {},
        }
    }
}

// WebSocket test page handler
fn handlerWebSocketPage(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/html");
    try ctx.response.write(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <title>WebSocket Test</title>
        \\    <style>
        \\        body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; background: #f0f0f0; }
        \\        .container { display: flex; flex-direction: column; gap: 20px; }
        \\        #messages { height: 300px; overflow-y: auto; border: 1px solid #ccc; padding: 10px; background: #ffffff; border-radius: 4px; }
        \\        .message { margin: 5px 0; padding: 8px; border-radius: 4px; }
        \\        .sent { background: #e3f2fd; text-align: right; }
        \\        .received { background: #e8f5e9; }
        \\        .system { background: #fff3e0; font-style: italic; }
        \\        input, button { padding: 10px; border-radius: 4px; border: 1px solid #ddd; }
        \\        button { cursor: pointer; background: #4CAF50; color: white; border: none; }
        \\        button:hover { background: #45a049; }
        \\        #status { padding: 10px; border-radius: 4px; margin-bottom: 10px; font-weight: bold; }
        \\        .connected { background: #c8e6c9; color: #2e7d32; }
        \\        .disconnected { background: #ffcdd2; color: #c62828; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>🚀 WebSocket Echo Test</h1>
        \\    <div id="status" class="disconnected">Disconnected</div>
        \\    <div class="container">
        \\        <div id="messages"></div>
        \\        <div style="display: flex; gap: 10px;">
        \\            <input type="text" id="messageInput" placeholder="Type a message..." style="flex: 1;">
        \\            <button onclick="sendMessage()">Send</button>
        \\            <button onclick="disconnect()" style="background: #f44336;">Disconnect</button>
        \\            <button onclick="connect()" style="background: #2196F3;">Reconnect</button>
        \\        </div>
        \\    </div>
        \\    <script>
        \\        let ws = null;
        \\        const status = document.getElementById('status');
        \\        const messages = document.getElementById('messages');
        \\        const input = document.getElementById('messageInput');
        \\
        \\        function connect() {
        \\            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        \\            ws = new WebSocket(`${protocol}//${window.location.host}/ws/echo`);
        \\
        \\            ws.onopen = function() {
        \\                status.textContent = 'Connected';
        \\                status.className = 'connected';
        \\                addMessage('System', 'Connected to server', 'system');
        \\            };
        \\
        \\            ws.onmessage = function(event) {
        \\                addMessage('Server', event.data, 'received');
        \\            };
        \\
        \\            ws.onerror = function(error) {
        \\                addMessage('Error', 'WebSocket error occurred', 'system');
        \\            };
        \\
        \\            ws.onclose = function(event) {
        \\                status.textContent = 'Disconnected';
        \\                status.className = 'disconnected';
        \\                addMessage('System', 'Disconnected from server (code: ' + event.code + ')', 'system');
        \\            };
        \\        }
        \\
        \\        function sendMessage() {
        \\            if (ws && ws.readyState === WebSocket.OPEN) {
        \\                const msg = input.value.trim();
        \\                if (msg) {
        \\                    ws.send(msg);
        \\                    addMessage('You', msg, 'sent');
        \\                    input.value = '';
        \\                }
        \\            } else {
        \\                addMessage('Error', 'Not connected. Click Reconnect.', 'system');
        \\            }
        \\        }
        \\
        \\        function disconnect() {
        \\            if (ws) {
        \\                ws.close();
        \\            }
        \\        }
        \\
        \\        function addMessage(sender, text, type) {
        \\            const div = document.createElement('div');
        \\            div.className = 'message ' + type;
        \\            div.innerHTML = '<strong>' + sender + ':</strong> ' + text;
        \\            messages.appendChild(div);
        \\            messages.scrollTop = messages.scrollHeight;
        \\        }
        \\
        \\        input.addEventListener('keypress', function(e) {
        \\            if (e.key === 'Enter') {
        \\                sendMessage();
        \\            }
        \\        });
        \\
        \\        // Auto-connect on page load
        \\        connect();
        \\    </script>
        \\</body>
        \\</html>
    );
}
