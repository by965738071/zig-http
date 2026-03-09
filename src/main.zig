const std = @import("std");
const builtin = @import("builtin");
const httpServer = @import("core/http_server.zig").HTTPServer;
const router = @import("core/router.zig").Router;
const http = std.http;
const Context = @import("core/context.zig").Context;
const Logger = @import("core/error_handler.zig").Logger;

// Middleware
const AuthMiddleware = @import("features/middleware/auth.zig").AuthMiddleware;
const XSSMiddleware = @import("features/middleware/xss.zig").XSSMiddleware;
const CSRFMiddleware = @import("features/middleware/csrf.zig").CSRFMiddleware;
const LoggingMiddleware = @import("features/middleware/logging.zig").LoggingMiddleware;
const CORSMiddleware = @import("features/middleware/cors.zig").CORSMiddleware;

// Features
const WebSocketServer = @import("features/websocket.zig").WebSocketServer;
const StaticServer = @import("features/static_server.zig").StaticServer;
const RateLimiter = @import("features/rate_limiter.zig").RateLimiter;
const Metrics = @import("features/monitoring.zig").Metrics;
const SessionManager = @import("features/session.zig").SessionManager;
const MemorySessionStore = @import("features/session.zig").MemorySessionStore;
const Template = @import("features/template.zig").Template;
const IPFilter = @import("features/security.zig").IPFilter;
const SignalHandler = @import("features/signal_handler.zig").SignalHandler;
const PrometheusExporter = @import("features/metrics_exporter.zig").PrometheusExporter;
const StructuredLogger = @import("features/structured_log.zig").StructuredLogger;
const UploadTracker = @import("features/upload_progress.zig").UploadTracker;
const consoleProgressCallback = @import("features/upload_progress.zig").consoleProgressCallback;

// Low priority features
const Interceptor = @import("features/interceptor.zig").Interceptor;
const InterceptorRegistry = @import("features/interceptor.zig").InterceptorRegistry;

// Handlers
const handlers_home = @import("home.zig").handleHome;
const handlers_health = @import("health.zig").handleHealth;
const handlers_api = @import("api.zig");
const handlers_upload = @import("upload.zig");
const handlers_static = @import("static.zig").handleStatic;
const WebSocketContext = @import("features/websocket.zig").WebSocketContext;

// Global state for handler access (now defined in handlers/globals.zig)

pub fn main(init: std.process.Init) !void {
    _ = init;
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

    // Initialize servers and features
    var server_config = try initializeServerComponents(allocator, io);
    defer deinitServerComponents(&server_config);

    // Initialize router and register routes
    var route = try setupRoutes(allocator);
    defer route.deinit();

    // Configure HTTP server
    var server = try httpServer.init(allocator, io, .{
        .port = 8080,
        .host = "0.0.0.0",
    });
    //server.setWebSocketServer(server_config.ws_server);
    //server.setStaticServer(server_config.static_server);
    //server.setRateLimiter(server_config.rate_limiter);
    //server.setMetrics(server_config.metrics);
    //server.setLogger(server_config.logger);
    //server.setRouter(route);
    //server.setInterceptorRegistry(server_config.interceptor_registry);

    // Configure middlewares
    try setupMiddlewares(allocator, &server);

    // Set global references
    const handlers_globals = @import("globals.zig");
    handlers_globals.g_structured_logger = server_config.structured_logger;
    handlers_globals.g_upload_tracker = server_config.upload_tracker;
    handlers_globals.g_prometheus_exporter = server_config.prometheus_exporter;

    // Set signal handler reference in server for graceful shutdown
    //server.setSignalHandler(&server_config.signal_handler);

    // Start server
    try server.start(io);
}

/// Server configuration struct
const ServerConfig = struct {
    ws_server: *WebSocketServer,
    static_server: *StaticServer,
    rate_limiter: *RateLimiter,
    metrics: *Metrics,
    logger: *Logger,
    template: *Template,
    structured_logger: *StructuredLogger,
    upload_tracker: *UploadTracker,
    prometheus_exporter: *PrometheusExporter,
    interceptor_registry: *InterceptorRegistry,
    logging_interceptor: *Interceptor,
    timing_interceptor: *Interceptor,
    size_interceptor: *Interceptor,
    ip_filter: IPFilter,
    signal_handler: SignalHandler,
};

/// Initialize all server components
fn initializeServerComponents(allocator: std.mem.Allocator, io: std.Io) !ServerConfig {
    // WebSocket server
    var ws_server = WebSocketServer.init(allocator);

    // Simple WebSocket echo handler
    const echoHandler = struct {
        fn echo(ws: *WebSocketContext) !void {
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
                    else => continue,
                }
            }
        }
    }.echo;
    try ws_server.handle("/ws/echo", echoHandler);

    // Static server
    var static_server = try StaticServer.init(allocator, .{
        .root = "public",
        .prefix = "/static",
        .enable_directory_listing = true,
        .enable_cache = true,
    });

    // Rate limiter - allocate on heap to avoid dangling pointer
    const rate_limiter = try allocator.create(RateLimiter);
    rate_limiter.* = RateLimiter.init(allocator, .{
        .max_requests = 100,
        .window_ms = 60000,
    }, io);

    // Metrics - allocate on heap
    const metrics = try allocator.create(Metrics);
    metrics.* = Metrics.init(allocator, io);

    // Logger - allocate on heap
    const logger = try allocator.create(Logger);
    logger.* = Logger.init(allocator, .info);

    // Template engine - allocate on heap
    const template = try allocator.create(Template);
    template.* = Template.init(allocator, "Hello {{name}}!");

    // Structured logger - allocate on heap
    const structured_logger = try allocator.create(StructuredLogger);
    structured_logger.* = StructuredLogger.init(.{
        .output_format = .json,
        .log_level = .info,
        .include_request_id = true,
        .include_ip_address = true,
        .include_user_agent = true,
    }, io);

    // Upload tracker - allocate on heap
    const upload_tracker = try allocator.create(UploadTracker);
    upload_tracker.* = UploadTracker.init(allocator);
    upload_tracker.setDefaultCallback(consoleProgressCallback);

    // Prometheus exporter - allocate on heap
    const prometheus_exporter = try allocator.create(PrometheusExporter);
    prometheus_exporter.* = PrometheusExporter.init(allocator, metrics);

    // Interceptor registry - allocate on heap to avoid dangling pointer
    const interceptor_registry = try allocator.create(InterceptorRegistry);
    interceptor_registry.* = InterceptorRegistry.init(allocator);

    // Built-in interceptors - allocate on heap
    const logging_interceptor = try allocator.create(Interceptor);
    logging_interceptor.* = Interceptor.init("logging", @import("features/interceptor.zig").loggingInterceptor);
    try interceptor_registry.addBeforeRequest(logging_interceptor);
    try interceptor_registry.addAfterResponse(logging_interceptor);
    try interceptor_registry.addOnError(logging_interceptor);

    const timing_interceptor = try allocator.create(Interceptor);
    timing_interceptor.* = Interceptor.init("timing", @import("features/interceptor.zig").timingInterceptor);
    try interceptor_registry.addBeforeRequest(timing_interceptor);
    try interceptor_registry.addAfterResponse(timing_interceptor);
    try interceptor_registry.addOnError(timing_interceptor);

    const size_interceptor = try allocator.create(Interceptor);
    size_interceptor.* = Interceptor.init("size", @import("features/interceptor.zig").sizeInterceptor);
    try interceptor_registry.addBeforeRequest(size_interceptor);
    try interceptor_registry.addAfterResponse(size_interceptor);

    // Security features
    const ip_filter = IPFilter.init(allocator, .blacklist);

    // Signal handler
    var signal_handler = try SignalHandler.init(allocator, io, .{
        .handle_interrupt = true,
        .handle_terminate = true,
        .handle_quit = false,
    });
    try signal_handler.setupSignalThread();

    return ServerConfig{
        .ws_server = &ws_server,
        .static_server = &static_server,
        .rate_limiter = rate_limiter,
        .metrics = metrics,
        .logger = logger,
        .template = template,
        .structured_logger = structured_logger,
        .upload_tracker = upload_tracker,
        .prometheus_exporter = prometheus_exporter,
        .interceptor_registry = interceptor_registry,
        .logging_interceptor = logging_interceptor,
        .timing_interceptor = timing_interceptor,
        .size_interceptor = size_interceptor,
        .ip_filter = ip_filter,
        .signal_handler = signal_handler,
    };
}

/// Deinitialize server components
fn deinitServerComponents(config: *ServerConfig) void {
    config.ws_server.deinit();
    config.static_server.deinit();
    config.rate_limiter.deinit();
    config.metrics.deinit();
    config.logger.deinit();
    config.template.deinit();
    config.upload_tracker.deinit();

    // Get allocator for freeing heap-allocated objects
    const allocator = config.rate_limiter.allocator;

    // Free heap-allocated components
    allocator.destroy(config.rate_limiter);
    allocator.destroy(config.metrics);
    allocator.destroy(config.logger);
    allocator.destroy(config.template);
    allocator.destroy(config.upload_tracker);
    allocator.destroy(config.structured_logger);
    allocator.destroy(config.prometheus_exporter);

    // Free interceptor objects first, then registry
    allocator.destroy(config.logging_interceptor);
    allocator.destroy(config.timing_interceptor);
    allocator.destroy(config.size_interceptor);
    config.interceptor_registry.deinit();
    allocator.destroy(config.interceptor_registry);

    config.ip_filter.deinit();
    config.signal_handler.deinit();
}

/// Setup routes
fn setupRoutes(allocator: std.mem.Allocator) !router {
    var route = try router.init(allocator);

    try route.addRoute(http.Method.GET, "/", handlers_home);
    try route.addRoute(http.Method.GET, "/api/health", handlers_health);

    // API routes
    try route.addRoute(http.Method.GET, "/api/data", handlers_api.handleData);
    // try route.addRoute(http.Method.POST, "/api/submit", handlers_api.handleSubmit);
    // try route.addRoute(http.Method.POST, "/api/upload", handlers_upload.handleUpload);
    // try route.addRoute(http.Method.GET, "/api/cookie", handlers_api.handleCookie);
    // try route.addRoute(http.Method.GET, "/api/template", handlers_api.handleTemplate);
    // try route.addRoute(http.Method.GET, "/api/compress", handlers_api.handleCompress);
    // try route.addRoute(http.Method.GET, "/api/metrics", handlers_api.handleMetrics);
    // try route.addRoute(http.Method.GET, "/api/client", handlers_api.handleClient);
    // try route.addRoute(http.Method.GET, "/api/secure", handlers_api.handleSecure);
    // try route.addRoute(http.Method.GET, "/api/benchmark", handlers_api.handleBenchmark);
    // try route.addRoute(http.Method.GET, "/api/tests", handlers_api.handleTests);
    // try route.addRoute(http.Method.GET, "/api/upload/progress", handlers_upload.handleUploadProgress);
    // try route.addRoute(http.Method.GET, "/api/log/demo", handlers_api.handleStructuredLog);
    // try route.addRoute(http.Method.GET, "/metrics", handlers_api.handlePrometheus);

    // Static files route
    // try route.addRoute(http.Method.GET, "/static/*", handlers_static);

    return route;
}

/// Setup middlewares
fn setupMiddlewares(allocator: std.mem.Allocator, server: *httpServer) !void {
    // Logger middleware - DO NOT defer, HTTPServer will manage lifecycle
    var logger_middleware = try LoggingMiddleware.init(allocator);
    server.use(&logger_middleware.middleware);

    // CORS middleware - DO NOT defer, HTTPServer will manage lifecycle
    var cors_middleware = try CORSMiddleware.init(allocator, .{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{ "GET", "POST", "PUT", "DELETE", "OPTIONS" },
        .allowed_headers = &.{ "Content-Type", "Authorization", "X-CSRF-Token" },
    });
    server.use(&cors_middleware.middleware);

    // XSS middleware - DO NOT defer, HTTPServer will manage lifecycle
    var xss_middleware = try XSSMiddleware.init(allocator, true);
    server.use(&xss_middleware.middleware);

    // CSRF middleware - DO NOT defer, HTTPServer will manage lifecycle
    var csrf_middleware = try CSRFMiddleware.init(allocator, .{
        .secret = "csrf-secret-key-change-in-production",
        .token_lifetime_sec = 3600,
    });
    try csrf_middleware.skipPath("/api/submit");
    try csrf_middleware.skipPath("/api/upload");
    server.use(&csrf_middleware.middleware);

    // Auth middleware with skip paths - DO NOT defer, HTTPServer will manage lifecycle
    var auth_middleware = try AuthMiddleware.init(allocator, "my-secret-token");

    const skip_paths = &[_][]const u8{
        "/",               "/api/data",         "/api/submit",   "/api/upload",          "/api/session",
        "/api/cookie",     "/api/template",     "/api/compress", "/api/metrics",         "/api/client",
        "/api/health",     "/api/benchmark",    "/api/tests",    "/api/upload/progress", "/api/log/demo",
        "/api/stream/sse", "/api/stream/chunk", "/metrics",      "/static/*",            "/ws",
        "/ws/echo",
    };

    for (skip_paths) |path| {
        try auth_middleware.skipPath(path);
    }
    server.use(&auth_middleware.middleware);
}
