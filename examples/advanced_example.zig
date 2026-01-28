/// Advanced features example demonstrating rate limiting, security, and monitoring
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = @import("context.zig").Context;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const Metrics = @import("monitoring.zig").Metrics;
const Logger = @import("error_handler.zig").Logger;
const Template = @import("template.zig").Template;
const http = std.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Advanced Features Example starting on {s}:{d}", .{ "127.0.0.1", 8083 });

    var server = try HTTPServer.init(allocator, .{
        .port = 8083,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Initialize advanced features
    var rate_limiter = RateLimiter.init(allocator, .{ .max_requests = 10, .window_ms = 60000 });
    defer rate_limiter.deinit();
    server.setRateLimiter(&rate_limiter);

    var metrics = Metrics.init(allocator);
    defer metrics.deinit();
    server.setMetrics(&metrics);

    var logger = Logger.init(allocator, .info);
    defer logger.deinit();
    server.setLogger(&logger);

    // Add routes
    server.get("/", handleHome);
    server.get("/api/data", handleData);
    server.post("/api/submit", handleSubmit);
    server.get("/health", handleHealth);

    try server.start(io);
}

fn handleHome(ctx: *Context) !void {
    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>Advanced Features Demo</title>
            \<meta charset="utf-8">
        \</head>
        \<body>
            \<h1>Advanced Features Demo</h1>
            \<h2>Implemented Features:</h2>
            \<ul>
                \<li>Rate Limiting - Try requesting /api/data more than 10 times</li>
                \<li>Request Metrics - Check /health</li>
                \<li>Template Rendering - This page uses templates</li>
                \<li>Error Handling - Try visiting /nonexistent</li>
            \</ul>
            \<h2>Test Endpoints:</h2>
            \<ul>
                \<li><a href="/api/data">GET /api/data - Rate limited endpoint</a></li>
                \<li><a href="/health">GET /health - Health check with metrics</a></li>
            \</ul>
            \<h3>Your IP: </h3>
            \<p>Request #0 from your IP in the last minute</p>
        \</body>
        \</html>
    ;

    try ctx.html(source);
}

fn handleData(ctx: *Context) !void {
    const server = ctx.server;
    const client_ip = "127.0.0.1"; // In real app, extract from request

    // Check rate limit
    if (server.rate_limiter) |*limiter| {
        if (!limiter.isAllowed(client_ip)) {
            ctx.setStatus(http.Status.too_many_requests);
            try ctx.json(.{
                .error_val = "Rate limit exceeded",
                .retry_after = 60,
            });
            return;
        }
    }

    try ctx.json(.{
        .message = "Success! Request allowed.",
        .timestamp = std.time.timestamp(),
    });
}

fn handleSubmit(ctx: *Context) !void {
    try ctx.json(.{
        .message = "Data submitted successfully",
        .received = ctx.getBody(),
    });
}

fn handleHealth(ctx: *Context) !void {
    const server = ctx.server;

    var status = "healthy";
    var uptime: i64 = 0;

    if (server.metrics) |*metrics| {
        const metrics_json = try metrics.toJson(ctx.allocator);
        defer ctx.allocator.free(metrics_json);
        try ctx.html(metrics_json);
    } else {
        try ctx.json(.{
            .status = "healthy",
            .uptime = 0,
        });
    }
}
