# Zig HTTP Server

A high-performance, lightweight HTTP server framework written in Zig, featuring a middleware system, trie-based routing, and comprehensive security features.

## Features

- ⚡ **High Performance** - 10,000+ QPS (queries per second)
- 🔒 **Security First** - Built-in XSS, CSRF, and Authentication middleware
- 🌳 **Trie-based Routing** - Efficient URL matching with parameter support
- 🔌 **Middleware System** - Flexible, comptime VTable-based middleware architecture
- 📦 **Zero Dependencies** - Uses only Zig standard library
- 🚀 **Async I/O** - Non-blocking event loop architecture

## Performance

Benchmark results on `127.0.0.1:8080`:

| Metric | Value |
|--------|--------|
| QPS | 7,500 - 10,000+ |
| Avg Latency | ~1ms |
| P99 Latency | <5ms |
| Success Rate | 100% |

```bash
# Benchmark with oha
oha -n 500 -c 500 -z 30s http://127.0.0.1:8080/abc
```

## Quick Start

```bash
# Clone the repository
git clone https://github.com/by965738071/zig-http.git
cd zig-http

# Build and run
zig build run

# The server starts on http://127.0.0.1:8080
```

## Project Structure

```
src/
├── main.zig              # Entry point and server setup
├── http_server.zig        # Core HTTP server implementation
├── router.zig             # Trie-based URL router
├── middleware.zig         # Middleware VTable architecture
├── context.zig            # Request/response context
├── response.zig           # HTTP response builder
├── types.zig             # Common type definitions
└── middleware/            # Built-in middleware implementations
    ├── auth.zig           # Bearer token authentication
    ├── cors.zig           # CORS support
    ├── xss.zig            # XSS protection
    ├── csrf.zig           # CSRF token validation
    └── logging.zig        # Request logging
```

## Usage

### Basic Server Setup

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var server = try HTTPServer.init(allocator, .{
        .port = 8080,
        .host = "127.0.0.1",
    });

    server.get("/", handler);
    server.start(io) catch |err| {
        std.log.err("Error: {}", .{err});
        return err;
    };
    defer server.deinit();
}

fn handler(ctx: *Context) !void {
    try ctx.json(.{ .message = "Hello, World!" });
}
```

### Adding Routes

```zig
// GET request
server.get("/users", getUsersHandler);

// POST request
server.post("/users", createUserHandler);

// PUT request
server.put("/users/:id", updateUserHandler);

// DELETE request
server.delete("/users/:id", deleteUserHandler);

// All HTTP methods
server.all("/health", healthCheckHandler);
```

### Route Parameters

```zig
server.get("/users/:id", getUserHandler);

fn getUserHandler(ctx: *Context) !void {
    const user_id = ctx.getParam("id") orelse {
        try ctx.err(std.http.Status.bad_request, "Missing user ID");
        return;
    };
    try ctx.json(.{ .user_id = user_id });
}
```

### Query Parameters

```zig
fn searchHandler(ctx: *Context) !void {
    const query = ctx.getQuery("q") orelse "";
    try ctx.json(.{ .query = query });
}

// GET /search?q=zig+http
```

## Middleware

### Using Built-in Middleware

#### Authentication Middleware

```zig
const AuthMiddleware = @import("middleware/auth.zig").AuthMiddleware;

var auth = try AuthMiddleware.init(allocator, "my-secret-token");
defer auth.deinit();

// Add whitelist for public routes
try auth.skipPath("/public");
try auth.skipPath("/login");

server.use(&auth.middleware);
```

**Usage:**
```bash
curl -H "Authorization: Bearer my-secret-token" http://127.0.0.1:8080/protected
```

#### XSS Protection Middleware

```zig
const XSSMiddleware = @import("middleware/xss.zig").XSSMiddleware;

var xss = try XSSMiddleware.init(allocator, true);
defer xss.deinit();

server.use(&xss.middleware);
```

**Security Headers Added:**
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `X-XSS-Protection: 1; mode=block`
- `Content-Security-Policy: default-src 'self'...`

**Utility Functions:**
```zig
// HTML escaping
const safe_html = try XSSMiddleware.escapeHtml(allocator, "<script>alert('xss')</script>");

// JavaScript escaping
const safe_js = try XSSMiddleware.escapeJs(allocator, "'; alert('xss');");

// URL sanitization
const safe_url = try XSSMiddleware.sanitizeUrl(allocator, "javascript:alert(1)");
```

#### CSRF Protection Middleware

```zig
const CSRFMiddleware = @import("middleware/csrf.zig").CSRFMiddleware;

var csrf = try CSRFMiddleware.init(allocator, .{
    .secret = "csrf-secret-key",
    .token_lifetime_sec = 3600,  // 1 hour
});
defer csrf.deinit();

server.use(&csrf.middleware);
```

**Frontend Usage:**
```javascript
// Get CSRF token from cookie
const csrfToken = document.cookie
    .split('; ')
    .find(c => c.trim().startsWith('csrf_token='))
    ?.split('=')[1];

// Include in headers
fetch('/api/update', {
    method: 'POST',
    headers: {
        'X-CSRF-Token': csrfToken
    }
});
```

#### CORS Middleware

```zig
const CORSMiddleware = @import("middleware/cors.zig").CORSMiddleware;

var cors = try CORSMiddleware.init(allocator, .{
    .allowed_origins = &.{ "https://example.com", "https://api.example.com" },
    .allow_credentials = true,
});
defer cors.deinit();

server.use(&cors.middleware);
```

#### Logging Middleware

```zig
const LoggingMiddleware = @import("middleware/logging.zig").LoggingMiddleware;

var logger = try LoggingMiddleware.init(allocator);
defer logger.deinit();

server.use(&logger.middleware);
```

### Custom Middleware

```zig
const CustomMiddleware = struct {
    middleware: Middleware,

    pub fn init(allocator: std.mem.Allocator) !*CustomMiddleware {
        const self = try allocator.create(CustomMiddleware);
        self.* = .{
            .middleware = Middleware.init(CustomMiddleware),
        };
        return self;
    }

    pub fn process(self: *CustomMiddleware, ctx: *Context) !Middleware.NextAction {
        // Your logic here
        std.log.debug("Custom middleware processing: {s}", .{ctx.request.head.target});

        return Middleware.NextAction.@"continue";
    }

    pub fn deinit(self: *CustomMiddleware) void {
        _ = self;
    }
};

// Usage
var custom = try CustomMiddleware.init(allocator);
defer custom.deinit();
server.use(&custom.middleware);
```

### Context Methods

```zig
// Set HTTP status
ctx.setStatus(std.http.Status.ok);

// Send JSON response
try ctx.json(.{ .data = value });

// Send HTML response
try ctx.html("<h1>Hello</h1>");

// Send text response
try ctx.text("Plain text");

// Send error
try ctx.err(std.http.Status.not_found, "Resource not found");

// Set custom header
try ctx.response.setHeader("X-Custom-Header", "value");

// Store state (for use in handlers/middlewares)
try ctx.setState("user_id", "12345");

// Get state
if (ctx.getState("user_id")) |ptr| {
    const user_id = @as(*[]const u8, @ptrCast(@alignCast(ptr))).*;
}
```

### Middleware Chain

Middlewares are executed in the order they are added:

```zig
// 1. CORS
server.use(&cors.middleware);

// 2. CSRF (only for unsafe methods)
server.use(&csrf.middleware);

// 3. Auth
server.use(&auth.middleware);

// 4. Custom
server.use(&custom.middleware);

// Execution order: CORS → CSRF → Auth → Custom → Handler
```

### Middleware NextAction

```zig
pub const NextAction = enum {
    @"continue",  // Continue to next middleware/handler
    respond,     // Send response immediately, stop chain
    err,         // Error handling (same as respond)
};

// Example: Short-circuit middleware
pub fn process(self: *CustomMiddleware, ctx: *Context) !Middleware.NextAction {
    if (isRateLimited(ctx)) {
        try ctx.err(std.http.Status.too_many_requests, "Rate limit exceeded");
        return Middleware.NextAction.respond;  // Stop here
    }
    return Middleware.NextAction.@"continue";  // Continue
}
```

## Architecture

### VTable Pattern

This framework uses Zig's VTable pattern for polymorphism, similar to `std.mem.Allocator`:

```zig
pub const Middleware = struct {
    name: []const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        process: *const fn (*anyopaque, *Context) anyerror!NextAction,
        destroy: *const fn (*anyopaque) void,
    };
};
```

**Benefits:**
- ✅ Compile-time type safety
- ✅ Zero runtime overhead (direct function pointer calls)
- ✅ No reflection required
- ✅ Explicit control over type conversions

### Request Lifecycle

```
┌─────────────────────────────────────────────────────────┐
│ 1. TCP Connection Accepted                      │
├─────────────────────────────────────────────────────────┤
│ 2. HTTP Request Parsed (receiveHead)             │
├─────────────────────────────────────────────────────────┤
│ 3. Route Matched (Trie traversal)               │
├─────────────────────────────────────────────────────────┤
│ 4. Global Middlewares Executed                    │
│    ├─ CORS                                    │
│    ├─ CSRF                                     │
│    └─ Auth                                     │
├─────────────────────────────────────────────────────────┤
│ 5. Route Middlewares Executed                   │
├─────────────────────────────────────────────────────────┤
│ 6. Handler Executed                              │
├─────────────────────────────────────────────────────────┤
│ 7. Response Sent (toHttpResponse)               │
└─────────────────────────────────────────────────────────┘
```

### Trie-Based Routing

The router uses a trie data structure for efficient URL matching:

```
┌───────┐
│  root  │
└─────┬─┘
      │
      ├─ api/ ───── users/
      │                ├─ :id/
      │                └─ posts/
      │
      ├─ public/
      │
      └─ health
```

**Advantages:**
- O(k) lookup complexity (k = URL depth)
- Fast prefix matching
- Efficient wildcard/parameter matching

## Requirements

- **Zig**: 0.16.0-dev (or compatible version)
- **OS**: Windows, Linux, macOS (cross-platform)
- **Network**: Async I/O support required

## Building

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run tests
zig test
```

## Configuration

### Server Options

```zig
pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
};
```

### Optimizing for High Concurrency

```zig
// Increase kernel backlog for more pending connections
server.tcp_server = try address.listen(server.io, .{
    .reuse_address = true,
    .kernel_backlog = 4096,  // Default: 128
});

// Larger I/O buffers
var read_buffer: [65536]u8 = undefined;  // 64KB
var write_buffer: [65536]u8 = undefined;
```

### Windows System Tuning

```powershell
# Increase dynamic port range
netsh int ipv4 set dynamicport tcp start=1024 num=60000

# View TCP parameters
netsh int ipv4 show dynamicport tcp
```

## Security Features

### Authentication
- Bearer token validation
- Path-based whitelist
- Configurable secret

### XSS Protection
- Automatic header injection
- HTML entity encoding
- JavaScript escaping
- URL sanitization

### CSRF Protection
- Automatic token generation (GET requests)
- Token validation (POST/PUT/DELETE)
- Configurable token lifetime
- HttpOnly + SameSite=Strict cookies

### CORS
- Configurable allowed origins
- Credential support
- Preflight request handling (OPTIONS)

## API Reference

See inline documentation in source files:

- `src/http_server.zig` - HTTPServer API
- `src/router.zig` - Router API
- `src/context.zig` - Context API
- `src/middleware/*.zig` - Middleware implementations

## Examples

### REST API Example

```zig
server.get("/api/users", getUsers);
server.get("/api/users/:id", getUser);
server.post("/api/users", createUser);
server.put("/api/users/:id", updateUser);
server.delete("/api/users/:id", deleteUser);

fn getUsers(ctx: *Context) !void {
    try ctx.json(.{
        .users = &[_]User{ ... }
    });
}
```

### Static File Server (Conceptual)

```zig
server.get("/static/*", serveStatic);

fn serveStatic(ctx: *Context) !void {
    const path = ctx.getParam("*") orelse "index.html";
    // Serve file content...
}
```

## Contributing

Contributions are welcome! Areas for improvement:

- [ ] WebSocket support
- [ ] File upload handling (multipart/form-data)
- [ ] Template engine integration
- [ ] Rate limiting middleware
- [ ] Request body streaming
- [ ] HTTP/2 support
- [ ] TLS/HTTPS support

## License

MIT License - See LICENSE file for details

## Acknowledgments

- Built with [Zig](https://ziglang.org/)
- HTTP parsing powered by `std.http`
- Async I/O powered by `std.Io`

## Author

Your Name - [@yourusername](https://github.com/yourusername)

---

**Note**: This project is designed for Zig 0.16.0-dev. The HTTP APIs may change before stable release.
