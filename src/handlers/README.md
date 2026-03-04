# Handlers Module

处理器模块包含所有的路由处理器，按功能分类。

## 处理器列表

### home.zig
- **handleHome()** - 主页处理器，显示服务器演示界面

### health.zig
- **handleHealth()** - 健康检查端点，返回服务器状态

### api.zig
API 相关处理器：
- **handleData()** - 返回服务器信息和功能列表
- **handleSubmit()** - 处理 POST 数据提交（JSON/Form）
- **handleCookie()** - Cookie 操作演示
- **handleTemplate()** - 模板渲染演示
- **handleCompress()** - Gzip 压缩测试
- **handleMetrics()** - 服务器指标
- **handleClient()** - HTTP 客户端功能
- **handleSecure()** - 受保护端点演示
- **handleBenchmark()** - 性能测试
- **handleTests()** - 运行测试用例
- **handleStructuredLog()** - 结构化日志演示
- **handlePrometheus()** - Prometheus 指标

### upload.zig
文件上传相关：
- **handleUpload()** - 处理 multipart 文件上传
- **handleUploadProgress()** - 查询上传进度

### session.zig
会话管理：
- **handleSession()** - 会话管理演示

### streaming.zig
流媒体处理：
- **handleSSE()** - Server-Sent Events 演示
- **handleChunked()** - Chunked 传输演示

### websocket.zig
WebSocket 相关：
- **echoHandler()** - WebSocket 回显处理器
- **testPageHandler()** - WebSocket 测试页面

### static.zig
静态文件：
- **handleStatic()** - 静态文件服务处理器

## 处理器签名

所有处理器遵循相同的签名：

```zig
pub fn handleYourEndpoint(ctx: *Context) !void
```

### Context 可用方法

```zig
// 访问请求数据
const body = ctx.getBody();
const header = ctx.getHeader("Content-Type");
const query = ctx.getQuery("param");

// 设置响应
ctx.response.setStatus(http.Status.ok);
try ctx.response.setHeader("Content-Type", "application/json");
try ctx.response.writeJSON(.{ .message = "Hello" });

// Cookie 操作
try ctx.setCookie(.{ .name = "key", .value = "value" });
const jar = ctx.getCookieJar();

// 访问服务器组件
if (ctx.server.metrics) |metrics| {
    const count = metrics.total_requests;
}
```

## 添加新处理器

1. 创建新的 `.zig` 文件（例如 `src/handlers/your_handler.zig`）
2. 实现处理器函数
3. 在 `src/handlers/lib.zig` 中导出
4. 在 `main.zig` 中注册路由

### 示例

```zig
// src/handlers/your_handler.zig
const std = @import("std");
const http = std.http;
const Context = @import("../context.zig").Context;

pub fn handleCustom(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .message = "Custom handler",
        .timestamp = std.time.timestamp(),
    });
}
```

```zig
// src/handlers/lib.zig
pub const custom = @import("your_handler.zig").handleCustom;
```

```zig
// main.zig
try route.addRoute(http.Method.GET, "/api/custom", handlers.custom);
```

## 处理器分类

### 基础处理器
- 主页
- 健康检查

### API 处理器
- 数据查询
- 数据提交
- 文件操作

### 功能处理器
- 会话管理
- Cookie 操作
- 模板渲染
- 压缩
- 指标

### 流媒体处理器
- SSE
- Chunked 传输

### WebSocket 处理器
- WebSocket 连接处理
- 测试页面

### 静态文件处理器
- 静态文件服务
