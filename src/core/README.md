# Core Module

核心模块提供 HTTP 服务器的基础构建块。

## 导出的类型

### HTTPServer
主 HTTP 服务器实现，负责：
- 接受和处理连接
- 请求路由
- 中间件执行
- 响应发送

### Router
路由系统，支持：
- 静态路由
- 动态路由（参数提取）
- 路径匹配
- 中间件注册

### Context
请求/响应上下文，提供：
- 请求数据访问
- 响应构建
- 会话管理
- Cookie 操作

### Response
响应处理，提供：
- 状态码设置
- 头部设置
- 内容写入
- JSON 序列化
- 流式响应

### Middleware
中间件接口，允许：
- 请求预处理
- 响应后处理
- 错误处理
- 流程控制

## 使用示例

```zig
const core = @import("core/lib.zig");

// 创建服务器
var server = try core.Server.init(allocator, .{
    .port = 8080,
    .host = "0.0.0.0",
});

// 创建路由器
var router = try core.Router.init(allocator);
try router.addRoute(http.Method.GET, "/", handler);

// 设置路由器
server.setRouter(router);

// 启动服务器
try server.start(io);
```

## 架构

核心模块遵循以下原则：

1. **单一职责** - 每个组件负责单一功能
2. **可组合性** - 组件可以独立使用或组合使用
3. **可扩展性** - 通过中间件和拦截器扩展功能
4. **性能优先** - 最小化内存分配和复制
