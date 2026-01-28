/// Example demonstrating Cookie and Session management
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = @import("context.zig").Context;
const Cookie = @import("cookie.zig").Cookie;
const SessionManager = @import("session.zig").SessionManager;
const MemorySessionStore = @import("session.zig").MemorySessionStore;
const http = std.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Session Example starting on {s}:{d}", .{ "127.0.0.1", 8084 });

    var server = try HTTPServer.init(allocator, .{
        .port = 8084,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Initialize session store
    var session_store = MemorySessionStore.init(allocator);
    defer session_store.deinit();

    var session_manager = SessionManager.init(allocator, &session_store, .{
        .secret = "my-secret-key-123456",
        .max_age = 3600,
        .http_only = true,
        .same_site = .lax,
    });

    // Add routes
    server.get("/", handleHome);
    server.get("/login", handleLogin);
    server.get("/profile", handleProfile);
    server.get("/logout", handleLogout);

    try server.start(io);
}

fn handleHome(ctx: *Context) !void {
    const session_id = ctx.getCookie("session_id");

    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>Session Demo</title>
            \<meta charset="utf-8">
        \</head>
        \<body>
            \<h1>Session Demo</h1>
            \<p>Current session: {s}</p>
            \<ul>
                \<li><a href="/login">Login</a></li>
                \<li><a href="/profile">Profile</a></li>
                \<li><a href="/logout">Logout</a></li>
            \</ul>
        \</body>
        \</html>
    ;

    const formatted = try std.fmt.allocPrint(
        ctx.allocator,
        source,
        .{session_id orelse "none"}
    );
    defer ctx.allocator.free(formatted);

    try ctx.html(formatted);
}

fn handleLogin(ctx: *Context) !void {
    const username = ctx.getQuery("username") orelse "guest";

    // Set session cookie
    const cookie = Cookie{
        .name = "username",
        .value = username,
        .options = .{
            .max_age = 3600,
            .http_only = true,
        },
    };

    try ctx.setCookie(cookie);

    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>Logged In</title>
        \</head>
        \<body>
            \<h1>Welcome, {s}!</h1>
            \<p>You are now logged in.</p>
            \<p><a href="/">Return to home</a></p>
        \</body>
        \</html>
    ;

    const formatted = try std.fmt.allocPrint(ctx.allocator, source, .{username});
    defer ctx.allocator.free(formatted);

    try ctx.html(formatted);
}

fn handleProfile(ctx: *Context) !void {
    const username = ctx.getCookie("username") orelse "guest";

    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>Profile</title>
        \</head>
        \<body>
            \<h1>Profile</h1>
            \<p>Logged in as: <strong>{s}</strong></p>
            \<p><a href="/">Return to home</a></p>
        \</body>
        \</html>
    ;

    const formatted = try std.fmt.allocPrint(ctx.allocator, source, .{username});
    defer ctx.allocator.free(formatted);

    try ctx.html(formatted);
}

fn handleLogout(ctx: *Context) !void {
    // Clear cookie by setting expired cookie
    const cookie = Cookie{
        .name = "username",
        .value = "",
        .options = .{
            .max_age = -1,
        },
    };

    try ctx.setCookie(cookie);

    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>Logged Out</title>
        \</head>
        \<body>
            \<h1>Logged Out</h1>
            \<p>You have been logged out.</p>
            \<p><a href="/">Return to home</a></p>
        \</body>
        \</html>
    ;

    try ctx.html(source);
}
