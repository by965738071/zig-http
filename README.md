# Zig HTTP Server

一个功能完整的 Zig HTTP 服务器实现，支持多种现代 Web 功能。

## 项目结构

```
zig-http/
├── src/
│   ├── main.zig              # 主入口文件
│   ├── core/                 # 核心库
│   │   └── lib.zig          # 公共接口导出
│   ├── handlers/            # 路由处理器
│   │   ├── lib.zig          # 处理器公共接口
│   │   ├── home.zig         # 主页处理器
│   │   ├── health.zig       # 健康检查
│   │   ├── api.zig          # API 处理器
│   │   ├── upload.zig       # 文件上传
│   │   ├── session.zig      # 会话管理
│   │   ├── streaming.zig    # 流媒体
│   │   ├── websocket.zig    # WebSocket
│   │   └── static.zig       # 静态文件
│   ├── middleware/          # 中间件
│   │   ├── auth.zig
│   │   ├── cors.zig
│   │   ├── csrf.zig
│   │   ├── xss.zig
│   │   ├── logging.zig
│   │   └── ...
│   ├── utils/               # 工具模块
│   │   └── lib.zig
│   ├── http_server.zig      # HTTP 服务器核心
│   ├── router.zig           # 路由器
│   ├── context.zig          # 请求上下文
│   ├── response.zig         # 响应处理
│   └── ...
├── public/                  # 静态文件目录
├── examples/                # 示例代码
└── docs/                    # 文档

```

## 核心功能

- ✅ HTTP/1.1 服务器
- ✅ 路由系统（支持动态路由）
- ✅ 中间件系统
- ✅ WebSocket 支持
- ✅ 静态文件服务
- ✅ 请求体解析（JSON, Form, Multipart）
- ✅ 会话管理
- ✅ Cookie 管理
- ✅ 模板引擎
- ✅ Gzip 压缩
- ✅ 速率限制
- ✅ 指标收集
- ✅ Prometheus 导出
- ✅ 结构化日志
- ✅ 上传进度追踪
- ✅ 拦截器
- ✅ 安全特性（XSS, CSRF, Auth）

## 快速开始

```bash
# 构建项目
zig build

# 运行服务器
zig build run

# 或者直接运行可执行文件
./zig-out/bin/zig_http
```

服务器将在 `http://127.0.0.1:8080` 启动。

## 模块说明

### 核心模块 (core/)

核心库提供 HTTP 服务器的基础构建块：

- **HTTPServer** - 主服务器实现
- **Router** - 路由系统
- **Context** - 请求/响应上下文
- **Response** - 响应处理
- **Middleware** - 中间件接口

### 处理器模块 (handlers/)

所有路由处理器按功能分类：

- **home.zig** - 主页处理器
- **health.zig** - 健康检查端点
- **api.zig** - API 处理器（数据、模板、压缩等）
- **upload.zig** - 文件上传和进度追踪
- **session.zig** - 会话管理
- **streaming.zig** - SSE 和 Chunked 流
- **websocket.zig** - WebSocket 处理
- **static.zig** - 静态文件服务

### 中间件模块 (middleware/)

提供各种中间件：

- **auth.zig** - 身份验证
- **cors.zig** - 跨域资源共享
- **csrf.zig** - CSRF 保护
- **xss.zig** - XSS 过滤
- **logging.zig** - 请求日志

## API 端点

### 基础端点

- `GET /` - 主页
- `GET /api/health` - 健康检查

### API 端点

- `GET /api/data` - 获取服务器信息
- `POST /api/submit` - 提交数据（支持 JSON 和 Form）
- `POST /api/upload` - 文件上传
- `GET /api/session` - 会话管理
- `GET /api/cookie` - Cookie 操作
- `GET /api/template` - 模板渲染
- `GET /api/compress` - 压缩测试
- `GET /api/metrics` - 服务器指标
- `GET /api/client` - HTTP 客户端功能
- `GET /api/secure` - 受保护端点
- `GET /api/benchmark` - 性能测试
- `GET /api/tests` - 运行测试用例
- `GET /api/upload/progress` - 上传进度
- `GET /api/log/demo` - 结构化日志演示
- `GET /api/stream/sse` - Server-Sent Events
- `GET /api/stream/chunk` - Chunked 传输
- `GET /metrics` - Prometheus 指标

### WebSocket

- `WS /ws/echo` - WebSocket 回显服务器
- `GET /ws` - WebSocket 测试页面

### 静态文件

- `GET /static/*` - 静态文件服务

## 配置

服务器配置位于 `main.zig` 中的 `ServerConfig` 结构体。

## 开发

### 添加新的处理器

1. 在 `src/handlers/` 中创建新的 `.zig` 文件
2. 实现处理器函数：`pub fn handleYourEndpoint(ctx: *Context) !void`
3. 在 `src/handlers/lib.zig` 中导出
4. 在 `main.zig` 的 `setupRoutes` 函数中注册路由

### 添加新的中间件

1. 在 `src/middleware/` 中创建新的 `.zig` 文件
2. 实现 `Middleware` 接口
3. 在 `main.zig` 的 `setupMiddlewares` 函数中添加中间件

## 贡献

欢迎贡献代码、报告问题或提出改进建议！

## 许可证

MIT License
