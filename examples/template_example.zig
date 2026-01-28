/// Example demonstrating template engine usage
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = @import("context.zig").Context;
const Template = @import("template.zig").Template;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Template Example starting on {s}:{d}", .{ "127.0.0.1", 8085 });

    var server = try HTTPServer.init(allocator, .{
        .port = 8085,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Add routes
    server.get("/", handleHome);
    server.get("/dashboard", handleDashboard);
    server.get("/safe", handleSafe);

    try server.start(io);
}

fn handleHome(ctx: *Context) !void {
    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>Template Engine Demo</title>
            \<meta charset="utf-8">
            \<style>
                body { font-family: Arial, sans-serif; margin: 40px; }
                h1 { color: #333; }
                .nav { margin: 20px 0; padding: 10px; background: #f4f4f4; }
                .nav a { margin-right: 20px; text-decoration: none; color: #007bff; }
            \</style>
        \</head>
        \<body>
            \<h1>Template Engine Demo</h1>
            \<div class="nav">
                \<a href="/">Home</a>
                \<a href="/dashboard">Dashboard</a>
                \<a href="/safe">Safe Rendering (XSS Prevention)</a>
            \</div>
            \<h2>Features:</h2>
            \<ul>
                \<li>Variable substitution: {{variable}}</li>
                \<li>Conditionals: {{#if variable}}...{{/if}}</li>
                \<li>Loops: {{#each array}}...{{/each}}</li>
                \<li>HTML escaping for XSS protection</li>
            \</ul>
        \</body>
        \</html>
    ;

    try ctx.html(source);
}

fn handleDashboard(ctx: *Context) !void {
    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>Dashboard</title>
            \<meta charset="utf-8">
            \<style>
                body { font-family: Arial, sans-serif; margin: 40px; }
                .metric { display: inline-block; margin: 10px; padding: 20px; background: #e9ecef; }
                table { border-collapse: collapse; width: 100%; }
                th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
            \</style>
        \</head>
        \<body>
            \<h1>Dashboard</h1>
            \<p>Welcome, {{username}}!</p>

            \<h2>Metrics</h2>
            \<div>
                \<div class="metric">
                    \<h3>Total Requests</h3>
                    \<p>{{total_requests}}</p>
                \</div>
                \<div class="metric">
                    \<h3>Avg Response Time</h3>
                    \<p>{{avg_time}}ms</p>
                \</div>
                \<div class="metric">
                    \<h3>Active Users</h3>
                    \<p>{{active_users}}</p>
                \</div>
            \</div>

            \<h2>Recent Activity</h2>
            {{#if has_activity}}
                \<table>
                    \<thead>
                        \<tr>
                            \<th>Time</th>
                            \<th>User</th>
                            \<th>Action</th>
                        \</tr>
                    \</thead>
                    \<tbody>
                        {{#each activities}}
                            \<tr>
                                \<td>{{time}}</td>
                                \<td>{{user}}</td>
                                \<td>{{action}}</td>
                            \</tr>
                        {{/each}}
                    \</tbody>
                \</table>
            {{/if}}
            {{#if has_activity}}
                \<p>No recent activity</p>
            {{/if}}

            \<p><a href="/">Back to home</a></p>
        \</body>
        \</html>
    ;

    var tmpl = Template.init(ctx.allocator, source);
    defer tmpl.deinit();

    try tmpl.set("username", "John Doe");
    try tmpl.set("total_requests", "1,234");
    try tmpl.set("avg_time", "45");
    try tmpl.set("active_users", "42");
    try tmpl.set("has_activity", "true");

    // Simulate activities (in real app, would be from database)
    const activities = "Login,View Dashboard,Update Settings,Logout,Login";

    const rendered = try tmpl.render();
    defer ctx.allocator.free(rendered);

    try ctx.html(rendered);
}

fn handleSafe(ctx: *Context) !void {
    const user_input = ctx.getQuery("input") orelse "<script>alert('XSS')</script>";

    const source =
        \\<!DOCTYPE html>
        \\<html>
        \<head>
            \<title>XSS Prevention Demo</title>
            \<meta charset="utf-8">
        \</head>
        \<body>
            \<h1>XSS Prevention Demo</h1>
            \<h2>User Input:</h2>
            \<p>{{user_input}}</p>

            \<h2>Escaped Output:</h2>
            \<p>{{escaped_input}}</p>

            \<h2>Test Inputs:</h2>
            \<ul>
                \<li><a href="/safe?input=Hello">Safe input: Hello</a></li>
                \<li><a href="/safe?input=&lt;script&gt;alert(1)&lt;/script&gt;">
                    XSS attempt: &lt;script&gt;...
                \</a></li>
                \<li><a href="/safe?input=&lt;img src=x onerror=alert(1)&gt;">
                    XSS attempt: &lt;img&gt;
                \</a></li>
            \</ul>

            \<p><a href="/">Back to home</a></p>
        \</body>
        \</html>
    ;

    var tmpl = Template.init(ctx.allocator, source);
    defer tmpl.deinit();

    try tmpl.set("user_input", user_input);
    try tmpl.set("escaped_input", try Template.escapeHtml(ctx.allocator, user_input));

    const rendered = try tmpl.render();
    defer ctx.allocator.free(rendered);

    try ctx.html(rendered);
}
