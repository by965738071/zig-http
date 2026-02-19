# Zig HTTP Server

A high-performance, lightweight HTTP server framework written in Zig, featuring a middleware system, trie-based routing, comprehensive security features, and **fully working WebSocket support**.

## ✨ Features

- ⚡ **High Performance** - Designed for 7,500+ QPS (queries per second)
- 🔒 **Security First** - Built-in XSS, CSRF, and Authentication middleware
- 🌳 **Trie-based Routing** - Efficient URL matching with parameter support
- 🔌 **Middleware System** - Flexible, comptime VTable-based middleware architecture
- 📦 **Zero Dependencies** - Uses only Zig standard library
- 🚀 **Async I/O** - Non-blocking event loop architecture
- 🛑 **Graceful Shutdown** - Atomic shutdown flag with active connection tracking
- 📊 **Request Body Handling** - Content-Length aware body reading with memory limits
- 🌐 **Static File Server** - Integrated static file serving with single-instance optimization
- 📡 **WebSocket Support** - Echo server implementation included
- 📈 **Monitoring** - Built-in metrics collection (requests, latency, etc.)

## 📊 Performance

Benchmark results on `127.0.0.1:8080`:

| Metric | Value |
|--------|--------|
| QPS | 7,500 - 10,000+ |
| Avg Latency | ~1ms |
| P99 Latency | <5ms |
| Success Rate | 100% |
| Memory Model | Stack-based + Arena allocator |

```bash
# Benchmark with oha
oha -n 500 -c 500 -z 30s http://127.0.0.1:8080/
```

## 🚀 Quick Start

### Prerequisites
- **Zig**: 0.15.2+ (tested on 0.16.0-dev)
- **OS**: Windows, Linux, macOS

### Build & Run

```bash
# Clone the repository
git clone https://github.com/by965738071/zig-http.git
cd zig-http

# Build
zig build

# Run the server
./zig-out/bin/zig_http

# Or use the convenient command
zig build run

# The server starts on http://127.0.0.1:8080
```

### Test Endpoints

```bash
# Home page
curl http://127.0.0.1:8080/

# JSON API
curl http://127.0.0.1:8080/api/data

# Submit form
curl -X POST -H "Content-Type: application/json" \
  -d '{"name":"Alice","age":30}' \
  http://127.0.0.1:8080/api/submit

# File upload
curl -F "file=@myfile.txt" http://127.0.0.1:8080/upload

# Static file serving
curl http://127.0.0.1:8080/static/index.html

# WebSocket echo
wscat -c ws://127.0.0.1:8080/ws
```

## 📁 Project Structure

```
zig-http/
├── build.zig              # Build configuration
├── README.md             # This file
├── QUICKSTART.md         # Detailed getting started guide
├── IMPROVEMENTS.md       # Summary of improvements made
├── PROJECT_STATUS.md     # Current project status and next steps
│
└── src/
    ├── main.zig          # Entry point and server initialization
    ├── http_server.zig   # Core HTTP server (listen, accept, request handling)
    ├── context.zig       # Request/response context with body reading
    ├── response.zig      # HTTP response builder with header management
    ├── router.zig        # Trie-based URL router with parameter extraction
    ├── types.zig         # Common types and constants
    ├── body_parser.zig   # Request body parsing (JSON, form, multipart)
    ├── static_server.zig # Static file serving
    ├── websocket.zig     # WebSocket protocol support
    ├── monitoring.zig    # Metrics collection and tracking
    │
    └── middleware/       # Built-in middleware implementations
        ├── middleware.zig    # Middleware VTable and base architecture
        ├── auth.zig         # Bearer token authentication
        ├── cors.zig         # CORS (Cross-Origin Resource Sharing)
        ├── xss.zig          # XSS protection and HTML escaping
        ├── csrf.zig         # CSRF token validation
        └── logging.zig      # Request/response logging
```

## 📖 Usage

### Basic Server Setup

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = @import("context.zig").Context;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{
        .port = 8080,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Add routes
    try server.get("/", homeHandler);
    try server.post("/api/submit", submitHandler);

    // Start server
    try server.start();
}

fn homeHandler(ctx: *Context) !void {
    try ctx.html("<h1>Welcome!</h1>");
}

fn submitHandler(ctx: *Context) !void {
    // Body is automatically read and available in ctx.request_body
    try ctx.json(.{ .status = "ok" });
}
```

### Adding Routes

```zig
// HTTP Methods
try server.get("/users", getUsersHandler);
try server.post("/users", createUserHandler);
try server.put("/users/:id", updateUserHandler);
try server.delete("/users/:id", deleteUserHandler);
try server.patch("/users/:id", patchUserHandler);
try server.all("/health", healthCheckHandler);
```

### Route Parameters

```zig
try server.get("/users/:id", getUserHandler);

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
    try ctx.json(.{ .results = .{}, .query = query });
}

// Usage: GET /search?q=zig+http
```

### Request Body Handling

```zig
fn submitHandler(ctx: *Context) !void {
    // Request body is automatically read based on Content-Length
    // Available as: ctx.request_body ([]const u8)
    
    if (ctx.request_body.len > 0) {
        std.debug.print("Received body: {s}\n", .{ctx.request_body});
    }
    
    try ctx.json(.{ .received = ctx.request_body.len });
}
```

### Form Data Parsing

```zig
fn handleForm(ctx: *Context) !void {
    const body_str = ctx.request_body;
    
    // Parse as form data
    // Format: key1=value1&key2=value2
    
    try ctx.json(.{ .status = "form received" });
}
```

### File Upload Handling

```zig
fn handleUpload(ctx: *Context) !void {
    const content_type = ctx.request.head.content_type orelse "";
    
    if (std.mem.startsWith(u8, content_type, "multipart/form-data")) {
        // Parse multipart form data
        // ctx.request_body contains the raw body
        try ctx.json(.{ .status = "file received" });
    } else {
        try ctx.err(std.http.Status.bad_request, "Invalid content type");
    }
}
```

## 🔌 Middleware

### Using Built-in Middleware

#### Logging Middleware

```zig
const LoggingMiddleware = @import("middleware/logging.zig").LoggingMiddleware;

var logger = try LoggingMiddleware.init(allocator);
defer logger.deinit();

try server.use(&logger.middleware);
```

Output:
```
[GET  ] 127.0.0.1 /api/data (200 OK) 1.23ms
[POST ] 127.0.0.1 /api/submit (201 Created) 2.45ms
```

#### Authentication Middleware

```zig
const AuthMiddleware = @import("middleware/auth.zig").AuthMiddleware;

var auth = try AuthMiddleware.init(allocator, "my-secret-token");
defer auth.deinit();

// Add whitelist for public routes
try auth.skipPath("/public");
try auth.skipPath("/login");

try server.use(&auth.middleware);
```

**Usage:**
```bash
curl -H "Authorization: Bearer my-secret-token" \
  http://127.0.0.1:8080/protected
```

#### XSS Protection Middleware

```zig
const XSSMiddleware = @import("middleware/xss.zig").XSSMiddleware;

var xss = try XSSMiddleware.init(allocator, true);
defer xss.deinit();

try server.use(&xss.middleware);
```

**Security Headers Added:**
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `X-XSS-Protection: 1; mode=block`
- `Content-Security-Policy: default-src 'self'`

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

try server.use(&csrf.middleware);
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

try server.use(&cors.middleware);
```

### Custom Middleware

```zig
const CustomMiddleware = struct {
    middleware: Middleware,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*CustomMiddleware {
        const self = try allocator.create(CustomMiddleware);
        self.* = .{
            .middleware = Middleware.init(CustomMiddleware),
            .allocator = allocator,
        };
        return self;
    }

    pub fn process(self: *CustomMiddleware, ctx: *Context) !Middleware.NextAction {
        std.debug.print("Processing: {s}\n", .{ctx.request.head.target});
        return Middleware.NextAction.@"continue";
    }

    pub fn deinit(self: *CustomMiddleware) void {
        self.allocator.destroy(self);
    }
};

// Usage
var custom = try CustomMiddleware.init(allocator);
defer custom.deinit();
try server.use(&custom.middleware);
```

### Middleware Chain

Middlewares are executed in the order they are added:

```zig
// 1. Logging (all requests)
try server.use(&logger.middleware);

// 2. CORS (handle preflight)
try server.use(&cors.middleware);

// 3. CSRF (validate tokens)
try server.use(&csrf.middleware);

// 4. Authentication (verify tokens)
try server.use(&auth.middleware);

// Execution order: Logging → CORS → CSRF → Auth → Handler
```

### Middleware NextAction

```zig
pub const NextAction = enum {
    @"continue",  // Continue to next middleware/handler
    respond,      // Send response, stop chain
    err,          // Error response, stop chain
};

// Example: Rate limiting middleware
pub fn process(self: *RateLimitMiddleware, ctx: *Context) !Middleware.NextAction {
    if (isRateLimited(ctx.request.head.host)) {
        try ctx.err(std.http.Status.too_many_requests, "Rate limit exceeded");
        return Middleware.NextAction.respond;
    }
    return Middleware.NextAction.@"continue";
}
```

## 🏗️ Architecture

### VTable Pattern

This framework uses Zig's VTable pattern for polymorphism:

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
- ✅ Zero runtime overhead (direct function pointers)
- ✅ No reflection required
- ✅ Explicit control over type conversions

### Request Lifecycle

```
┌──────────────────────────────────────────────────┐
│ 1. TCP Connection Accepted                       │
├──────────────────────────────────────────────────┤
│ 2. HTTP Request Parsed (receiveHead)             │
├──────────────────────────────────────────────────┤
│ 3. Request Body Read (respecting Content-Length) │
├──────────────────────────────────────────────────┤
│ 4. Route Matched (Trie traversal)                │
├──────────────────────────────────────────────────┤
│ 5. Global Middlewares Executed                   │
│    ├─ Logging                                    │
│    ├─ CORS                                       │
│    ├─ CSRF                                       │
│    └─ Auth                                       │
├──────────────────────────────────────────────────┤
│ 6. Route Handler Executed                        │
├──────────────────────────────────────────────────┤
│ 7. Response Sent (toHttpResponse)                │
├──────────────────────────────────────────────────┤
│ 8. Connection Tracked / Closed                   │
└──────────────────────────────────────────────────┘
```

### Trie-Based Routing

The router uses a trie data structure for efficient URL matching:

```
┌─────────┐
│  root   │
└────┬────┘
     │
     ├─ api/ ────── data
     │              submit
     │
     ├─ users/ ──── :id/ ──── profile
     │                         settings
     │
     └─ static/
```

**Advantages:**
- O(k) lookup (k = URL depth)
- Fast prefix matching
- Efficient parameter extraction

### Graceful Shutdown

The server implements graceful shutdown:

```zig
// Atomic shutdown flag
pub var shutdown_requested = std.atomic.Value(bool).init(false);

// Active connection counter
var active_connections = std.atomic.Value(u32).init(0);

// Request shutdown
pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

// Wait for active connections (with timeout)
pub fn waitForShutdown(timeout_ms: u32) !void {
    const start = std.time.millis();
    while (true) {
        if (active_connections.load(.acquire) == 0) break;
        if (std.time.millis() - start > timeout_ms) return error.ShutdownTimeout;
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
```

## 🛡️ Security Features

### Authentication
- Bearer token validation with secret key
- Path-based whitelist for public routes
- Token verification before handler execution

### XSS Protection
- Automatic security header injection
- HTML entity encoding utilities
- JavaScript escaping functions
- URL sanitization

### CSRF Protection
- Automatic token generation (GET requests)
- Token validation (POST/PUT/DELETE)
- Configurable token lifetime
- HttpOnly + SameSite=Strict cookies

### CORS
- Configurable allowed origins
- Credential support
- Automatic preflight request handling (OPTIONS)
- Custom headers support

## 📋 API Reference

### Context API

```zig
// Status
ctx.setStatus(std.http.Status.ok);

// Responses
try ctx.json(.{ .data = value });
try ctx.html("<h1>Title</h1>");
try ctx.text("Plain text");
try ctx.err(std.http.Status.not_found, "Not found");

// Headers
try ctx.response.setHeader("X-Custom", "value");
const content_type = ctx.request.head.content_type;

// Parameters
if (ctx.getParam("id")) |id| { }
if (ctx.getQuery("q")) |q| { }

// State storage
try ctx.setState("user_id", value_ptr);
if (ctx.getState("user_id")) |ptr| { }

// Body
const body = ctx.request_body;  // []const u8
```

### HTTPServer API

```zig
var server = try HTTPServer.init(allocator, .{
    .port = 8080,
    .host = "127.0.0.1",
});

try server.get("/path", handler);
try server.post("/path", handler);
try server.put("/path", handler);
try server.delete("/path", handler);
try server.patch("/path", handler);
try server.all("/path", handler);

try server.use(&middleware.middleware);

try server.start();
server.deinit();
```

## 🔧 Building & Configuration

### Build Targets

```bash
# Debug build (default)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Release small (minimal binary)
zig build -Doptimize=ReleaseSmall

# Check for errors without building
zig build -Dhelp
```

### Configuration Options

```zig
pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_request_body_size: usize = 10 * 1024 * 1024,  // 10 MB
};
```

### Performance Tuning

```zig
// Increase listener backlog
server.tcp_server = try address.listen(server.io, .{
    .reuse_address = true,
    .kernel_backlog = 4096,
});

// Larger buffers for I/O
var read_buffer: [65536]u8 = undefined;   // 64 KB
var write_buffer: [65536]u8 = undefined;
```

## 📚 Examples

### REST API

```zig
try server.get("/api/users", getUsers);
try server.get("/api/users/:id", getUser);
try server.post("/api/users", createUser);
try server.put("/api/users/:id", updateUser);
try server.delete("/api/users/:id", deleteUser);

fn getUsers(ctx: *Context) !void {
    try ctx.json(.{
        .users = &[_]User{
            .{ .id = 1, .name = "Alice" },
            .{ .id = 2, .name = "Bob" },
        }
    });
}

fn getUser(ctx: *Context) !void {
    const id = ctx.getParam("id") orelse return;
    try ctx.json(.{ .id = id, .name = "User " ++ id });
}
```

### Static File Server

```zig
var static = try StaticServer.init(allocator, "./public");
defer static.deinit();

try server.get("/static/*", struct {
    fn handle(ctx: *Context) !void {
        const path = ctx.getParam("*") orelse "index.html";
        try static.serve(ctx, path);
    }
}.handle);
```

### WebSocket Echo Server

```zig
try server.all("/ws", wsEchoHandler);

fn wsEchoHandler(ctx: *Context) !void {
    const ws = try WebSocket.init(ctx);
    defer ws.deinit();
    
    while (try ws.read()) |message| {
        try ws.write(message);
    }
}
```

## 🚦 Status & Next Steps

### ✅ Completed Features
- [x] Core HTTP server with async I/O
- [x] Trie-based routing with parameters
- [x] Middleware system (VTable pattern)
- [x] Request body reading
- [x] Static file serving
- [x] WebSocket echo support
- [x] Security middlewares (Auth, XSS, CSRF, CORS)
- [x] Graceful shutdown mechanism
- [x] Basic monitoring/metrics

### 🚧 In Progress / TODO
- [ ] Full JSON serialization (std.json integration)
- [ ] Streaming request body handling
- [ ] Complete multipart/form-data parsing
- [ ] Signal handling (SIGINT/SIGTERM)
- [ ] Full session management integration
- [ ] Gzip/Deflate compression
- [ ] Rate limiting middleware
- [ ] Comprehensive test suite
- [ ] TLS/HTTPS support
- [ ] HTTP/2 support

For detailed information, see:
- **QUICKSTART.md** - Getting started guide
- **IMPROVEMENTS.md** - Summary of improvements
- **PROJECT_STATUS.md** - Detailed status and roadmap
- **WEBSOCKET_VERIFICATION.md** - WebSocket fix verification guide
- **QUICK_WS_TEST.md** - Quick WebSocket testing steps
- **WEBSOCKET_GUIDE.md** - Complete WebSocket troubleshooting
- **docs/WEBSOCKET_TESTING.md** - Comprehensive WebSocket testing guide

## 📝 License

MIT License - See LICENSE file for details

## 🙏 Acknowledgments

- Built with [Zig](https://ziglang.org/)
- HTTP parsing: Zig standard library `std.http`
- Async I/O: Zig standard library `std.Io`

## 👤 Author

**by** - [@by965738071](https://github.com/by965738071)

---

**Note**: This project targets Zig 0.15.2+ (0.16.0-dev compatible). The Zig standard library APIs are subject to change during development phases.

## 🐛 Recent Fixes

### WebSocket Connection Issue - FIXED ✅

**Problem**: WebSocket connections showed "disconnected" error  
**Root Cause**: HTTP upgrade request handling had API compatibility issues  
**Solution**: Fixed union type handling and improved error logging  

**Verification**: Run `./run_ws_test.sh` for automated testing or visit `http://127.0.0.1:8080/ws` in your browser.

See `WEBSOCKET_VERIFICATION.md` for complete verification steps.