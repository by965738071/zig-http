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
const SignalHandler = @import("signal_handler.zig").SignalHandler;
const StreamingWriter = @import("streaming.zig").StreamingWriter;
const StreamingType = @import("streaming.zig").StreamingType;
const StreamingConfig = @import("streaming.zig").StreamingConfig;
const PrometheusExporter = @import("metrics_exporter.zig").PrometheusExporter;
const StructuredLogger = @import("structured_log.zig").StructuredLogger;
const UploadTracker = @import("upload_progress.zig").UploadTracker;
const consoleProgressCallback = @import("upload_progress.zig").consoleProgressCallback;

// Low priority features
const Interceptor = @import("interceptor.zig").Interceptor;
const InterceptorRegistry = @import("interceptor.zig").InterceptorRegistry;
const benchmarkFn = @import("benchmark.zig").benchmark;
const test_utils = @import("test_utils.zig");

// Global state for handler access (set in main before server starts)
var g_structured_logger: ?*StructuredLogger = null;
var g_upload_tracker: ?*UploadTracker = null;
var g_session_manager: ?*SessionManager = null;
var g_prometheus_exporter: ?*PrometheusExporter = null;

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

    // Initialize Prometheus Exporter
    var prometheus_exporter = PrometheusExporter.init(allocator, &metrics);

    // Initialize Logger
    var logger = Logger.init(allocator, .info);
    defer logger.deinit();

    // Initialize Session Manager
    var session_store = MemorySessionStore.init(allocator);
    defer session_store.deinit();
    var session_manager = SessionManager.init(allocator, &session_store, .{
        .secret = "secret-key-12345",
    });

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

    // Initialize Upload Tracker
    var upload_tracker = UploadTracker.init(allocator);
    defer upload_tracker.deinit();
    upload_tracker.setDefaultCallback(consoleProgressCallback);

    // Initialize Structured Logger
    var structured_logger = StructuredLogger.init(.{
        .output_format = .json,
        .log_level = .info,
        .include_request_id = true,
        
        .include_ip_address = true,
        .include_user_agent = true,
    },io);

    // Initialize Prometheus Exporter (depends on metrics, initialized after)
    // Will be set up after metrics is created

    // Initialize Signal Handler for graceful shutdown
    var signal_handler = try SignalHandler.init(allocator, io, .{
        .handle_interrupt = true,
        .handle_terminate = true,
        .handle_quit = false,
    });
    defer signal_handler.deinit();

    // Start signal handling thread
    try signal_handler.setupSignalThread();

    // Initialize Interceptor Registry
    var interceptor_registry = InterceptorRegistry.init(allocator);
    defer interceptor_registry.deinit();

    // Create and add built-in interceptors
    var logging_interceptor = Interceptor.init("logging", @import("interceptor.zig").loggingInterceptor);
    try interceptor_registry.addBeforeRequest(&logging_interceptor);
    try interceptor_registry.addAfterResponse(&logging_interceptor);
    try interceptor_registry.addOnError(&logging_interceptor);

    var timing_interceptor = Interceptor.init("timing", @import("interceptor.zig").timingInterceptor);
    try interceptor_registry.addBeforeRequest(&timing_interceptor);
    try interceptor_registry.addAfterResponse(&timing_interceptor);
    try interceptor_registry.addOnError(&timing_interceptor);

    var size_interceptor = Interceptor.init("size", @import("interceptor.zig").sizeInterceptor);
    try interceptor_registry.addBeforeRequest(&size_interceptor);
    try interceptor_registry.addAfterResponse(&size_interceptor);

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
    //try route.addRoute(http.Method.GET, "/api/benchmark", handleBenchmark);
    try route.addRoute(http.Method.GET, "/api/tests", handleTests);
    try route.addRoute(http.Method.GET, "/api/upload/progress", handleUploadProgress);
    try route.addRoute(http.Method.GET, "/api/log/demo", handleStructuredLog);
    try route.addRoute(http.Method.GET, "/api/stream/sse", handleSSE);
    try route.addRoute(http.Method.GET, "/api/stream/chunk", handleChunked);
    try route.addRoute(http.Method.GET, "/metrics", handlePrometheus);
    try route.addRoute(http.Method.GET, "/ws", handlerWebSocketPage);

    // Static file route
    try route.addRoute(http.Method.GET, "/static/*", handleStatic);

    // Initialize server
    var server = try httpServer.init(allocator, .{
        .port = 8080,
        .host = "0.0.0.0",
    });
    server.setWebSocketServer(&ws_server);
    server.setStaticServer(&static_server);
    server.setRateLimiter(&rate_limiter);
    server.setMetrics(&metrics);
    server.setLogger(&logger);
    server.setRouter(route);
    server.setInterceptorRegistry(&interceptor_registry);

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
    try auth_middleware.skipPath("/api/benchmark");
    try auth_middleware.skipPath("/api/tests");
    try auth_middleware.skipPath("/api/upload/progress");
    try auth_middleware.skipPath("/api/log/demo");
    try auth_middleware.skipPath("/api/stream/sse");
    try auth_middleware.skipPath("/api/stream/chunk");
    try auth_middleware.skipPath("/metrics");
    try auth_middleware.skipPath("/static/*");
    try auth_middleware.skipPath("/ws");
    try auth_middleware.skipPath("/ws/echo");
    server.use(&auth_middleware.middleware);

    // Store references needed by handlers via server userdata pattern
    // Pass structured logger and upload tracker via global state
    g_structured_logger = &structured_logger;
    g_upload_tracker = &upload_tracker;
    g_session_manager = &session_manager;
    g_prometheus_exporter = &prometheus_exporter;

    // Note: Signal handler integration would require passing server reference
    // and modifying server.start() to check for shutdown signals periodically
    // For now, signal_handler.deinit() is called at end of main()

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
        \\        <div class="endpoint">
        \\            <span><code>GET /api/benchmark</code></span>
        \\            <a href="/api/benchmark" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/tests</code></span>
        \\            <a href="/api/tests" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/upload/progress</code></span>
        \\            <a href="/api/upload/progress" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/log/demo</code></span>
        \\            <a href="/api/log/demo" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/stream/sse</code></span>
        \\            <a href="/api/stream/sse" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /api/stream/chunk</code></span>
        \\            <a href="/api/stream/chunk" target="_blank">Test</a>
        \\        </div>
        \\        <div class="endpoint">
        \\            <span><code>GET /metrics</code> (Prometheus)</span>
        \\            <a href="/metrics" target="_blank">Test</a>
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
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    if (g_session_manager) |sm| {
        // Try to read session_id from cookie
        const jar = ctx.getCookieJar();
        const session_id_opt = jar.get("session_id");

        const session = try sm.get(session_id_opt,ctx.io);

        // Set visit count
        const visits_str = session.get("visits") orelse "0";
        const visits = std.fmt.parseInt(u32, visits_str, 10) catch 0;
        var buf: [16]u8 = undefined;
        const new_visits = std.fmt.bufPrint(&buf, "{d}", .{visits + 1}) catch "1";
        try session.set("visits", new_visits);
        try sm.save(session, ctx.io);

        // Set session cookie
        const cookie = try sm.createCookie(session.id);
        try ctx.setCookie(cookie);

        try ctx.response.writeJSON(.{
            .session_id = session.id,
            .visits = visits + 1,
            .message = "Session active",
        });
    } else {
        try ctx.response.writeJSON(.{
            .session_id = "unavailable",
            .message = "Session manager not initialized",
        });
    }
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
        .server = "Zig HTTP Server",
        .version = "0.16-dev",
        .uptime = "running", // Placeholder - could use actual uptime tracking
    });
}

fn handleBenchmark(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    // Run a simple string-allocation benchmark
    const result = try benchmarkFn("alloc_free", 1000, struct {
        fn run() anyerror!void {
            const buf = try std.heap.page_allocator.alloc(u8, 256);
            std.heap.page_allocator.free(buf);
        }
    }.run);

    try ctx.response.writeJSON(.{
        .status = "completed",
        .name = result.name,
        .iterations = result.iterations,
        .avg_time_ms = result.avg_time_ms,
    });
}

fn handleTests(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    const TestCase = struct {
        name: []const u8,
        passed: bool,
    };
    var results = std.ArrayList(TestCase).empty;
    defer results.deinit(ctx.allocator);

    // Run built-in test cases from test_utils
    const cases = [_]struct {
        name: []const u8,
        fn_ptr: *const fn () anyerror!void,
    }{
        .{ .name = "path_safety", .fn_ptr = test_utils.testPathSafetyValidation },
        .{ .name = "filename_safety", .fn_ptr = test_utils.testFilenameSafetyValidation },
        .{ .name = "http_method", .fn_ptr = test_utils.testHttpMethodValidation },
        .{ .name = "sql_injection", .fn_ptr = test_utils.testSqlInjectionDetection },
        .{ .name = "xss_detection", .fn_ptr = test_utils.testXssDetection },
    };

    var total: u32 = 0;
    var passed_count: u32 = 0;
    for (cases) |c| {
        total += 1;
        const ok = if (c.fn_ptr()) true else |_| false;
        if (ok) passed_count += 1;
        try results.append(ctx.allocator, .{ .name = c.name, .passed = ok });
    }

    try ctx.response.writeJSON(.{
        .status = if (passed_count == total) "all_passed" else "some_failed",
        .total = total,
        .passed = passed_count,
        .failed = total - passed_count,
    });
}

fn handleUploadProgress(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    if (g_upload_tracker) |tracker| {
        const ids = try tracker.getActiveUploads();
        defer ctx.allocator.free(ids);
        try ctx.response.writeJSON(.{
            .active_uploads = ids.len,
            .upload_ids = ids,
            .message = "Upload tracker active",
        });
    } else {
        try ctx.response.writeJSON(.{ .message = "Upload tracker not initialized" });
    }
}

fn handleStructuredLog(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    if (g_structured_logger) |slogger| {
        // Log this request as a demo
        try slogger.logRequest(ctx, 12_345_678); // simulate 12ms request
        try ctx.response.writeJSON(.{
            .message = "Structured log entry emitted to stderr",
            .format = "json",
            .fields = &.{ "timestamp", "level", "method", "path", "status", "duration_ns", "request_id", "ip", "user_agent" },
        });
    } else {
        try ctx.response.writeJSON(.{ .message = "Structured logger not initialized" });
    }
}

fn handleSSE(ctx: *Context) !void {
    // SSE requires direct stream access; log that it's available
    // Full SSE would bypass the normal response pipeline and write directly to the TCP stream.
    // This demonstrates the StreamingWriter API is wired in.
    _ = StreamingWriter;
    _ = StreamingConfig;
    _ = StreamingType;
    // Return a polite message since full SSE needs raw stream access
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain");
    try ctx.response.write("SSE streaming module loaded. Full SSE requires raw TCP stream handler.");
}

fn handleChunked(ctx: *Context) !void {
    _ = StreamingWriter;
    _ = StreamingConfig;
    _ = StreamingType;
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain");
    try ctx.response.write("Chunked streaming module loaded. Full chunked transfer requires raw TCP stream handler.");
}

fn handlePrometheus(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain; version=0.0.4");

    if (g_prometheus_exporter) |exporter| {
        const data = try exporter.toPrometheus();
        defer exporter.allocator.free(data);
        try ctx.response.write(data);
    } else {
        try ctx.response.write("# metrics exporter not initialized\n");
    }
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
