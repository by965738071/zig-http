# Zig-HTTP 集成测试文档

## 目录

- [测试概述](#测试概述)
- [环境准备](#环境准备)
- [单元测试](#单元测试)
- [集成测试](#集成测试)
- [性能测试](#性能测试)
- [端到端测试](#端到端测试)
- [测试最佳实践](#测试最佳实践)

---

## 测试概述

Zig-HTTP 提供了完整的测试框架，包括：
- 单元测试（模块级测试）
- 集成测试（API 端点测试）
- 性能测试（基准测试）
- 端到端测试（完整流程测试）

### 测试目录结构

```
zig-http/
├── tests/
│   ├── unit/              # 单元测试
│   ├── integration/       # 集成测试
│   ├── performance/       # 性能测试
│   └── e2e/              # 端到端测试
└── src/
    └── test_utils.zig    # 测试工具
```

---

## 环境准备

### 1. 安装依赖

```bash
# 安装 Zig (需要 0.15.2+ 版本)
# 访问 https://ziglang.org/download/ 下载

# 验证安装
zig version
```

### 2. 安装测试工具

```bash
# 安装 HTTP 客户端工具（可选，用于手动测试）
# macOS
brew install httpie curl jq

# Linux (Ubuntu/Debian)
sudo apt-get install httpie curl jq

# 使用 Cargo (Rust) 安装测试工具
cargo install httpie
```

### 3. 创建测试目录

```bash
mkdir -p tests/unit
mkdir -p tests/integration
mkdir -p tests/performance
mkdir -p tests/e2e
```

---

## 单元测试

单元测试针对单个模块或函数进行测试，通常不涉及网络 I/O。

### 1. 工具函数测试

```zig
// tests/unit/utils_test.zig
const std = @import("std");
const testing = std.testing;
const utils = @import("../../src/utils.zig");

test "generateRequestId generates unique IDs" {
    const allocator = testing.allocator;

    const id1 = try utils.generateRequestId(allocator, std.Io{});
    defer allocator.free(id1);

    const id2 = try utils.generateRequestId(allocator, std.Io{});
    defer allocator.free(id2);

    try testing.expect(!std.mem.eql(u8, id1, id2));
    try testing.expect(id1.len > 0);
}

test "isPathSafe validates paths" {
    // 安全路径
    try testing.expect(utils.isPathSafe("/var/www/index.html", "/var/www"));

    // 不安全路径（路径遍历）
    try testing.expect(!utils.isPathSafe("/var/www/../etc/passwd", "/var/www"));
}

test "isFilenameSafe validates filenames" {
    try testing.expect(utils.isFilenameSafe("file.txt"));
    try testing.expect(utils.isFilenameSafe("image-123.jpg"));

    // 不安全的文件名
    try testing.expect(!utils.isFilenameSafe("../../etc/passwd"));
    try testing.expect(!utils.isFilenameSafe("file\x00.txt"));
}

test "isValidMethod validates HTTP methods" {
    try testing.expect(utils.isValidMethod("GET"));
    try testing.expect(utils.isValidMethod("POST"));
    try testing.expect(utils.isValidMethod("PUT"));
    try testing.expect(utils.isValidMethod("DELETE"));

    try testing.expect(!utils.isValidMethod("INVALID"));
    try testing.expect(!utils.isValidMethod(""));
}

test "containsSqlInjection detects SQL injection" {
    try testing.expect(utils.containsSqlInjection("SELECT * FROM users WHERE id = 1 OR 1=1"));
    try testing.expect(utils.containsSqlInjection("admin'--"));

    try testing.expect(!utils.containsSqlInjection("Hello, world!"));
}

test "containsXss detects XSS attacks" {
    try testing.expect(utils.containsXss("<script>alert('xss')</script>"));
    try testing.expect(utils.containsXss("<img src=x onerror=alert('xss')>"));

    try testing.expect(!utils.containsXss("Hello, world!"));
}

test "escapeHtml escapes HTML special characters" {
    const input = "<script>alert('hi')</script>";
    const output = utils.escapeHtml(input);

    try testing.expect(!std.mem.indexOf(u8, output, "<script") != null);
    try testing.expect(std.mem.indexOf(u8, output, "&lt;script") != null);
}
```

### 2. Context 测试

```zig
// tests/unit/context_test.zig
const std = @import("std");
const testing = std.testing;
const Context = @import("../../src/context.zig").Context;
const HTTPServer = @import("../../src/http_server.zig").HTTPServer;

test "Context initializes correctly" {
    const allocator = testing.allocator;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try HTTPServer.init(gpa.allocator(), .{ .port = 8080 });
    defer server.deinit();

    var response = try @import("../../src/response.zig").Response.init(allocator);
    defer response.deinit();

    // 简化的测试 - 实际需要模拟 HTTP Request
    try testing.expect(server.port == 8080);
}

test "Context stores and retrieves state" {
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, null, null, null, std.Io{});
    defer ctx.deinit();

    const key = "test_key";
    const value: u32 = 123;

    try ctx.setState(key, &value);

    const retrieved = ctx.getState(key) orelse {
        try testing.expect(false);
        return;
    };

    const ptr: *const u32 = @ptrCast(@alignCast(retrieved));
    try testing.expect(ptr.* == 123);
}
```

### 3. Response 测试

```zig
// tests/unit/response_test.zig
const std = @import("std");
const testing = std.testing;
const Response = @import("../../src/response.zig").Response;

test "Response initializes with default status" {
    const allocator = testing.allocator;

    var response = try Response.init(allocator);
    defer response.deinit();

    try testing.expect(@intFromEnum(response.status) == 200);
}

test "Response sets and gets headers" {
    const allocator = testing.allocator;

    var response = try Response.init(allocator);
    defer response.deinit();

    try response.setHeader("Content-Type", "application/json");

    const content_type = response.getHeader("Content-Type") orelse {
        try testing.expect(false);
        return;
    };

    try testing.expect(std.mem.eql(u8, content_type, "application/json"));
}

test "Response has header check" {
    const allocator = testing.allocator;

    var response = try Response.init(allocator);
    defer response.deinit();

    try response.setHeader("X-Custom", "value");

    try testing.expect(response.hasHeader("X-Custom"));
    try testing.expect(!response.hasHeader("X-Missing"));
}

test "Response writes data" {
    const allocator = testing.allocator;

    var response = try Response.init(allocator);
    defer response.deinit();

    try response.write("Hello, ");
    try response.write("World!");

    try testing.expect(std.mem.eql(u8, response.body.items, "Hello, World!"));
}

test "Response writeJSON" {
    const allocator = testing.allocator;

    var response = try Response.init(allocator);
    defer response.deinit();

    const data = struct { name: []const u8, age: u32 }{
        .name = "Alice",
        .age = 30,
    };

    try response.writeJSON(data);

    const content_type = response.getHeader("Content-Type") orelse "";
    try testing.expect(std.mem.indexOf(u8, content_type, "application/json") != null);
    try testing.expect(std.mem.indexOf(u8, response.body.items, "Alice") != null);
}

test "Response reset" {
    const allocator = testing.allocator;

    var response = try Response.init(allocator);
    defer response.deinit();

    try response.setHeader("X-Test", "value");
    try response.write("data");

    response.reset();

    try testing.expect(@intFromEnum(response.status) == 200);
    try testing.expect(!response.hasHeader("X-Test"));
    try testing.expect(response.body.items.len == 0);
}
```

### 4. Session 测试

```zig
// tests/unit/session_test.zig
const std = @import("std");
const testing = std.testing;
const SessionManager = @import("../../src/session.zig").SessionManager;
const MemorySessionStore = @import("../../src/session.zig").MemorySessionStore;

test "SessionManager creates and retrieves sessions" {
    const allocator = testing.allocator;

    var session_manager = SessionManager.init(allocator);
    defer session_manager.deinit();

    var store = MemorySessionStore.init(allocator, 3600);
    defer store.deinit();

    session_manager.setSessionStore(&store.base);

    // 创建会话
    const session = try session_manager.createSession();
    defer session.deinit();

    // 设置数据
    try session.set("user_id", "123");
    try session.set("username", "alice");

    // 获取数据
    const user_id = session.get("user_id") orelse {
        try testing.expect(false);
        return;
    };

    try testing.expect(std.mem.eql(u8, user_id, "123"));

    // 通过 ID 获取会话
    const retrieved = try session_manager.getSession(session.id);
    defer retrieved.deinit();

    const retrieved_user_id = retrieved.get("user_id") orelse "";
    try testing.expect(std.mem.eql(u8, retrieved_user_id, "123"));
}

test "Session expires after TTL" {
    const allocator = testing.allocator;

    var session_manager = SessionManager.init(allocator);
    defer session_manager.deinit();

    var store = MemorySessionStore.init(allocator, 1); // 1 秒过期
    defer store.deinit();

    session_manager.setSessionStore(&store.base);

    const session = try session_manager.createSession();
    const session_id = session.id;

    // 等待过期
    std.time.sleep(2 * std.time.ns_per_s);

    const retrieved = session_manager.getSession(session_id) catch null;
    try testing.expect(retrieved == null);
}
```

### 5. 运行单元测试

```bash
# 运行所有单元测试
zig test tests/unit/utils_test.zig
zig test tests/unit/context_test.zig
zig test tests/unit/response_test.zig
zig test tests/unit/session_test.zig

# 运行单个测试
zig test tests/unit/utils_test.zig --test-filter generateRequestId

# 运行所有测试
zig test tests/unit/*.zig
```

---

## 集成测试

集成测试测试多个模块之间的交互，通常涉及完整的 HTTP 请求/响应周期。

### 1. HTTP 服务器集成测试

```zig
// tests/integration/http_server_test.zig
const std = @import("std");
const testing = std.testing;
const HTTPServer = @import("../../src/http_server.zig").HTTPServer;

test "HTTP server starts and responds to GET request" {
    const allocator = testing.allocator;

    var server = try HTTPServer.init(allocator, .{
        .port = 18080,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // 启动服务器（后台）
    const server_thread = try std.Thread.spawn(.{}, serverRunner, .{&server});
    defer server_thread.join();

    std.time.sleep(100 * std.time.ns_per_ms);

    // 发送 HTTP 请求
    var client = try std.net.tcp.connectToHost(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 18080),
    );
    defer client.stream.close();

    try client.stream.writer().writeAll(
        "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "\r\n"
    );

    var buffer: [4096]u8 = undefined;
    const n = try client.stream.reader().readAll(&buffer);

    try testing.expect(n > 0);
    const response = buffer[0..n];
    try testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1") != null);
}

fn serverRunner(server: *HTTPServer) !void {
    try server.start();
}
```

### 2. 路由集成测试

```zig
// tests/integration/router_test.zig
const std = @import("std");
const testing = std.testing;
const HTTPServer = @import("../../src/http_server.zig").HTTPServer;

test "Router matches paths with parameters" {
    const allocator = testing.allocator;

    var server = try HTTPServer.init(allocator, .{ .port = 18081 });
    defer server.deinit();

    // 注册带参数的路由
    try server.get("/users/:id", userHandler);

    const server_thread = try std.Thread.spawn(.{}, serverRunner, .{&server});
    defer server_thread.join();

    std.time.sleep(100 * std.time.ns_per_ms);

    // 测试带参数的路径
    var client = try std.net.tcp.connectToHost(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 18081),
    );
    defer client.stream.close();

    try client.stream.writer().writeAll(
        "GET /users/123 HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "\r\n"
    );

    var buffer: [4096]u8 = undefined;
    const n = try client.stream.reader().readAll(&buffer);

    try testing.expect(std.mem.indexOf(u8, buffer[0..n], "123") != null);
}

fn userHandler(ctx: *HTTPServer.Context) !void {
    const user_id = ctx.params.get("id") orelse "unknown";
    try ctx.response.writeJSON(.{ .user_id = user_id });
}

fn serverRunner(server: *HTTPServer) !void {
    try server.start();
}
```

### 3. 中间件集成测试

```zig
// tests/integration/middleware_test.zig
const std = @import("std");
const testing = std.testing;
const HTTPServer = @import("../../src/http_server.zig").HTTPServer;
const Middleware = @import("../../src/middleware.zig").Middleware;

test "Logging middleware logs requests" {
    const allocator = testing.allocator;

    var server = try HTTPServer.init(allocator, .{ .port = 18082 });
    defer server.deinit();

    // 注册日志中间件
    const logging = LoggingMiddleware{};
    try server.use(&logging.base);

    try server.get("/test", testHandler);

    const server_thread = try std.Thread.spawn(.{}, serverRunner, .{&server});
    defer server_thread.join();

    std.time.sleep(100 * std.time.ns_per_ms);

    // 发送请求
    _ = try sendHttpRequest("127.0.0.1", 18082, "GET /test HTTP/1.1\r\n\r\n");
}

const LoggingMiddleware = struct {
    base: Middleware,

    fn handle(ctx: *HTTPServer.Context, next: *const fn (ctx: *HTTPServer.Context) anyerror!void) !void {
        std.log.info("{s} {s}", .{ ctx.method, ctx.path });
        try next(ctx);
    }
};

fn testHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.write("OK");
}

fn sendHttpRequest(host: []const u8, port: u16, request: []const u8) ![]u8 {
    const allocator = testing.allocator;

    var client = try std.net.tcp.connectToHost(
        allocator,
        try std.net.Address.parseIp(host, port),
    );
    defer client.stream.close();

    try client.stream.writer().writeAll(request);

    var buffer: [4096]u8 = undefined;
    const n = try client.stream.reader().readAll(&buffer);

    return try allocator.dupe(u8, buffer[0..n]);
}

fn serverRunner(server: *HTTPServer) !void {
    try server.start();
}
```

### 4. 运行集成测试

```bash
# 运行集成测试
zig test tests/integration/http_server_test.zig
zig test tests/integration/router_test.zig
zig test tests/integration/middleware_test.zig
```

---

## 性能测试

性能测试用于测量系统的性能指标，如吞吐量、延迟等。

### 1. 基准测试

```zig
// tests/performance/benchmark_test.zig
const std = @import("std");
const testing = std.testing;
const benchmark = @import("../../src/benchmark.zig");

test "Benchmark string allocation" {
    const result = try benchmark.benchmarkStringAlloc();
    std.log.info("String allocation: {d} ops/s", .{result.throughput});
}

test "Benchmark JSON parsing" {
    const result = try benchmark.benchmarkJsonParse();
    std.log.info("JSON parsing: {d} ops/s", .{result.throughput});
}

test "Benchmark URL encoding" {
    const result = try benchmark.benchmarkUrlEncode();
    std.log.info("URL encoding: {d} ops/s", .{result.throughput});
}

test "Benchmark hashmap operations" {
    const result = try benchmark.benchmarkHashmap();
    std.log.info("Hashmap: {d} ops/s", .{result.throughput});
}
```

### 2. HTTP 性能测试

```zig
// tests/performance/http_benchmark.zig
const std = @import("std");
const testing = std.testing;
const HTTPServer = @import("../../src/http_server.zig").HTTPServer;

test "HTTP server performance test" {
    const allocator = testing.allocator;
    const port: u16 = 18083;

    var server = try HTTPServer.init(allocator, .{ .port = port });
    defer server.deinit();

    try server.get("/", simpleHandler);

    const server_thread = try std.Thread.spawn(.{}, serverRunner, .{&server});
    defer server_thread.join();

    std.time.sleep(100 * std.time.ns_per_ms);

    // 运行性能测试
    const iterations = 1000;
    var total_time: i128 = 0;

    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();

        _ = try sendHttpRequest("127.0.0.1", port, "GET / HTTP/1.1\r\n\r\n");

        const end = std.time.nanoTimestamp();
        total_time += end - start;
    }

    const avg_time_ns = @divTrunc(total_time, iterations);
    const avg_time_ms = @as(f64, @floatFromInt(avg_time_ns)) / 1_000_000.0;
    const throughput = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(total_time)) / 1_000_000_000.0);

    std.log.info("Average response time: {d:.2}ms", .{avg_time_ms});
    std.log.info("Throughput: {d:.2} requests/sec", .{throughput});
}

fn simpleHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.write("Hello, World!");
}

fn serverRunner(server: *HTTPServer) !void {
    try server.start();
}

fn sendHttpRequest(host: []const u8, port: u16, request: []const u8) ![]u8 {
    const allocator = testing.allocator;

    var client = try std.net.tcp.connectToHost(
        allocator,
        try std.net.Address.parseIp(host, port),
    );
    defer client.stream.close();

    try client.stream.writer().writeAll(request);

    var buffer: [4096]u8 = undefined;
    const n = try client.stream.reader().readAll(&buffer);

    return try allocator.dupe(u8, buffer[0..n]);
}
```

### 3. 并发测试

```zig
// tests/performance/concurrent_test.zig
const std = @import("std");
const testing = std.testing;
const HTTPServer = @import("../../src/http_server.zig").HTTPServer;

test "Concurrent request handling" {
    const allocator = testing.allocator;
    const port: u16 = 18084;
    const num_threads = 10;
    const requests_per_thread = 100;

    var server = try HTTPServer.init(allocator, .{ .port = port });
    defer server.deinit();

    try server.get("/", simpleHandler);

    const server_thread = try std.Thread.spawn(.{}, serverRunner, .{&server});
    defer server_thread.join();

    std.time.sleep(100 * std.time.ns_per_ms);

    // 创建工作线程
    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = .{null} ** num_threads;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{
            port,
            requests_per_thread,
            &errors[i],
        });
    }

    // 等待所有线程完成
    for (threads) |thread| {
        thread.join();
    }

    // 检查错误
    for (errors) |err| {
        if (err) |e| {
            std.log.err("Worker error: {}", .{e});
            try testing.expect(false);
        }
    }

    std.log.info("Successfully handled {d} concurrent requests", .{num_threads * requests_per_thread});
}

fn workerFn(port: u16, num_requests: usize, error_ptr: *?anyerror) void {
    error_ptr.* = worker(port, num_requests) catch |e| e;
}

fn worker(port: u16, num_requests: usize) !void {
    const allocator = testing.allocator;

    for (0..num_requests) |_| {
        var client = try std.net.tcp.connectToHost(
            allocator,
            try std.net.Address.parseIp("127.0.0.1", port),
        );
        defer client.stream.close();

        try client.stream.writer().writeAll("GET / HTTP/1.1\r\n\r\n");

        var buffer: [4096]u8 = undefined;
        _ = try client.stream.reader().readAll(&buffer);
    }
}

fn simpleHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.write("OK");
}

fn serverRunner(server: *HTTPServer) !void {
    try server.start();
}
```

### 4. 运行性能测试

```bash
# 运行性能测试
zig test tests/performance/benchmark_test.zig
zig test tests/performance/http_benchmark.zig
zig test tests/performance/concurrent_test.zig

# 使用 Release 优化模式
zig test -Doptimize=ReleaseFast tests/performance/*.zig
```

---

## 端到端测试

端到端测试模拟完整的用户场景。

### 1. REST API 端到端测试

```zig
// tests/e2e/api_test.zig
const std = @import("std");
const testing = std.testing;

test "E2E: User CRUD operations" {
    const allocator = testing.allocator;

    // 1. 创建用户
    const create_body = \\{"name":"Alice","email":"alice@example.com"}
    ;
    const create_response = try sendPostRequest(18085, "/api/users", create_body);
    defer allocator.free(create_response);

    try testing.expect(std.mem.indexOf(u8, create_response, "\"success\":true") != null);

    // 2. 获取用户列表
    const list_response = try sendGetRequest(18085, "/api/users");
    defer allocator.free(list_response);

    try testing.expect(std.mem.indexOf(u8, list_response, "Alice") != null);

    // 3. 获取单个用户
    const get_response = try sendGetRequest(18085, "/api/users/1");
    defer allocator.free(get_response);

    try testing.expect(std.mem.indexOf(u8, get_response, "\"id\":1") != null);

    // 4. 更新用户
    const update_body = \\{"name":"Alice Updated"}
    ;
    const update_response = try sendPutRequest(18085, "/api/users/1", update_body);
    defer allocator.free(update_response);

    try testing.expect(std.mem.indexOf(u8, update_response, "Alice Updated") != null);

    // 5. 删除用户
    const delete_response = try sendDeleteRequest(18085, "/api/users/1");
    defer allocator.free(delete_response);

    try testing.expect(std.mem.indexOf(u8, delete_response, "\"success\":true") != null);
}

fn sendGetRequest(port: u16, path: []const u8) ![]u8 {
    const allocator = testing.allocator;

    var request_buf = std.ArrayList(u8).init(allocator);
    defer request_buf.deinit();

    try request_buf.writer().print("GET {s} HTTP/1.1\r\n", .{path});
    try request_buf.appendSlice("Host: 127.0.0.1\r\n");
    try request_buf.appendSlice("\r\n");

    return sendHttpRequest("127.0.0.1", port, request_buf.items);
}

fn sendPostRequest(port: u16, path: []const u8, body: []const u8) ![]u8 {
    const allocator = testing.allocator;

    var request_buf = std.ArrayList(u8).init(allocator);
    defer request_buf.deinit();

    try request_buf.writer().print("POST {s} HTTP/1.1\r\n", .{path});
    try request_buf.appendSlice("Host: 127.0.0.1\r\n");
    try request_buf.writer().print("Content-Length: {d}\r\n", .{body.len});
    try request_buf.appendSlice("Content-Type: application/json\r\n");
    try request_buf.appendSlice("\r\n");
    try request_buf.appendSlice(body);

    return sendHttpRequest("127.0.0.1", port, request_buf.items);
}

fn sendPutRequest(port: u16, path: []const u8, body: []const u8) ![]u8 {
    const allocator = testing.allocator;

    var request_buf = std.ArrayList(u8).init(allocator);
    defer request_buf.deinit();

    try request_buf.writer().print("PUT {s} HTTP/1.1\r\n", .{path});
    try request_buf.appendSlice("Host: 127.0.0.1\r\n");
    try request_buf.writer().print("Content-Length: {d}\r\n", .{body.len});
    try request_buf.appendSlice("Content-Type: application/json\r\n");
    try request_buf.appendSlice("\r\n");
    try request_buf.appendSlice(body);

    return sendHttpRequest("127.0.0.1", port, request_buf.items);
}

fn sendDeleteRequest(port: u16, path: []const u8) ![]const u8 {
    const allocator = testing.allocator;

    var request_buf = std.ArrayList(u8).init(allocator);
    defer request_buf.deinit();

    try request_buf.writer().print("DELETE {s} HTTP/1.1\r\n", .{path});
    try request_buf.appendSlice("Host: 127.0.0.1\r\n");
    try request_buf.appendSlice("\r\n");

    return sendHttpRequest("127.0.0.1", port, request_buf.items);
}

fn sendHttpRequest(host: []const u8, port: u16, request: []const u8) ![]u8 {
    const allocator = testing.allocator;

    var client = try std.net.tcp.connectToHost(
        allocator,
        try std.net.Address.parseIp(host, port),
    );
    defer client.stream.close();

    try client.stream.writer().writeAll(request);

    var buffer: [8192]u8 = undefined;
    const n = try client.stream.reader().readAll(&buffer);

    return try allocator.dupe(u8, buffer[0..n]);
}
```

### 2. WebSocket 端到端测试

```zig
// tests/e2e/websocket_test.zig
const std = @import("std");
const testing = std.testing;

test "E2E: WebSocket echo server" {
    const allocator = testing.allocator;
    const port: u16 = 18086;

    // 1. 连接到 WebSocket
    var ws_client = try connectWebSocket(port, "/ws/echo");
    defer ws_client.deinit();

    // 2. 发送消息
    try ws_client.sendText("Hello, WebSocket!");

    // 3. 接收回显
    const message = try ws_client.receiveMessage();
    defer allocator.free(message);

    try testing.expect(std.mem.eql(u8, message, "Hello, WebSocket!"));

    // 4. 发送 ping
    try ws_client.sendPing("ping");

    // 5. 接收 pong
    const pong = try ws_client.receiveMessage();
    defer allocator.free(pong);

    try testing.expect(std.mem.eql(u8, pong, "ping"));

    // 6. 关闭连接
    try ws_client.sendClose(.normal_closure, "Goodbye!");
}

const WebSocketClient = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,

    fn deinit(self: *WebSocketClient) void {
        self.stream.close();
    }

    fn sendText(self: *WebSocketClient, message: []const u8) !void {
        var frame: [128]u8 = undefined;
        var frame_idx: usize = 0;

        // FIN + Text frame
        frame[frame_idx] = 0x81;
        frame_idx += 1;

        // Payload length
        if (message.len <= 125) {
            frame[frame_idx] = @as(u8, @intCast(message.len));
            frame_idx += 1;
        } else {
            frame[frame_idx] = 126;
            frame_idx += 1;
            std.mem.writeIntBig(u16, frame[frame_idx..][0..2], @intCast(message.len));
            frame_idx += 2;
        }

        // Payload
        @memcpy(frame[frame_idx..][0..message.len], message);

        try self.stream.writer().writeAll(frame[0 .. frame_idx + message.len]);
    }

    fn sendPing(self: *WebSocketClient, message: []const u8) !void {
        var frame: [128]u8 = undefined;
        var frame_idx: usize = 0;

        // FIN + Ping frame
        frame[frame_idx] = 0x89;
        frame_idx += 1;

        // Payload length
        frame[frame_idx] = @as(u8, @intCast(message.len));
        frame_idx += 1;

        // Payload
        @memcpy(frame[frame_idx..][0..message.len], message);

        try self.stream.writer().writeAll(frame[0 .. frame_idx + message.len]);
    }

    fn sendClose(self: *WebSocketClient, code: enum(u16) { normal_closure = 1000 }, reason: []const u8) !void {
        var frame: [128]u8 = undefined;
        var frame_idx: usize = 0;

        // FIN + Close frame
        frame[frame_idx] = 0x88;
        frame_idx += 1;

        const payload_len = 2 + reason.len;
        frame[frame_idx] = @as(u8, @intCast(payload_len));
        frame_idx += 1;

        // Close code
        std.mem.writeIntBig(u16, frame[frame_idx..][0..2], @intFromEnum(code));
        frame_idx += 2;

        // Close reason
        @memcpy(frame[frame_idx..][0..reason.len], reason);

        try self.stream.writer().writeAll(frame[0 .. frame_idx + reason.len]);
    }

    fn receiveMessage(self: *WebSocketClient) ![]u8 {
        var header: [2]u8 = undefined;
        _ = try self.stream.reader().readAll(&header);

        const fin = (header[0] & 0x80) != 0;
        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len = header[1] & 0x7F;

        var extended_len: [8]u8 = undefined;
        if (payload_len == 126) {
            _ = try self.stream.reader().readAll(extended_len[0..2]);
            payload_len = std.mem.readIntBig(u16, &extended_len);
        } else if (payload_len == 127) {
            _ = try self.stream.reader().readAll(&extended_len);
            payload_len = @intCast(std.mem.readIntBig(u64, &extended_len));
        }

        var mask: [4]u8 = undefined;
        if (masked) {
            _ = try self.stream.reader().readAll(&mask);
        }

        var payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);

        _ = try self.stream.reader().readAll(payload);

        if (masked) {
            for (payload, 0..) |byte, i| {
                payload[i] = byte ^ mask[i % 4];
            }
        }

        return payload;
    }
};

fn connectWebSocket(port: u16, path: []const u8) !WebSocketClient {
    const allocator = testing.allocator;

    // 1. 建立 TCP 连接
    const stream = try std.net.tcp.connectToHost(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", port),
    );

    // 2. 发送 WebSocket 握手
    const key = "dGhlIHNhbXBsZSBub25jZQ==";

    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();

    try request.writer().print("GET {s} HTTP/1.1\r\n", .{path});
    try request.appendSlice("Host: 127.0.0.1\r\n");
    try request.appendSlice("Upgrade: websocket\r\n");
    try request.appendSlice("Connection: Upgrade\r\n");
    try request.writer().print("Sec-WebSocket-Key: {s}\r\n", .{key});
    try request.appendSlice("Sec-WebSocket-Version: 13\r\n");
    try request.appendSlice("\r\n");

    try stream.writer().writeAll(request.items);

    // 3. 读取握手响应
    var response: [512]u8 = undefined;
    const n = try stream.reader().readAll(&response);

    // 简化：假设握手成功
    _ = n;

    return .{ .stream = stream, .allocator = allocator };
}
```

### 3. 运行端到端测试

```bash
# 运行端到端测试
zig test tests/e2e/api_test.zig
zig test tests/e2e/websocket_test.zig
```

---

## 测试最佳实践

### 1. 测试命名规范

```zig
// ✅ 好的命名
test "generateRequestId generates unique 16-character IDs"
test "user can login with valid credentials"
test "server handles 1000 concurrent requests without errors"

// ❌ 不好的命名
test "test1"
test "it works"
test "function test"
```

### 2. 使用 testing.allocator

```zig
// ✅ 使用 testing.allocator 检测内存泄漏
test "Context initialization does not leak memory" {
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, null, null, null, std.Io{});
    defer ctx.deinit();

    try testing.expect(ctx.request_id != null);
}
```

### 3. 测试边界条件

```zig
test "Response handles large bodies" {
    const allocator = testing.allocator;

    var response = try Response.init(allocator);
    defer response.deinit();

    // 测试 1MB 数据
    const large_data = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_data);
    @memset(large_data, 'A');

    try response.writeAll(large_data);
    try testing.expect(response.body.items.len == 1024 * 1024);
}
```

### 4. 测试错误处理

```zig
test "Context returns error for invalid JSON" {
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, null, null, null, std.Io{});
    defer ctx.deinit();

    ctx.body_data = "{ invalid json }";

    const parsed = ctx.parseJSON(struct { name: []const u8 });

    try testing.expectError(error.InvalidJson, parsed);
}
```

### 5. 使用测试辅助函数

```zig
// 创建测试辅助函数
fn assertStatusCode(response: []const u8, expected: std.http.Status) !void {
    const allocator = testing.allocator;

    var iter = std.mem.splitScalar(u8, response, ' ');
    _ = iter.next(); // HTTP/1.1
    const code_str = iter.next() orelse return error.MissingStatusCode;

    const code = std.fmt.parseInt(u16, code_str, 10) catch return error.InvalidStatusCode;
    try testing.expect(code == @intFromEnum(expected));
}

// 使用辅助函数
test "Handler returns 404 for missing resource" {
    const response = try sendGetRequest(18085, "/nonexistent");
    defer testing.allocator.free(response);

    try assertStatusCode(response, .not_found);
}
```

---

## 持续集成

### GitHub Actions 配置

```yaml
# .github/workflows/test.yml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
        zig: ['0.15.2', 'master']

    steps:
      - uses: actions/checkout@v3

      - name: Install Zig
        uses: goto-bus/setup-zig@v2
        with:
          version: ${{ matrix.zig }}

      - name: Run unit tests
        run: |
          zig test tests/unit/*.zig

      - name: Run integration tests
        run: |
          zig test tests/integration/*.zig

      - name: Run performance tests
        run: |
          zig test -Doptimize=ReleaseFast tests/performance/*.zig

      - name: Check for memory leaks
        run: |
          zig test --test-no-exec tests/unit/*.zig
          valgrind --leak-check=full ./zig-cache/o/*/test
```

---

## 测试覆盖率

虽然 Zig 本身不提供内置的覆盖率工具，但可以使用以下方法：

```bash
# 使用编译时插桩
zig test -Dcoverage=1 tests/unit/*.zig

# 使用外部工具
kcov --exclude-pattern=/usr/include ./zig-cache/o ./zig-cache/o/*/test
```

---

## 总结

### 测试类型对比

| 测试类型 | 范围 | 速度 | 复杂度 | 维护成本 |
|---------|------|------|--------|----------|
| 单元测试 | 函数/模块 | 快 | 低 | 低 |
| 集成测试 | 多个模块 | 中 | 中 | 中 |
| 性能测试 | 系统性能 | 慢 | 高 | 高 |
| 端到端测试 | 完整流程 | 慢 | 高 | 高 |

### 推荐的测试策略

1. **单元测试**: 覆盖核心逻辑，目标覆盖率 80%+
2. **集成测试**: 覆盖关键 API 端点
3. **性能测试**: 在每个 PR 前运行
4. **端到端测试**: 在发布前运行

---

## 许可证

MIT License
