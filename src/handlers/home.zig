const std = @import("std");
const http = std.http;
const Context = @import("../core/context.zig").Context;

/// Handler for the home page - displays server demo interface
pub fn handleHome(ctx: *Context) !void {
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
