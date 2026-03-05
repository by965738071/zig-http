const std = @import("std");
const http = std.http;
const Context = @import("../core/context.zig").Context;
const StructuredLogger = @import("../structured_log.zig").StructuredLogger;
const PrometheusExporter = @import("../metrics_exporter.zig").PrometheusExporter;
const globals = @import("globals.zig");

/// Handle GET /api/data - return server information
pub fn handleData(ctx: *Context) !void {
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

/// Handle POST /api/submit - process form submissions
/// Using struct-based parameter binding for type safety and clarity

/// Submit request parameters
pub const SubmitRequest = struct {
    /// Parameter from query, form, path, or JSON body
    abc: []const u8,
};

pub fn handleSubmit(ctx: *Context) !void {
    // Bind request parameters to struct
    const data = ctx.bindOrError(SubmitRequest) catch |err| {
        std.log.debug("Parameter binding failed: {}", .{err});
        // Error response is already set by bindOrError
        return err;
    };
    
    ctx.response.setStatus(http.Status.ok);
    
    // Show the bound parameter value
    try ctx.response.writeJSON(.{
        .status = "success",
        .bound_param = data.abc,
        .message = "Parameter binding successful",
        .method = "struct_based_binding",
    });
}

/// Handle GET /api/cookie - cookie operations
pub fn handleCookie(ctx: *Context) !void {
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

/// Handle GET /api/template - template rendering
pub fn handleTemplate(ctx: *Context) !void {
    const Template = @import("../template.zig").Template;
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

/// Handle GET /api/compress - compression test
pub fn handleCompress(ctx: *Context) !void {
    const base_text = "This is a long text that will be compressed using gzip compression algorithm. ";
    const repeated = "Repeated text to make compression more effective. ";

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(ctx.allocator);

    try buffer.appendSlice(ctx.allocator, base_text);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try buffer.appendSlice(ctx.allocator, repeated);
    }
    const data = buffer.items;

    const GzipCompressor = @import("../compression.zig").GzipCompressor;
    var compressor = GzipCompressor.init(ctx.allocator, .default);
    const compressed = try compressor.compress(data);
    defer ctx.allocator.free(compressed);

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain");
    try ctx.response.setHeader("Content-Encoding", "gzip");
    try ctx.response.write(compressed);
}

/// Handle GET /api/metrics - server metrics
pub fn handleMetrics(ctx: *Context) !void {
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

/// Handle GET /api/client - HTTP client capabilities
pub fn handleClient(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.writeJSON(.{
        .status = "success",
        .message = "HTTP client functionality available",
        .capabilities = .{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS" },
    });
}

/// Handle GET /api/secure - protected endpoint
pub fn handleSecure(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .message = "You have access to this protected endpoint!",
        .user = "authenticated_user",
    });
}

/// Handle GET /api/benchmark - benchmark test
pub fn handleBenchmark(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    const benchmarkFn = @import("../benchmark.zig").benchmark;

    const result = try benchmarkFn("alloc_free", 1000, struct {
        fn run() anyerror!void {
            const buf = try std.heap.page_allocator.alloc(u8, 256);
            std.heap.page_allocator.free(buf);
        }
    }.run, ctx.server.io);

    try ctx.response.writeJSON(.{
        .status = "completed",
        .name = result.name,
        .iterations = result.iterations,
        .avg_time_ms = result.avg_time_ms,
    });
}

/// Handle GET /api/tests - run test cases
pub fn handleTests(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    const TestCase = struct {
        name: []const u8,
        passed: bool,
    };
    var results = std.ArrayList(TestCase){};
    defer results.deinit(ctx.allocator);

    const test_utils = @import("../test_utils.zig");
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

/// Handle GET /api/log/demo - structured logging demo
pub fn handleStructuredLog(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    if (globals.g_structured_logger) |slogger| {
        try slogger.logRequest(ctx, 12_345_678);
        try ctx.response.writeJSON(.{
            .message = "Structured log entry emitted to stderr",
            .format = "json",
            .fields = &.{ "timestamp", "level", "method", "path", "status", "duration_ns", "request_id", "ip", "user_agent" },
        });
    } else {
        try ctx.response.writeJSON(.{ .message = "Structured logger not initialized" });
    }
}

/// Handle GET /metrics - Prometheus metrics
pub fn handlePrometheus(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/plain; version=0.0.4");

    if (globals.g_prometheus_exporter) |exporter| {
        const data = try exporter.toPrometheus();
        defer exporter.allocator.free(data);
        try ctx.response.write(data);
    } else {
        try ctx.response.write("# metrics exporter not initialized\n");
    }
}
