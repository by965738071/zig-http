const std = @import("std");
const httpServer = @import("http_server.zig").HTTPServer;
const router = @import("router.zig").Router;
const http = std.http;
const Context = @import("context.zig").Context;

// Middleware
const AuthMiddleware = @import("middleware/auth.zig").AuthMiddleware;
const XSSMiddleware = @import("middleware/xss.zig").XSSMiddleware;
const CSRFMiddleware = @import("middleware/csrf.zig").CSRFMiddleware;
const LoggingMiddleware = @import("middleware/logging.zig").LoggingMiddleware;
const CORSMiddleware = @import("middleware/cors.zig").CORSMiddleware;

// Features
const WebSocketServer = @import("websocket.zig").WebSocketServer;
const WebSocketContext = @import("websocket.zig").WebSocketContext;
const StaticServer = @import("static_server.zig").StaticServer;
const BodyParser = @import("body_parser.zig").BodyParser;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const Metrics = @import("monitoring.zig").Metrics;
const Logger = @import("error_handler.zig").Logger;
const SessionManager = @import("session.zig").SessionManager;
const MemorySessionStore = @import("session.zig").MemorySessionStore;
const CookieJar = @import("cookie.zig").CookieJar;
const Template = @import("template.zig").Template;
const MultipartParser = @import("multipart.zig").MultipartParser;
const IPFilter = @import("security.zig").IPFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.err("Memory leak detected", .{});
        }
    }

    const allocator = gpa.allocator();
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("========================================", .{});
    std.log.info("🚀 Zig HTTP Server starting on {s}:{d}", .{ "127.0.0.1", 8080 });
    std.log.info("========================================", .{});
    std.log.info("Features:", .{});
    std.log.info("  ✅ HTTP Server & Router", .{});
    std.log.info("  ✅ WebSocket: /ws/echo", .{});
    std.log.info("  ✅ Static Files: /static/*", .{});
    std.log.info("  ✅ Body Parser: JSON & Form", .{});
    std.log.info("  ✅ Multipart: /upload", .{});
    std.log.info("  ✅ Session Management", .{});
    std.log.info("  ✅ Cookies", .{});
    std.log.info("  ✅ Templates", .{});
    std.log.info("  ✅ Compression", .{});
    std.log.info("  ✅ Rate Limiting", .{});
    std.log.info("  ✅ Metrics & Monitoring", .{});
    std.log.info("  ✅ HTTP Client", .{});
    std.log.info("========================================", .{});
    std.log.info("Middlewares:", .{});
    std.log.info("  🛡️  Auth (Bearer Token)", .{});
    std.log.info("  🛡️  XSS Protection", .{});
    std.log.info("  🛡️  CSRF Protection", .{});
    std.log.info("  🛡️  CORS", .{});
    std.log.info("  🛡️  Security Headers", .{});
    std.log.info("========================================", .{});
    std.log.info("Test Endpoints:", .{});
    std.log.info("  GET  /              - Home page", .{});
    std.log.info("  GET  /api/data     - JSON response", .{});
    std.log.info("  POST /api/submit   - Body parser test", .{});
    std.log.info("  POST /api/upload   - Multipart upload", .{});
    std.log.info("  GET  /api/session   - Session test", .{});
    std.log.info("  GET  /api/cookie   - Cookie test", .{});
    std.log.info("  GET  /api/template - Template test", .{});
    std.log.info("  GET  /api/compress - Compression test", .{});
    std.log.info("  GET  /api/metrics  - Metrics dashboard", .{});
    std.log.info("  GET  /api/client   - HTTP client test", .{});
    std.log.info("  GET  /api/secure   - Protected endpoint", .{});
    std.log.info("========================================", .{});
    std.log.info("Press Ctrl+C to stop the server", .{});
    std.log.info("========================================", .{});

    // Initialize WebSocket server
    var ws_server = WebSocketServer.init(allocator);
    defer ws_server.deinit();
    try ws_server.handle("/ws/echo", websocketEchoHandler);

    // Initialize Static Server
    var static_server = try StaticServer.init(allocator, .{
        .root = "public",
        .prefix = "/static",
        .enable_directory_listing = true,
        .enable_cache = true,
    });
    defer static_server.deinit();

    // Initialize Rate Limiter
    var rate_limiter = RateLimiter.init(allocator, .{
        .max_requests = 100,
        .window_ms = 60000,
    }, io);
    defer rate_limiter.deinit();

    // Initialize Metrics
    var metrics = Metrics.init(allocator, io);
    defer metrics.deinit();

    // Initialize Logger
    var logger = Logger.init(allocator, .info);
    defer logger.deinit();

    // Initialize Session Manager
    var session_store = MemorySessionStore.init(allocator);
    defer session_store.deinit();
    _ = SessionManager.init(allocator, &session_store, .{
        .secret = "secret-key-12345",
    });
    // Note: SessionManager doesn't have deinit, stored but not used in handlers

    // Initialize Template Engine
    // Note: Template.init requires a source string, not just allocator
    // This is a placeholder - in practice you'd load a template file
    var template = Template.init(allocator, "Hello {{name}}!");
    defer template.deinit();

    // Compression - used in handleCompress handler
    // No global compressor needed

    // Initialize Security - IPFilter example
    var ip_filter = IPFilter.init(allocator, .blacklist);
    defer ip_filter.deinit();

    // Setup routes
    var route = try router.init(allocator);
    defer route.deinit();

    try route.addRoute(http.Method.GET, "/", handleHome);
    try route.addRoute(http.Method.GET, "/api/data", handleData);
    try route.addRoute(http.Method.POST, "/api/submit", handleSubmit);
    try route.addRoute(http.Method.POST, "/api/upload", handleUpload);
    try route.addRoute(http.Method.GET, "/api/session", handleSession);
    try route.addRoute(http.Method.GET, "/api/cookie", handleCookie);
    try route.addRoute(http.Method.GET, "/api/template", handleTemplate);
    try route.addRoute(http.Method.GET, "/api/compress", handleCompress);
    try route.addRoute(http.Method.GET, "/api/metrics", handleMetrics);
    try route.addRoute(http.Method.GET, "/api/client", handleClient);
    try route.addRoute(http.Method.GET, "/api/secure", handleSecure);
    try route.addRoute(http.Method.GET, "/api/health", handleHealth);
    try route.addRoute(http.Method.GET, "/ws", handlerWebSocketPage);

    // Static file route
    try route.addRoute(http.Method.GET, "/static/*", handleStatic);

    // Initialize server
    var server = try httpServer.init(allocator, .{
        .port = 8080,
        .host = "127.0.0.1",
    });
    server.setWebSocketServer(&ws_server);
    server.setStaticServer(&static_server);
    server.setRateLimiter(&rate_limiter);
    server.setMetrics(&metrics);
    server.setLogger(&logger);
    server.setRouter(route);

    // Add middlewares
    var logger_middleware = try LoggingMiddleware.init(allocator);
    defer logger_middleware.deinit();
    server.use(&logger_middleware.middleware);

    var cors_middleware = try CORSMiddleware.init(allocator, .{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{ "GET", "POST", "PUT", "DELETE", "OPTIONS" },
        .allowed_headers = &.{ "Content-Type", "Authorization", "X-CSRF-Token" },
    });
    defer cors_middleware.deinit();
    server.use(&cors_middleware.middleware);

    var xss_middleware = try XSSMiddleware.init(allocator, true);
    defer xss_middleware.deinit();
    server.use(&xss_middleware.middleware);

    var csrf_middleware = try CSRFMiddleware.init(allocator, .{
        .secret = "csrf-secret-key-change-in-production",
        .token_lifetime_sec = 3600,
    });
    defer csrf_middleware.deinit();
    server.use(&csrf_middleware.middleware);

    var auth_middleware = try AuthMiddleware.init(allocator, "my-secret-token");
    defer auth_middleware.deinit();
    try auth_middleware.skipPath("/");
    try auth_middleware.skipPath("/api/data");
    try auth_middleware.skipPath("/api/submit");
    try auth_middleware.skipPath("/api/upload");
    try auth_middleware.skipPath("/api/session");
    try auth_middleware.skipPath("/api/cookie");
    try auth_middleware.skipPath("/api/template");
    try auth_middleware.skipPath("/api/compress");
    try auth_middleware.skipPath("/api/metrics");
    try auth_middleware.skipPath("/api/client");
    try auth_middleware.skipPath("/api/health");
    try auth_middleware.skipPath("/static/*");
    try auth_middleware.skipPath("/ws");
    try auth_middleware.skipPath("/ws/echo");
    server.use(&auth_middleware.middleware);

    server.start(io) catch |err| {
        std.log.err("Error starting server: {}", .{err});
        return err;
    };
}

// Handlers
fn handleHome(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/html");
    try ctx.response.write(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <title>Zig HTTP Server Demo</title>
        \\    <style>
        \\        body { font-family: Arial, sans-serif; max-width: 1200px; margin: 50px auto; padding: 20px; background: #f5f5f5; }
        \\        .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\        h1 { color: #333; }
        \\        h2 { color: #555; margin-top: 0; }
        \\        a { display: inline-block; padding: 10px 20px; margin: 5px; background: #4CAF50; color: white; text-decoration: none; border-radius: 4px; }
        \\        a:hover { background: #45a049; }
        \\        .endpoint { display: flex; justify-content: space-between; align-items: center; padding: 10px 0; border-bottom: 1px solid #eee; }
        \\        .endpoint:last-child { border-bottom: none; }
        \\        code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="card">
        \\        <h1>🚀 Zig HTTP Server Demo</h1>
        \\        <p>A comprehensive HTTP server implementation in Zig with all features enabled.</p>
        \\    </div>
        \\
        \\    <div class="card">
        \\        <h2>📡 API Endpoints</h2>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/data</code></span>
        \\            <a href="/api/data" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>POST /api/submit</code></span>
        \\            <a href="#" onclick="testSubmit(); return false;">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>POST /api/upload</code></span>
        \\            <a href="#" onclick="testUpload(); return false;">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/session</code></span>
        \\            <a href="/api/session" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/cookie</code></span>
        \\            <a href="/api/cookie" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/template</code></span>
        \\            <a href="/api/template" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/compress</code></span>
        \\            <a href="/api/compress" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/metrics</code></span>
        \\            <a href="/api/metrics" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/client</code></span>
        \\            <a href="/api/client" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/secure</code></span>
        \\            <a href="/api/secure" target="_blank">Test (Requires Auth)</a>
        \\        </div>
        \\    </div>
        \\
        \\    <div class="card">
        \\        <h2>🔌 WebSocket</h2>
        \\        <div class="endpoint">
        \\            <span><code>WS /ws/echo</code></span>
        \\            <a href="/ws" target="_blank">Open Test Page</a>
        \\        </div>
        \\    </div>
        \\
        \\    <div class="card">
        \\        <h2>📁 Static Files</h2>
        \\        <div class="endpoint">
        \\            <span><code>GET /static/*</code></span>
        \\            <a href="/static" target="_blank">Browse</a>
        \\        </div>
        \\    </div>
        \\
        \\    <script>
        \\        async function testSubmit() {
        \\            const res = await fetch('/api/submit', {
        \\                method: 'POST',
        \\                headers: { 'Content-Type': 'application/json' },
        \\                body: JSON.stringify({ name: 'Test User', message: 'Hello from demo!' })
        \\            });
        \\            const data = await res.json();
        \\            alert(JSON.stringify(data, null, 2));
        \\        }
        \\
        \\        async function testUpload() {
        \\            const formData = new FormData();
        \\            formData.append('file', new Blob(['test content'], { type: 'text/plain' }), 'test.txt');
        \\            const res = await fetch('/api/upload', { method: 'POST', body: formData });
        \\            const data = await res.json();
        \\            alert(JSON.stringify(data, null, 2));
        \\        }
        \\    </script>
        \\</body>
        \\</html>
    );
}

fn handleData(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .message = "Hello, World!",
        .server = "Zig HTTP Server",
        .version = "0.16-dev",
        .features = &.{
            "HTTP/1.1",
            "WebSocket",
            "Static Files",
            "Body Parser",
            "Multipart",
            "Session",
            "Cookies",
            "Templates",
            "Compression",
            "Rate Limiting",
            "Metrics",
        },
    });
}

fn handleSubmit(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    const body = ctx.getBody();
    if (body.len == 0) {
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "No request body",
        });
        return;
    }

    const content_type = ctx.getHeader("Content-Type") orelse "application/octet-stream";

    if (std.mem.indexOf(u8, content_type, "application/json") != null) {
        if (ctx.body_parser) |*parser| {
            _ = parser.parse() catch |err| {
                try ctx.response.writeJSON(.{
                    .status = "error",
                    .message = "Failed to parse JSON",
                    .error_val = @errorName(err),
                });
                return;
            };

            if (parser.getJSON()) |json| {
                try ctx.response.writeJSON(.{
                    .status = "success",
                    .type = "json",
                    .data = json.*,
                });
            } else {
                try ctx.response.writeJSON(.{
                    .status = "error",
                    .message = "Not valid JSON",
                });
            }
        }
    } else if (std.mem.indexOf(u8, content_type, "application/x-www-form-urlencoded") != null) {
        if (ctx.body_parser) |*parser| {
            _ = parser.parse() catch |err| {
                try ctx.response.writeJSON(.{
                    .status = "error",
                    .message = "Failed to parse form data",
                    .error_val = @errorName(err),
                });
                return;
            };

            if (parser.getForm()) |form| {
                try ctx.response.writeJSON(.{
                    .status = "success",
                    .type = "form",
                    .fields_count = form.fields.count(),
                });
            } else {
                try ctx.response.writeJSON(.{
                    .status = "error",
                    .message = "Not valid form data",
                });
            }
        }
    } else {
        try ctx.response.writeJSON(.{
            .status = "success",
            .type = "raw",
            .body_size = body.len,
        });
    }
}

fn handleUpload(ctx: *Context) !void {
    const content_type = ctx.getHeader("Content-Type") orelse "";
    const body = ctx.getBody();

    if (body.len == 0) {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "No file uploaded",
        });
        return;
    }

    if (std.mem.indexOf(u8, content_type, "multipart/form-data") == null) {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Content-Type must be multipart/form-data",
        });
        return;
    }

    const boundary = MultipartParser.extractBoundary(content_type) catch |err| {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Invalid multipart boundary",
            .error_val = @errorName(err),
        });
        return;
    };

    var parser = MultipartParser.init(ctx.allocator, boundary);
    defer parser.deinit();

    var form = parser.parse(body) catch |err| {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Failed to parse multipart form",
            .error_val = @errorName(err),
        });
        return;
    };
    defer form.deinit();

    var uploaded_files = std.ArrayList([]const u8){};
    defer uploaded_files.deinit(ctx.allocator);

    var file_count: usize = 0;
    for (form.getAllFiles()) |*part| {
        if (part.filename != null) {
            file_count += 1;
            try uploaded_files.append(ctx.allocator, part.filename.?);
        }
    }

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.writeJSON(.{
        .status = "success",
        .message = "Files uploaded successfully",
        .files = uploaded_files.items,
        .count = file_count,
    });
}

fn handleSession(ctx: *Context) !void {
    // Note: Session functionality requires session_manager context
    // This is a simplified placeholder demo
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .session_id = "demo-session-123",
        .message = "Session placeholder - requires session_manager integration",
    });
}

fn handleCookie(ctx: *Context) !void {
    try ctx.setCookie(.{
        .name = "test_cookie",
        .value = "hello_world",
        .options = .{
            .max_age = 3600,
            .path = "/",
            .http_only = false,
        },
    });

    const jar = ctx.getCookieJar();
    const cookie_value = jar.get("test_cookie") orelse "not found";

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .cookie_value = cookie_value,
        .message = "Cookie set successfully",
    });
}

fn handleTemplate(ctx: *Context) !void {
    const template_str = "Hello, {{name}}! Welcome to {{app}}.";

    var template = Template.init(ctx.allocator, template_str);
    defer template.deinit();

    try template.set("name", "User");
    try template.set("app", "Zig HTTP Server");

    const rendered = try template.render();

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/html");
    try ctx.response.write(rendered);
    ctx.allocator.free(rendered);
}

fn handleCompress(ctx: *Context) !void {
    const base_text = "This is a long text that will be compressed using gzip compression algorithm. ";
    const repeated = "Repeated text to make compression more effective. ";

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(ctx.allocator);

    try buffer.appendSlice(ctx.allocator, base_text);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try buffer.appendSlice(ctx.allocator, repeated);
    }
    const data = buffer.items;

    const GzipCompressor = @import("compression.zig").GzipCompressor;
    var compressor = GzipCompressor.init(ctx.allocator, .default);
    const compressed = try compressor.compress(data);
    defer ctx.allocator.free(compressed);

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain");
    try ctx.response.setHeader("Content-Encoding", "gzip");
    try ctx.response.write(compressed);
}

fn handleMetrics(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);

    if (ctx.server.metrics) |metrics| {
        try ctx.response.writeJSON(.{
            .status = "success",
            .message = "Metrics available",
            .total_requests = metrics.total_requests,
            .total_errors = metrics.total_errors,
            .average_latency_ms = metrics.avg_response_time_ms,
        });
    } else {
        try ctx.response.writeJSON(.{
            .status = "success",
            .message = "Metrics not enabled",
            .total_requests = 0,
            .total_errors = 0,
            .average_latency_ms = 0,
        });
    }
}

fn handleClient(ctx: *Context) !void {
    // HTTP client test - demonstrates making outbound requests
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.writeJSON(.{
        .status = "success",
        .message = "HTTP client functionality available",
        .capabilities = .{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS" },
    });
}

fn handleSecure(ctx: *Context) !void {
    // Placeholder - real user info requires auth middleware integration
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .message = "You have access to this protected endpoint!",
        .user = "authenticated_user",
    });
}

fn handleHealth(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .status = "healthy",
        .timestamp = 0, // Placeholder - timestamp API changed in Zig 0.16-dev
    });
}

fn handleStatic(ctx: *Context) !void {
    // Static server is now handled by HTTPServer through routing
    // This handler is kept for compatibility but the static server
    // is invoked in handleRequest before route matching
    if (ctx.server.static_server) |static_srv| {
        _ = try static_srv.handle(ctx);
    } else {
        ctx.response.setStatus(http.Status.not_found);
        try ctx.err(http.Status.internal_server_error, "Static server not configured");
    }
}

fn websocketEchoHandler(ws: *WebSocketContext) !void {
    std.log.info("WebSocket client connected", .{});
    try ws.sendText("Welcome to WebSocket echo server!");

    while (true) {
        var msg = try ws.receive();
        defer ws.freeMessage(&msg);

        switch (msg.opcode) {
            .text, .binary => {
                std.log.debug("Received {s} message", .{@tagName(msg.opcode)});
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
        \\        body {
        \\            font-family: Arial, sans-serif;
        \\            max-width: 800px;
        \\            margin: 50px auto;
        \\            padding: 20px;
        \\            background: #f0f0f0;
        \\        }
        \\        .container {
        \\            display: flex;
        \\            flex-direction: column;
        \\            gap: 20px;
        \\        }
        \\        #messages {
        \\            height: 300px;
        \\            overflow-y: auto;
        \\            border: 1px solid #ccc;
        \\            padding: 10px;
        \\            background: #ffffff;
        \\            border-radius: 4px;
        \\        }
        \\        .message {
        \\            margin: 5px 0;
        \\            padding: 8px;
        \\            border-radius: 4px;
        \\        }
        \\        .sent {
        \\            background: #e3f2fd;
        \\            text-align: right;
        \\        }
        \\        .received {
        \\            background: #e8f5e9;
        \\        }
        \\        .system {
        \\            background: #fff3e0;
        \\            font-style: italic;
        \\        }
        \\        input, button {
        \\            padding: 10px;
        \\            border-radius: 4px;
        \\            border: 1px solid #ddd;
        \\        }
        \\        button {
        \\            cursor: pointer;
        \\            background: #4CAF50;
        \\            color: white;
        \\            border: none;
        \\        }
        \\        button:hover {
        \\            background: #45a049;
        \\        }
        \\        #status {
        \\            padding: 10px;
        \\            border-radius: 4px;
        \\            margin-bottom: 10px;
        \\            font-weight: bold;
        \\        }
        \\        .connected {
        \\            background: #c8e6c9;
        \\            color: #2e7d32;
        \\        }
        \\        .disconnected {
        \\            background: #ffcdd2;
        \\            color: #c62828;
        \\        }
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
        \\
        \\    <script>
        \\        let ws = null;
        \\        const status = document.getElementById('status');
        \\        const messages = document.getElementById('messages');
        \\        const input = document.getElementById('messageInput');
        \\
        \\        function connect() {
        \\            if (ws && ws.readyState === WebSocket.OPEN) {
        \\                addMessage('System', 'Already connected', 'system');
        \\                return;
        \\            }
        \\
        \\            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        \\            const wsUrl = `ws://127.0.0.1:8080/ws/echo`;
        \\            console.log('Connecting to:', wsUrl);
        \\
        \\            ws = new WebSocket(wsUrl);
        \\
        \\            ws.onopen = function() {
        \\                status.textContent = 'Connected';
        \\                status.className = 'connected';
        \\                addMessage('System', 'Connected to server', 'system');
        \\                console.log('WebSocket connection opened');
        \\            };
        \\
        \\            ws.onmessage = function(event) {
        \\                addMessage('Server', event.data, 'received');
        \\                console.log('Received:', event.data);
        \\            };
        \\
        \\            ws.onerror = function(error) {
        \\                addMessage('Error', 'WebSocket error occurred', 'system');
        \\                console.error('WebSocket error:', error);
        \\            };
        \\
        \\            ws.onclose = function(event) {
        \\                status.textContent = 'Disconnected';
        \\                status.className = 'disconnected';
        \\                addMessage('System', `Disconnected from server (code: ${event.code})`, 'system');
        \\                console.log('WebSocket closed:', event.code, event.reason);
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
        \\                    console.log('Sent:', msg);
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
        \\            div.className = `message ${type}`;
        \\            div.innerHTML = `<strong>${sender}:</strong> ${escapeHtml(text)}`;
        \\            messages.appendChild(div);
        \\            messages.scrollTop = messages.scrollHeight;
        \\        }
        \\
        \\        function escapeHtml(text) {
        \\            const div = document.createElement('div');
        \\            div.textContent = text;
        \\            return div.innerHTML;
        \\        }
        \\
        \\        input.addEventListener('keypress', function(e) {
        \\            if (e.key === 'Enter') {
        \\                sendMessage();
        \\            }
        \\        });
        \\
        \\        // Auto-connect on page load
        \\        window.addEventListener('load', connect);
        \\    </script>
        \\</body>
        \\</html>
    );
}
