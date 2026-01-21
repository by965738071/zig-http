const std = @import("std");
const httpServer = @import("http_server.zig").HTTPServer;
const router = @import("router.zig").Router;
const http = std.http;
const Context = @import("context.zig").Context;
const AuthMiddleware = @import("middleware/auth.zig").AuthMiddleware;
const XSSMiddleware = @import("middleware/xss.zig").XSSMiddleware;
const CSRFMiddleware = @import("middleware/csrf.zig").CSRFMiddleware;

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
    std.log.info("Press Ctrl+C to stop the server", .{});

    var route = try router.init(allocator);
    defer route.deinit();

    try route.addRoute(http.Method.GET, "/abc", handlerHello);

    try route.addRoute(http.Method.GET, "/abc/bcd", handlerBcd);

    var server = try httpServer.init(allocator, .{
        .port = 8080,
        .host = "127.0.0.1",
    });

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
