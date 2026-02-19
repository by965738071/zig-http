# Zig HTTP Server - 快速开始指南

## 环境要求

- **Zig**: 0.16.0-dev 或兼容版本
- **操作系统**: macOS (ARM64/Intel), Linux, Windows
- **内存**: 最少 512MB

## 安装和编译

### 1. 克隆项目
```bash
git clone https://github.com/by965738071/zig-http.git
cd zig-http
```

### 2. 编译项目
```bash
# Debug 模式
zig build

# Release 模式（优化）
zig build -Doptimize=ReleaseFast
```

### 3. 运行服务器
```bash
# 方式一：直接运行编译后的二进制
./zig-out/bin/zig_http

# 方式二：使用 zig build run
zig build run
```

服务器将启动在 `http://127.0.0.1:8080`

## 首次运行

启动成功后，您应该看到类似的输出：

```
========================================
🚀 Zig HTTP Server starting on 127.0.0.1:8080
========================================
Features:
  ✅ HTTP Server & Router
  ✅ WebSocket: /ws/echo
  ✅ Static Files: /static/*
  ✅ Body Parser: JSON & Form
  ...
========================================
Press Ctrl+C to stop the server
========================================
```

## 测试端点

### 1. 访问主页
```bash
curl http://127.0.0.1:8080/
```

或在浏览器中打开：http://127.0.0.1:8080/

### 2. 获取 JSON 数据
```bash
curl http://127.0.0.1:8080/api/data
```

### 3. 发送 JSON 数据
```bash
curl -X POST http://127.0.0.1:8080/api/submit \
  -H "Content-Type: application/json" \
  -d '{"name":"John","message":"Hello"}'
```

### 4. 发送表单数据
```bash
curl -X POST http://127.0.0.1:8080/api/submit \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=John&message=Hello"
```

### 5. 上传文件
```bash
curl -X POST http://127.0.0.1:8080/api/upload \
  -F "file=@/path/to/file.txt"
```

### 6. WebSocket 连接
访问 http://127.0.0.1:8080/ws 打开 WebSocket 测试页面

### 7. 健康检查
```bash
curl http://127.0.0.1:8080/api/health
```

### 8. 获取指标
```bash
curl http://127.0.0.1:8080/api/metrics
```

## 项目结构

```
zig-http/
├── src/
│   ├── main.zig                 # 入口点和路由定义
│   ├── http_server.zig          # 核心 HTTP 服务器
│   ├── router.zig               # Trie 路由实现
│   ├── context.zig              # 请求/响应上下文
│   ├── response.zig             # HTTP 响应构建
│   ├── middleware.zig           # 中间件框架
│   ├── middleware/
│   │   ├── auth.zig             # 认证中间件
│   │   ├── cors.zig             # CORS 支持
│   │   ├── csrf.zig             # CSRF 保护
│   │   ├── xss.zig              # XSS 保护
│   │   └── logging.zig          # 日志记录
│   ├── websocket.zig            # WebSocket 支持
│   ├── static_server.zig        # 静态文件服务
│   ├── body_parser.zig          # 请求体解析
│   ├── multipart.zig            # Multipart 处理
│   ├── session.zig              # 会话管理
│   ├── cookie.zig               # Cookie 支持
│   ├── template.zig             # 模板引擎
│   ├── compression.zig          # 压缩支持
│   ├── rate_limiter.zig         # 速率限制
│   ├── monitoring.zig           # 性能监控
│   └── types.zig                # 类型定义
├── build.zig                    # 构建配置
├── build.zig.zon               # 依赖版本锁定
├── README.md                    # 项目说明
└── IMPROVEMENTS.md             # 改进总结
```

## 定制和扩展

### 添加新路由

编辑 `src/main.zig` 的 `main()` 函数：

```zig
// 添加新的 GET 路由
try route.addRoute(http.Method.GET, "/api/hello", handleHello);

// 添加新的 POST 路由
try route.addRoute(http.Method.POST, "/api/users", handleCreateUser);
```

### 实现新的 Handler

```zig
fn handleHello(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.writeJSON(.{
        .message = "Hello, World!",
        .timestamp = std.time.timestamp(),
    });
}
```

### 添加中间件

```zig
// 创建自定义中间件
var custom_middleware = try MyMiddleware.init(allocator);
defer custom_middleware.deinit();

// 注册到服务器
server.use(&custom_middleware.middleware);
```

## 配置选项

编辑 `src/main.zig` 中的服务器配置：

```zig
var server = try httpServer.init(allocator, .{
    .port = 8080,              // 监听端口
    .host = "127.0.0.1",       // 监听地址
    .max_connections = 1000,   // 最大连接数
    .request_timeout = 30_000, // 请求超时（毫秒）
});
```

## 性能调优

### 启用 Release 优化
```bash
zig build -Doptimize=ReleaseFast
```

### 增加缓冲区大小
编辑 `src/types.zig` 中的 Config：

```zig
pub const Config = struct {
    ...
    read_buffer_size: usize = 65536,    // 增加到 64KB
    write_buffer_size: usize = 65536,   // 增加到 64KB
};
```

### 负载测试

使用 `oha` 或 `wrk` 进行压力测试：

```bash
# 使用 oha
oha -n 10000 -c 100 -z 30s http://127.0.0.1:8080/api/data

# 使用 wrk
wrk -t4 -c100 -d30s http://127.0.0.1:8080/api/data
```

## 常见问题

### Q: 如何处理 POST 请求的 JSON 体？
A: 使用 `ctx.getBody()` 获取原始体数据，或使用 `ctx.getJSON()` 获取解析后的 JSON。

```zig
fn myHandler(ctx: *Context) !void {
    if (ctx.getJSON()) |json| {
        // 处理 JSON 数据
    }
}
```

### Q: 如何添加自定义响应头？
A: 使用 `ctx.response.setHeader()`：

```zig
fn myHandler(ctx: *Context) !void {
    try ctx.response.setHeader("X-Custom-Header", "value");
    try ctx.response.write("data");
}
```

### Q: 如何获取查询参数？
A: 使用 `ctx.getQuery()`：

```zig
fn myHandler(ctx: *Context) !void {
    if (ctx.getQuery("name")) |name| {
        try ctx.response.write(name);
    }
}
```

### Q: 如何获取路径参数？
A: 在路由中使用 `:` 前缀，然后用 `ctx.getParam()`：

```zig
// 定义路由
try route.addRoute(http.Method.GET, "/users/:id", handleGetUser);

// 处理器
fn handleGetUser(ctx: *Context) !void {
    if (ctx.getParam("id")) |id| {
        try ctx.response.write(id);
    }
}
```

### Q: 如何处理 WebSocket？
A: 在 `main()` 中注册 WebSocket 处理器：

```zig
var ws_server = WebSocketServer.init(allocator);
try ws_server.handle("/ws/custom", myWebSocketHandler);
server.setWebSocketServer(&ws_server);

fn myWebSocketHandler(ws: *WebSocketContext) !void {
    try ws.sendText("Welcome!");
    while (true) {
        var msg = try ws.receive();
        defer ws.freeMessage(&msg);
        try ws.sendText(msg.data);
    }
}
```

## 调试技巧

### 启用详细日志
在编译前，修改 `std.log` 的日志级别为 `debug`

### 检查请求内容
添加日志中间件查看所有请求：

```bash
curl -v http://127.0.0.1:8080/api/data
```

### 监听特定端口
更改 `main.zig` 中的监听地址和端口

## 下一步

1. **阅读 README.md** - 了解项目架构和高级功能
2. **浏览 IMPROVEMENTS.md** - 了解最近的改进和优化
3. **查看示例代码** - 在 `src/main.zig` 中查看完整的 handler 实现
4. **运行测试** - 使用 `zig test src/body_parser.zig` 运行单元测试

## 获取帮助

- 查看 README.md 的 API 参考部分
- 检查源代码中的注释和文档
- 查看 IMPROVEMENTS.md 中的已知限制

## 许可证

MIT License
