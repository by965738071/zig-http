# AGENTS.md - Agentic Coding Guidelines for Zig-HTTP

This document provides guidelines for agents working on the zig-http project.

## Project Overview

Zig-HTTP is a comprehensive HTTP server implementation in Zig supporting HTTP/1.1, WebSocket, middleware, routing, sessions, and more.

## Build Commands

```bash
# Build the project
zig build

# Run the server
zig build run

# Run with custom arguments
zig build run -- "arg1" "arg2"

# Run tests (if test files exist)
zig test <test_file.zig>

# Run a single test
zig test <test_file.zig> --test-filter <test_name>

# Run tests with specific optimization
zig test -Doptimize=ReleaseFast <test_file.zig>

# Check code (if available)
zig fmt --check src/
```

## Code Style Guidelines

### Imports

```zig
// Standard library import
const std = @import("std");

// Project imports - use relative paths
const httpServer = @import("core/http_server.zig").HTTPServer;
const router = @import("core/router.zig").Router;
const Context = @import("core/context.zig").Context;

// HTTP namespace from std
const http = std.http;
```

### Naming Conventions

- **Types/Structs**: PascalCase (`HTTPServer`, `Router`, `Context`)
- **Functions/Variables**: camelCase (`handleHome`, `initServer`)
- **Constants**: camelCase (`max_connections`, `default_port`)
- **Enums**: PascalCase with Casing for variants (`Status.ok`, `Method.GET`)
- **File names**: snake_case (`http_server.zig`, `context.zig`)

### Documentation

```zig
/// Handler for the home page - displays server demo interface
pub fn handleHome(ctx: *Context) !void {
}

/// Server    // ...
 configuration struct
const ServerConfig = struct {
    // ...
};
```

### Error Handling

- Use `try` for functions that can fail
- Use `!void` return type for handlers that can error
- Use `catch` for error recovery
- Use `defer` for cleanup

```zig
pub fn handleHome(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "text/html");
    try ctx.response.write("Hello, World!");
}
```

### Memory Management

- Always use `testing.allocator` in tests
- Use `defer` to free resources
- Check for memory leaks with GPA

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.err("Memory leak detected", .{});
        }
    }
    const allocator = gpa.allocator();
}
```

### Struct Initialization

```zig
// Direct initialization
const server = try HTTPServer.init(allocator, .{
    .port = 8080,
    .host = "0.0.0.0",
});

// Field access
server.setRouter(route);
```

### Handler Functions

All route handlers follow this signature:

```zig
pub fn handleRoute(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{ .status = "ok" });
}
```

### Middleware Pattern

```zig
pub const MiddlewareName = struct {
    middleware: Middleware,

    pub fn init(allocator: std.mem.Allocator, options: Options) !MiddlewareName {
        var middleware = try allocator.create(MiddlewareName);
        middleware.* = .{
            .middleware = Middleware{
                .name = "middleware_name",
                .handle = handleMiddleware,
            },
        };
        return middleware;
    }

    fn handleMiddleware(ctx: *Context, next: *const fn (*Context) !void) !void {
        // Pre-processing
        try next(ctx);
        // Post-processing
    }
};
```

### Response Methods

```zig
// Set status
ctx.response.setStatus(http.Status.ok);

// Set headers
try ctx.response.setHeader("Content-Type", "application/json");

// Write plain text
try ctx.response.write("Hello");

// Write JSON
try ctx.response.writeJSON(.{ .key = "value" });

// Get headers
const value = ctx.response.getHeader("Content-Type");
const has = ctx.response.hasHeader("X-Custom");
```

### Router Registration

```zig
var route = try router.init(allocator);
defer route.deinit();

try route.addRoute(http.Method.GET, "/path", handler);
try route.addRoute(http.Method.POST, "/api/submit", handlers.api.handleSubmit);
```

### Testing Conventions

```zig
const std = @import("std");
const testing = std.testing;

test "test name describes behavior" {
    const allocator = testing.allocator;
    
    // Test setup
    var item = try Item.init(allocator);
    defer item.deinit();
    
    // Assertions
    try testing.expect(item.value == expected);
}
```

### Module Organization

```
src/
├── main.zig           # Entry point
├── core/              # Core library (HTTPServer, Router, Context)
│   ├── lib.zig       # Public exports
│   ├── http_server.zig
│   ├── router.zig
│   ├── context.zig
│   └── response.zig
├── handlers/          # Route handlers
│   ├── lib.zig       # Handler exports
│   ├── home.zig
│   ├── api.zig
│   └── ...
├── middleware/        # Middleware implementations
│   ├── auth.zig
│   ├── cors.zig
│   └── ...
└── utils/             # Utility functions
```

### Working with Optional Types

```zig
// Null-safe access
const value = ctx.getState("key") orelse default_value;

// Optional struct fields
if (ctx.params) |params| {
    const id = params.get("id") orelse "";
}
```

### String Handling

- Use `[]const u8` for string slices when possible
- Use `std.mem.eql(u8, a, b)` for comparison
- Use `try allocator.dupe(u8, str)` to duplicate strings

### Common Patterns

1. **Initialization with heap allocation**:
```zig
const rate_limiter = try allocator.create(RateLimiter);
rate_limiter.* = RateLimiter.init(allocator, .{});
defer {
    rate_limiter.deinit();
    allocator.destroy(rate_limiter);
}
```

2. **Array list usage**:
```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.appendSlice(data);
```

3. **HashMap usage**:
```zig
var map = std.StringHashMap(Value).init(allocator);
defer map.deinit();
try map.put(key, value);
```

## Development Workflow

1. Make changes to source files in `src/`
2. Build with `zig build`
3. Run with `zig build run`
4. Test endpoints at `http://127.0.0.1:8080`

## Key Files

- `src/main.zig` - Server initialization and route setup
- `src/core/http_server.zig` - Main HTTP server implementation
- `src/core/router.zig` - Routing logic
- `src/core/context.zig` - Request/response context
- `src/handlers/` - All route handlers

## Important Notes

- This project uses Zig's new IO interface (`std.Io`)
- Requires Zig 0.16.0-dev.2193+fc517bd01 or later
- The server runs on `http://127.0.0.1:8080` by default
- WebSocket endpoint: `WS /ws/echo`
