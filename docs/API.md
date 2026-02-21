# Zig-HTTP API 文档

## 目录

- [快速开始](#快速开始)
- [核心模块](#核心模块)
  - [HTTPServer](#httpserver)
  - [Router](#router)
  - [Context](#context)
  - [Response](#response)
- [中间件](#中间件)
- [高级功能](#高级功能)
  - [会话管理](#会话管理)
  - [静态文件服务](#静态文件服务)
  - [WebSocket](#websocket)
  - [文件上传](#文件上传)
  - [压缩](#压缩)
- [监控与日志](#监控与日志)
- [工具函数](#工具函数)

---

## 快速开始

### 基本示例

```zig
const std = @import("std");
const http_server = @import("http_server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建服务器配置
    const config = http_server.Config{
        .host = "0.0.0.0",
        .port = 8080,
        .max_connections = 1000,
    };

    // 创建并启动服务器
    var server = try http_server.HTTPServer.init(allocator, config);
    defer server.deinit();

    // 注册路由
    try server.get("/", indexHandler);
    try server.get("/api/users", getUsersHandler);
    try server.post("/api/users", createUserHandler);

    // 启动服务器
    try server.start();
}

// 基本处理器
fn indexHandler(ctx: *http_server.Context) !void {
    try ctx.response.write("Hello, World!");
}

fn getUsersHandler(ctx: *http_server.Context) !void {
    const users = struct {
        users: []const struct { id: u32, name: []const u8 },
    }{
        .users = &.{
            .{ .id = 1, .name = "Alice" },
            .{ .id = 2, .name = "Bob" },
        },
    };
    try ctx.response.writeJSON(users);
}

fn createUserHandler(ctx: *http_server.Context) !void {
    // 解析请求体
    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    // 处理创建逻辑...
    try ctx.response.setStatus(.created);
    try ctx.response.writeJSON(.{ .success = true, .message = "User created" });
}
```

### 使用中间件

```zig
const middleware = @import("middleware.zig");

// 创建日志中间件
const logging_middleware = middleware.LoggingMiddleware{
    .handler = loggingHandler,
};

// 创建认证中间件
const auth_middleware = middleware.AuthMiddleware{
    .token = "secret-token",
    .handler = authHandler,
};

// 注册全局中间件
try server.use(&logging_middleware.base);

// 注册路由特定中间件
try server.get("/api/protected", protectedHandler, &.{ &auth_middleware.base });
```

---

## 核心模块

### HTTPServer

HTTP 服务器核心类，负责监听端口、处理连接、路由请求。

#### 配置选项

```zig
pub const Config = struct {
    host: []const u8 = "0.0.0.0",           // 监听地址
    port: u16 = 8080,                       // 监听端口
    max_connections: usize = 1000,         // 最大连接数
    request_timeout: u64 = 30_000,          // 请求超时（毫秒）
    read_buffer_size: usize = 8192,         // 读缓冲区大小
    write_buffer_size: usize = 4096,        // 写缓冲区大小
    max_request_body_size: usize = 10_485_760, // 最大请求体（10MB）
    max_header_size: usize = 8192,          // 最大头部大小
    connection_timeout: u64 = 60_000,       // 连接超时（毫秒）
};
```

#### 方法

##### `init(allocator, config) !HTTPServer`

初始化 HTTP 服务器。

```zig
const config = Config{
    .host = "127.0.0.1",
    .port = 8080,
};
var server = try HTTPServer.init(allocator, config);
defer server.deinit();
```

##### `start() !void`

启动服务器，开始监听连接。

```zig
try server.start();
```

##### `stop() !void`

优雅关闭服务器，等待所有活跃连接完成。

```zig
try server.stop();
```

##### `deinit()`

释放服务器资源。

```zig
server.deinit();
```

#### 路由方法

##### `get(path, handler, middlewares) !void`

注册 GET 路由。

```zig
try server.get("/api/data", getDataHandler);
try server.get("/api/protected", protectedHandler, &.{ &auth_middleware });
```

##### `post(path, handler, middlewares) !void`

注册 POST 路由。

```zig
try server.post("/api/users", createUserHandler);
```

##### `put(path, handler, middlewares) !void`

注册 PUT 路由。

```zig
try server.put("/api/users/:id", updateUserHandler);
```

##### `delete(path, handler, middlewares) !void`

注册 DELETE 路由。

```zig
try server.delete("/api/users/:id", deleteUserHandler);
```

##### `use(middleware) !void`

注册全局中间件。

```zig
try server.use(&logging_middleware.base);
```

##### `setStaticServer(static_server) void`

设置静态文件服务器。

```zig
var static_server = try StaticServer.init(allocator, "./public");
defer static_server.deinit();
server.setStaticServer(&static_server);
```

#### 高级方法

##### `setStaticPath(path) void`

设置静态文件路径（简化版）。

```zig
server.setStaticPath("/public");
```

##### `requestShutdown() void`

请求优雅关闭。

```zig
// 在信号处理程序中调用
server.requestShutdown();
```

##### `isShuttingDown() bool`

检查服务器是否正在关闭。

```zig
if (server.isShuttingDown()) {
    // 处理关闭逻辑
}
```

---

### Router

路由器，支持参数路由和通配符路由。

#### 方法

##### `addRoute(method, path, handler) !void`

添加路由规则。

```zig
var router = Router.init(allocator);
defer router.deinit();

try router.addRoute(.GET, "/users/:id", getUserHandler);
try router.addRoute(.GET, "/files/*", serveFileHandler);
```

##### `match(method, path) !?MatchResult`

匹配路由。

```zig
if (try router.match(.GET, "/users/123")) |result| {
    // result.handler - 处理函数
    // result.params - 路径参数
    const user_id = result.params.get("id") orelse "";
}
```

#### 路由参数

```zig
// 路由定义: /api/users/:id/posts/:post_id
// 请求路径: /api/users/123/posts/456

fn handler(ctx: *Context) !void {
    const user_id = ctx.params.get("id") orelse ""; // "123"
    const post_id = ctx.params.get("post_id") orelse ""; // "456"
    // ...
}
```

---

### Context

请求上下文，包含请求信息、响应构建器、状态存储等。

#### 字段

```zig
pub const Context = struct {
    server: *HTTPServer,                    // 服务器实例
    request: *http.Server.Request,          // 原始请求
    response: *Response,                    // 响应构建器
    params: ParamList,                      // 路由参数
    state: std.StringHashMap(*anyopaque),   // 请求状态存储
    body_parser: ?BodyParser,               // 请求体解析器
    body_data: ?[]u8,                       // 原始请求体
    multipart_form: ?*MultipartForm,        // 表单数据
    cookie_jar: ?CookieJar,                 // Cookie 管理
    session: ?Session,                      // 会话数据
    allocator: std.mem.Allocator,           // 内存分配器
    io: std.Io,                             // I/O 上下文
    request_id: ?[]const u8,                // 请求 ID
};
```

#### 方法

##### 请求信息

```zig
// 获取请求方法
const method = ctx.method; // "GET", "POST", ...

// 获取请求路径
const path = ctx.path; // "/api/users"

// 获取查询参数
const query = ctx.getQuery("page") orelse "1";

// 获取所有查询参数
const all_queries = ctx.getAllQueries();

// 获取请求头
const user_agent = ctx.getHeader("User-Agent") orelse "";

// 获取所有请求头
const all_headers = ctx.getAllHeaders();

// 获取客户端 IP
const ip = ctx.ip_address orelse "unknown";

// 获取请求 ID
const request_id = ctx.getRequestId();
```

##### 请求体处理

```zig
// 获取原始请求体
const body = try ctx.getBody();
defer ctx.allocator.free(body);

// 解析 JSON 请求体
const User = struct { name: []const u8, email: []const u8 };
const user_data = try ctx.parseJSON(User);
defer user_data.deinit(ctx.allocator);

// 解析表单数据
const form_data = try ctx.parseForm();
defer form_data.deinit();

// 获取文件上传
const uploads = try ctx.getUploadedFiles();
defer {
    for (uploads.items) |*upload| {
        upload.deinit(ctx.allocator);
    }
    uploads.deinit(ctx.allocator);
}
```

##### 状态管理

```zig
// 设置状态
try ctx.setState("user", &user_data);

// 获取状态
if (ctx.getState("user")) |user| {
    const user_ptr: *const User = @ptrCast(@alignCast(user));
    // 使用 user_ptr
}
```

##### Cookie 操作

```zig
// 获取 Cookie
const session_id = ctx.getCookie("session_id") orelse "";

// 设置 Cookie
try ctx.setCookie(.{
    .name = "session_id",
    .value = "abc123",
    .max_age = 3600, // 1 小时
    .http_only = true,
    .secure = true,
    .path = "/",
});

// 删除 Cookie
try ctx.deleteCookie("session_id");
```

##### 会话操作

```zig
// 获取会话
const session = try ctx.getSession();
defer session.deinit();

// 设置会话数据
try session.set("user_id", "123");
try session.set("role", "admin");

// 获取会话数据
const user_id = session.get("user_id") orelse "";
```

---

### Response

HTTP 响应构建器。

#### 方法

##### 设置状态

```zig
// 设置状态码
ctx.response.setStatus(.ok); // 200
ctx.response.setStatus(.created); // 201
ctx.response.setStatus(.not_found); // 404
ctx.response.setStatus(.internal_server_error); // 500

// 使用数字
ctx.response.setStatus(@enumFromInt(200));
```

##### 设置头部

```zig
// 设置头部
try ctx.response.setHeader("Content-Type", "application/json");
try ctx.response.setHeader("Cache-Control", "no-cache");
try ctx.response.setHeader("X-Custom-Header", "value");

// 检查头部是否存在
if (ctx.response.hasHeader("Content-Type")) {
    // 头部存在
}

// 获取头部
const content_type = ctx.response.getHeader("Content-Type");
```

##### 写入响应体

```zig
// 写入文本
try ctx.response.write("Hello, World!");

// 写入格式化文本
try ctx.response.writer().print("User: {s}, ID: {d}\n", .{ name, id });

// 写入 JSON
const data = struct { name: []const u8, age: u32 }{
    .name = "Alice",
    .age = 30,
};
try ctx.response.writeJSON(data);

// 写入原始字节
try ctx.response.writeAll(binary_data);

// 追加数据
try ctx.response.appendSlice(more_data);
```

##### 重定向

```zig
// 临时重定向
ctx.response.setStatus(.found);
try ctx.response.setHeader("Location", "/new-location");

// 永久重定向
ctx.response.setStatus(.moved_permanently);
try ctx.response.setHeader("Location", "/new-location");
```

##### 文件下载

```zig
ctx.response.setStatus(.ok);
try ctx.response.setHeader("Content-Type", "application/octet-stream");
try ctx.response.setHeader("Content-Disposition", "attachment; filename=\"file.txt\"");
try ctx.response.writeAll(file_content);
```

##### 流式响应

```zig
// 使用流式响应处理大数据
const chunk_size = 4096;
var buffer: [chunk_size]u8 = undefined;

while (try source_stream.read(&buffer)) |bytes_read| {
    if (bytes_read == 0) break;
    try ctx.response.writeAll(buffer[0..bytes_read]);
}
```

---

## 中间件

### 中间件基础

中间件是一个可以在请求处理前后执行逻辑的组件。

```zig
const Middleware = struct {
    base: struct {
        handler: HandlerFn,
        order: usize,
    },
};

pub const HandlerFn = *const fn (ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) anyerror!void;
```

### 内置中间件

#### 日志中间件

```zig
const middleware = @import("middleware.zig");

const logging_middleware = middleware.LoggingMiddleware{
    .handler = loggingHandler,
};

fn loggingHandler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) !void {
    const start_time = std.time.nanoTimestamp();
    try next(ctx);
    const end_time = std.time.nanoTimestamp();
    const duration_ms = (end_time - start_time) / 1_000_000;

    std.log.info("{s} {s} - {d}ms - {d}", .{
        ctx.method,
        ctx.path,
        duration_ms,
        ctx.response.status,
    });
}
```

#### 认证中间件

```zig
const auth_middleware = AuthMiddleware{
    .token = "secret-token",
    .handler = authHandler,
};

fn authHandler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) !void {
    const auth_header = ctx.getHeader("Authorization") orelse {
        ctx.response.setStatus(.unauthorized);
        try ctx.response.writeJSON(.{ .error = "Missing authorization" });
        return;
    };

    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        ctx.response.setStatus(.unauthorized);
        try ctx.response.writeJSON(.{ .error = "Invalid authorization format" });
        return;
    }

    const token = auth_header["Bearer ".len..];
    if (!std.mem.eql(u8, token, "secret-token")) {
        ctx.response.setStatus(.unauthorized);
        try ctx.response.writeJSON(.{ .error = "Invalid token" });
        return;
    }

    try next(ctx);
}
```

#### CORS 中间件

```zig
const cors_middleware = middleware.CORSMiddleware{
    .handler = corsHandler,
};

fn corsHandler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) !void {
    // 设置 CORS 头部
    try ctx.response.setHeader("Access-Control-Allow-Origin", "*");
    try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    // 处理 OPTIONS 预检请求
    if (std.mem.eql(u8, ctx.method, "OPTIONS")) {
        ctx.response.setStatus(.ok);
        return;
    }

    try next(ctx);
}
```

#### 速率限制中间件

```zig
const rate_limiter = RateLimiter{
    .max_requests = 100,
    .window_seconds = 60,
};

fn rateLimitHandler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) !void {
    const ip = ctx.ip_address orelse "unknown";

    if (!rate_limiter.allow(ip)) {
        ctx.response.setStatus(.too_many_requests);
        try ctx.response.writeJSON(.{ .error = "Too many requests" });
        return;
    }

    try next(ctx);
}
```

### 自定义中间件

```zig
// 自定义中间件示例
const my_middleware = struct {
    fn handler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) !void {
        // 前置逻辑
        const start_time = std.time.nanoTimestamp();

        // 调用下一个处理器
        try next(ctx);

        // 后置逻辑
        const duration = std.time.nanoTimestamp() - start_time;
        std.log.debug("Request processed in {d}ns", .{duration});
    }
};

// 注册中间件
const middleware_obj = Middleware{
    .base = .{
        .handler = my_middleware.handler,
        .order = 0,
    },
};
try server.use(&middleware_obj.base);
```

---

## 高级功能

### 会话管理

#### 初始化会话管理器

```zig
var session_manager = SessionManager.init(allocator);
defer session_manager.deinit();

try session_manager.startCleanupTask(300); // 每 5 分钟清理过期会话
defer session_manager.stopCleanupTask();
```

#### 内存会话存储

```zig
// 内存会话存储（默认）
var session_store = MemorySessionStore.init(allocator, 3600); // 1 小时过期
defer session_store.deinit();

session_manager.setSessionStore(&session_store.base);
```

#### 文件会话存储

```zig
// 文件会话存储
var file_store = FileSessionStore.init(allocator, "./sessions", 3600);
defer file_store.deinit();

session_manager.setSessionStore(&file_store.base);
```

#### 使用会话

```zig
fn handler(ctx: *Context) !void {
    // 获取或创建会话
    const session = try ctx.getSession();

    // 设置会话数据
    try session.set("user_id", "123");
    try session.set("username", "alice");

    // 获取会话数据
    const user_id = session.get("user_id") orelse "";

    // 删除会话数据
    _ = session.delete("username");

    // 销毁会话
    try ctx.destroySession();
}
```

### 静态文件服务

#### 基本用法

```zig
var static_server = try StaticServer.init(allocator, "./public");
defer static_server.deinit();

server.setStaticServer(&static_server);
```

#### 自定义配置

```zig
var config = StaticServer.Config{
    .root_path = "./public",
    .index_file = "index.html",
    .enable_compression = true,
    .enable_range = true,
    .enable_etag = true,
};

var static_server = try StaticServer.initWithConfig(allocator, config);
defer static_server.deinit();
```

#### 自定义路由

```zig
// 静态文件路由
try server.get("/static/*", staticHandler);

fn staticHandler(ctx: *Context) !void {
    const static_server = server.static_server orelse {
        ctx.response.setStatus(.internal_server_error);
        try ctx.response.write("Static server not configured");
        return;
    };

    try static_server.serve(ctx);
}
```

### WebSocket

#### 基本 WebSocket 服务器

```zig
const websocket = @import("websocket.zig");

var ws_server = WebSocketServer.init(allocator);
defer ws_server.deinit();

// 注册 WebSocket 路由
try ws_server.handle("/ws/echo", echoHandler);
```

#### WebSocket 处理器

```zig
fn echoHandler(conn: *websocket.Connection) !void {
    while (conn.state == .connected) {
        const message = try conn.readMessage() orelse continue;
        defer message.deinit();

        switch (message.type) {
            .text => {
                // 回显文本消息
                try conn.sendMessage(.text, message.data);
            },
            .binary => {
                // 回显二进制消息
                try conn.sendMessage(.binary, message.data);
            },
            .ping => {
                // 响应 ping
                try conn.sendPong(message.data);
            },
            .close => {
                // 关闭连接
                try conn.sendClose(.normal_closure, "");
                return;
            },
        }
    }
}
```

#### 广播消息

```zig
// 向所有连接广播
fn broadcastHandler(ws_server: *WebSocketServer, message: []const u8) !void {
    var iter = ws_server.connections.iterator();
    while (iter.next()) |entry| {
        const conn = entry.value_ptr.*;
        try conn.sendMessage(.text, message);
    }
}
```

### 文件上传

#### 基本文件上传

```zig
fn uploadHandler(ctx: *Context) !void {
    const multipart_form = try ctx.getMultipartForm();
    defer multipart_form.deinit(ctx.allocator);

    // 获取上传的文件
    const files = multipart_form.getFiles("file");
    for (files) |file| {
        // 保存文件
        const out_file = try std.fs.cwd().createFile(
            std.fs.path.join(ctx.allocator, &.{"./uploads", file.filename}) catch continue,
            .{},
        );
        defer out_file.close();

        try out_file.writeAll(file.data);
    }

    try ctx.response.writeJSON(.{ .success = true, .message = "Files uploaded" });
}
```

#### 文件上传进度

```zig
const upload_progress = @import("upload_progress.zig");

var tracker = upload_progress.UploadTracker.init(allocator);
defer tracker.deinit();

fn uploadWithProgress(ctx: *Context) !void {
    const upload_id = try utils.generateShortId(allocator, ctx.io);
    _ = tracker.startUpload(upload_id, "file.txt");

    // 在处理过程中更新进度
    try tracker.updateProgress(upload_id, 50, 1024 * 1024); // 50%, 1MB

    // 使用回调
    try tracker.setProgressCallback(upload_id, .{
        .handler = consoleProgressCallback,
    });

    try ctx.response.writeJSON(.{ .upload_id = upload_id });
}
```

### 压缩

#### 启用压缩

```zig
const compression = @import("compression.zig");

var compressor = compression.GzipCompressor.init(allocator);
defer compressor.deinit();

fn compressedHandler(ctx: *Context) !void {
    const data = "Large content here...";
    const compressed = try compressor.compress(data);
    defer compressor.allocator.free(compressed);

    try ctx.response.setHeader("Content-Encoding", "gzip");
    try ctx.response.writeAll(compressed);
}
```

#### 压缩中间件

```zig
const compression_middleware = compression.CompressionMiddleware{
    .compressor = &compressor.base,
    .min_size = 1024, // 只压缩大于 1KB 的响应
};

try server.use(&compression_middleware.base);
```

---

## 监控与日志

### 结构化日志

```zig
const structured_log = @import("structured_log.zig");

const logger_config = structured_log.LogConfig{
    .output_format = .json,
    .log_level = .info,
    .include_request_id = true,
    .include_ip_address = true,
    .slow_request_threshold_ns = 100_000_000, // 100ms
};

const logger = structured_log.StructuredLogger.init(logger_config);

fn loggingHandler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) !void {
    const start_time = std.time.nanoTimestamp();
    try next(ctx);
    const duration = std.time.nanoTimestamp() - start_time;

    try logger.logRequest(ctx, duration);
}
```

### Prometheus 指标

```zig
const metrics_exporter = @import("metrics_exporter.zig");

var exporter = metrics_exporter.PrometheusExporter.init(allocator);
defer exporter.deinit();

// 注册指标
try exporter.registerCounter("http_requests_total", "Total HTTP requests");
try exporter.registerCounter("http_errors_total", "Total HTTP errors");
try exporter.registerHistogram("http_request_duration_ms", "HTTP request duration");

// 指标端点
try server.get("/metrics", metricsHandler);

fn metricsHandler(ctx: *Context) !void {
    try ctx.response.setHeader("Content-Type", "text/plain; version=0.0.4");
    try ctx.response.writeAll(exporter.export());
}

// 记录指标
exporter.incrementCounter("http_requests_total");
exporter.recordHistogram("http_request_duration_ms", 123.5);
```

---

## 工具函数

### 安全工具

```zig
const utils = @import("utils.zig");

// 生成请求 ID
const request_id = try utils.generateRequestId(allocator, io);
defer allocator.free(request_id);

// 生成短 ID
const short_id = try utils.generateShortId(allocator, io);
defer allocator.free(short_id);

// 路径安全检查
if (utils.isPathSafe("/var/www/file.txt", "/var/www")) {
    // 路径安全
}

// 文件名验证
if (utils.isFilenameSafe("file.txt")) {
    // 文件名安全
}

// 日志清理（移除敏感信息）
const safe_log = utils.sanitizeForLog("password=secret123");
// 输出: password=***

// HTTP 方法验证
if (utils.isValidMethod("GET")) {
    // 有效方法
}

// SQL 注入检测
if (utils.containsSqlInjection("SELECT * FROM users")) {
    // 检测到注入
}

// XSS 检测
if (utils.containsXss("<script>alert('xss')</script>")) {
    // 检测到 XSS
}

// HTML 转义
const escaped = utils.escapeHtml("<script>alert('hi')</script>");
// 输出: &lt;script&gt;alert('hi')&lt;/script&gt;
```

---

## 最佳实践

### 错误处理

```zig
fn handler(ctx: *Context) !void {
    // 使用 errdefer 确保资源清理
    const data = try ctx.getBody();
    defer ctx.allocator.free(data);

    // 多级错误处理
    const result = parseData(data) catch |err| {
        std.log.err("Parse error: {}", .{err});
        ctx.response.setStatus(.bad_request);
        try ctx.response.writeJSON(.{ .error = "Invalid data" });
        return;
    };

    try processData(result);
}
```

### 内存管理

```zig
fn handler(ctx: *Context) !void {
    // 总是释放分配的内存
    const data = try ctx.allocator.alloc(u8, 1024);
    defer ctx.allocator.free(data);

    // 使用 ArrayList 时记得 deinit
    var list = std.ArrayList(u8).init(ctx.allocator);
    defer list.deinit(ctx.allocator);

    // 使用 StringHashMap 时记得 deinit
    var map = std.StringHashMap([]const u8).init(ctx.allocator);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            ctx.allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }
}
```

### 性能优化

```zig
// 使用缓冲区减少分配
var buffer: [4096]u8 = undefined;
const data = try reader.readAll(&buffer);

// 复用 Response
ctx.response.reset(); // 重置以重用

// 批量操作
var batch = std.ArrayList(u8).init(allocator);
defer batch.deinit(allocator);

for (0..100) |i| {
    try batch.writer().print("item_{d}\n", .{i});
}
try ctx.response.writeAll(batch.items);
```

---

## API 版本

当前版本: **0.16.0**

Zig 版本要求: **0.15.2+**

---

## 许可证

MIT License
