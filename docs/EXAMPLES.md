# Zig-HTTP 使用示例文档

## 目录

- [基础示例](#基础示例)
- [中间件示例](#中间件示例)
- [会话管理示例](#会话管理示例)
- [WebSocket 示例](#websocket-示例)
- [文件上传示例](#文件上传示例)
- [静态文件服务示例](#静态文件服务示例)
- [认证授权示例](#认证授权示例)
- [数据库集成示例](#数据库集成示例)
- [完整应用示例](#完整应用示例)

---

## 基础示例

### 1. 简单的 Hello World 服务器

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
    });
    defer server.deinit();

    try server.get("/", indexHandler);
    try server.start();
}

fn indexHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.write("Hello, World!");
}
```

**运行**:
```bash
zig build run
curl http://127.0.0.1:8080/
# 输出: Hello, World!
```

### 2. RESTful API

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = HTTPServer.Context;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

var users = std.ArrayList(User).init(std.heap.page_allocator);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    // 注册路由
    try server.get("/api/users", listUsers);
    try server.get("/api/users/:id", getUser);
    try server.post("/api/users", createUser);
    try server.put("/api/users/:id", updateUser);
    try server.delete("/api/users/:id", deleteUser);

    try server.start();
}

// GET /api/users - 获取所有用户
fn listUsers(ctx: *Context) !void {
    try ctx.response.writeJSON(.{
        .users = users.items,
        .count = users.items.len,
    });
}

// GET /api/users/:id - 获取单个用户
fn getUser(ctx: *Context) !void {
    const id_str = ctx.params.get("id") orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.response.writeJSON(.{ .error = "Missing user id" });
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.response.setStatus(.bad_request);
        try ctx.response.writeJSON(.{ .error = "Invalid user id" });
        return;
    };

    for (users.items) |user| {
        if (user.id == id) {
            try ctx.response.writeJSON(user);
            return;
        }
    }

    ctx.response.setStatus(.not_found);
    try ctx.response.writeJSON(.{ .error = "User not found" });
}

// POST /api/users - 创建用户
fn createUser(ctx: *Context) !void {
    const UserData = struct { name: []const u8, email: []const u8 };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const data = std.json.parseFromSlice(UserData, ctx.allocator, body, .{}) catch |err| {
        ctx.response.setStatus(.bad_request);
        try ctx.response.writeJSON(.{ .error = "Invalid JSON", .details = @errorName(err) });
        return;
    };
    defer data.deinit();

    const new_id = @as(u32, @intCast(users.items.len)) + 1;
    const new_user = User{
        .id = new_id,
        .name = data.value.name,
        .email = data.value.email,
    };
    try users.append(new_user);

    ctx.response.setStatus(.created);
    try ctx.response.writeJSON(.{
        .success = true,
        .user = new_user,
    });
}

// PUT /api/users/:id - 更新用户
fn updateUser(ctx: *Context) !void {
    const id_str = ctx.params.get("id") orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const UserData = struct { name: ?[]const u8, email: ?[]const u8 };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const data = std.json.parseFromSlice(UserData, ctx.allocator, body, .{}) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };
    defer data.deinit();

    for (users.items) |*user| {
        if (user.id == id) {
            if (data.value.name) |name| user.name = name;
            if (data.value.email) |email| user.email = email;

            try ctx.response.writeJSON(.{
                .success = true,
                .user = user.*,
            });
            return;
        }
    }

    ctx.response.setStatus(.not_found);
}

// DELETE /api/users/:id - 删除用户
fn deleteUser(ctx: *Context) !void {
    const id_str = ctx.params.get("id") orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };

    for (users.items, 0..) |user, index| {
        if (user.id == id) {
            _ = users.orderedRemove(index);
            try ctx.response.writeJSON(.{
                .success = true,
                .message = "User deleted",
            });
            return;
        }
    }

    ctx.response.setStatus(.not_found);
}
```

**测试**:
```bash
# 获取所有用户
curl http://127.0.0.1:8080/api/users

# 创建用户
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","email":"alice@example.com"}'

# 获取单个用户
curl http://127.0.0.1:8080/api/users/1

# 更新用户
curl -X PUT http://127.0.0.1:8080/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice Updated"}'

# 删除用户
curl -X DELETE http://127.0.0.1:8080/api/users/1
```

### 3. JSON API 完整示例

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;

const Todo = struct {
    id: u32,
    title: []const u8,
    completed: bool,
    created_at: i64,
};

var todos = std.ArrayList(Todo).init(std.heap.page_allocator);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化一些示例数据
    try todos.append(Todo{
        .id = 1,
        .title = "Learn Zig",
        .completed = false,
        .created_at = std.time.timestamp(),
    });

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    try server.get("/api/todos", listTodos);
    try server.post("/api/todos", createTodo);
    try server.put("/api/todos/:id", updateTodo);
    try server.delete("/api/todos/:id", deleteTodo);

    try server.start();
}

fn listTodos(ctx: *HTTPServer.Context) !void {
    try ctx.response.writeJSON(.{
        .todos = todos.items,
        .total = todos.items.len,
    });
}

fn createTodo(ctx: *HTTPServer.Context) !void {
    const TodoInput = struct { title: []const u8 };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const input = std.json.parseFromSlice(TodoInput, ctx.allocator, body, .{}) catch {
        ctx.response.setStatus(.bad_request);
        try ctx.response.writeJSON(.{ .error = "Invalid JSON" });
        return;
    };
    defer input.deinit();

    const new_todo = Todo{
        .id = @as(u32, @intCast(todos.items.len)) + 1,
        .title = input.value.title,
        .completed = false,
        .created_at = std.time.timestamp(),
    };
    try todos.append(new_todo);

    ctx.response.setStatus(.created);
    try ctx.response.writeJSON(.{ .todo = new_todo });
}

fn updateTodo(ctx: *HTTPServer.Context) !void {
    const id_str = ctx.params.get("id") orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.response.writeJSON(.{ .error = "Missing id" });
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const TodoUpdate = struct { title: ?[]const u8, completed: ?bool };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const update = std.json.parseFromSlice(TodoUpdate, ctx.allocator, body, .{}) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };
    defer update.deinit();

    for (todos.items) |*todo| {
        if (todo.id == id) {
            if (update.value.title) |title| todo.title = title;
            if (update.value.completed) |completed| todo.completed = completed;

            try ctx.response.writeJSON(.{ .todo = todo.* });
            return;
        }
    }

    ctx.response.setStatus(.not_found);
}

fn deleteTodo(ctx: *HTTPServer.Context) !void {
    const id_str = ctx.params.get("id") orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };

    for (todos.items, 0..) |todo, index| {
        if (todo.id == id) {
            _ = todos.orderedRemove(index);
            try ctx.response.writeJSON(.{ .message = "Todo deleted" });
            return;
        }
    }

    ctx.response.setStatus(.not_found);
}
```

---

## 中间件示例

### 1. 日志中间件

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Middleware = @import("middleware.zig").Middleware;

const LoggingMiddleware = struct {
    base: Middleware,

    fn init() LoggingMiddleware {
        return .{
            .base = .{
                .handler = handle,
                .order = 0,
            },
        };
    }

    fn handle(ctx: *HTTPServer.Context, next: *const fn (ctx: *HTTPServer.Context) anyerror!void) !void {
        const start_time = std.time.nanoTimestamp();

        std.log.info("{s} {s}", .{ ctx.method, ctx.path });

        try next(ctx);

        const duration_ms = (std.time.nanoTimestamp() - start_time) / 1_000_000;
        std.log.info("{s} {s} - {d}ms - {d}", .{
            ctx.method,
            ctx.path,
            duration_ms,
            @intFromEnum(ctx.response.status),
        });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    // 注册日志中间件
    const logging = LoggingMiddleware.init();
    try server.use(&logging.base);

    try server.get("/", indexHandler);
    try server.start();
}

fn indexHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.write("Hello, World!");
}
```

### 2. 认证中间件

```zig
const AuthMiddleware = struct {
    base: Middleware,
    secret_token: []const u8,

    fn init(token: []const u8) AuthMiddleware {
        return .{
            .base = .{
                .handler = handle,
                .order = 10,
            },
            .secret_token = token,
        };
    }

    fn handle(ctx: *HTTPServer.Context, next: *const fn (ctx: *HTTPServer.Context) anyerror!void) !void {
        const auth_header = ctx.getHeader("Authorization") orelse {
            ctx.response.setStatus(.unauthorized);
            try ctx.response.writeJSON(.{
                .error = "Missing Authorization header",
            });
            return;
        };

        if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
            ctx.response.setStatus(.unauthorized);
            try ctx.response.writeJSON(.{
                .error = "Invalid Authorization format. Use: Bearer <token>",
            });
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
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    const auth = AuthMiddleware.init("secret-token");

    try server.get("/", indexHandler);
    try server.get("/api/public", publicHandler);
    try server.get("/api/protected", protectedHandler, &.{ &auth.base });

    try server.start();
}

fn publicHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.writeJSON(.{ .message = "This is a public endpoint" });
}

fn protectedHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.writeJSON(.{ .message = "This is a protected endpoint" });
}
```

**测试**:
```bash
# 公开端点
curl http://127.0.0.1:8080/api/public
# {"message":"This is a public endpoint"}

# 无保护的端点
curl http://127.0.0.1:8080/api/protected
# 401 Unauthorized

# 带有效 token
curl http://127.0.0.1:8080/api/protected \
  -H "Authorization: Bearer secret-token"
# {"message":"This is a protected endpoint"}
```

### 3. CORS 中间件

```zig
const CORSMiddleware = struct {
    base: Middleware,
    allowed_origins: []const []const u8,

    fn init(origins: []const []const u8) CORSMiddleware {
        return .{
            .base = .{
                .handler = handle,
                .order = 1,
            },
            .allowed_origins = origins,
        };
    }

    fn handle(ctx: *HTTPServer.Context, next: *const fn (ctx: *HTTPServer.Context) anyerror!void) !void {
        // 设置 CORS 头部
        try ctx.response.setHeader("Access-Control-Allow-Origin", "*");
        try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

        // 处理预检请求
        if (std.mem.eql(u8, ctx.method, "OPTIONS")) {
            ctx.response.setStatus(.ok);
            return;
        }

        try next(ctx);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    const cors = CORSMiddleware.init(&.{ "*" });
    try server.use(&cors.base);

    try server.get("/api/data", dataHandler);
    try server.start();
}

fn dataHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.writeJSON(.{ .data = "sample data" });
}
```

### 4. 速率限制中间件

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;

const RateLimitMiddleware = struct {
    base: Middleware,
    limiter: *RateLimiter,
    max_requests: usize,
    window_seconds: u64,

    fn init(limiter: *RateLimiter, max: usize, window: u64) RateLimitMiddleware {
        return .{
            .base = .{
                .handler = handle,
                .order = 5,
            },
            .limiter = limiter,
            .max_requests = max,
            .window_seconds = window,
        };
    }

    fn handle(ctx: *HTTPServer.Context, next: *const fn (ctx: *HTTPServer.Context) anyerror!void) !void {
        const ip = ctx.ip_address orelse "unknown";

        if (!self.limiter.allow(ip, self.max_requests, self.window_seconds)) {
            ctx.response.setStatus(.too_many_requests);
            try ctx.response.setHeader("Retry-After", "60");
            try ctx.response.writeJSON(.{
                .error = "Too many requests",
                .limit = self.max_requests,
                .window = self.window_seconds,
            });
            return;
        }

        try next(ctx);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    var limiter = try RateLimiter.init(allocator, 60); // 60 秒窗口
    defer limiter.deinit();

    const rate_limit = RateLimitMiddleware.init(&limiter, 100, 60);
    try server.use(&rate_limit.base);

    try server.get("/api/data", dataHandler);
    try server.start();
}
```

---

## 会话管理示例

### 1. 基本会话管理

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const SessionManager = @import("session.zig").SessionManager;
const MemorySessionStore = @import("session.zig").MemorySessionStore;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    // 初始化会话管理器
    var session_manager = SessionManager.init(allocator);
    defer session_manager.deinit();

    // 设置内存存储，会话 1 小时过期
    var store = MemorySessionStore.init(allocator, 3600);
    defer store.deinit();
    session_manager.setSessionStore(&store.base);

    // 设置到服务器
    server.setSessionManager(&session_manager);

    // 启动清理任务
    try session_manager.startCleanupTask(300);
    defer session_manager.stopCleanupTask();

    try server.get("/login", loginHandler);
    try server.get("/dashboard", dashboardHandler);
    try server.get("/logout", logoutHandler);

    try server.start();
}

fn loginHandler(ctx: *HTTPServer.Context) !void {
    // 创建新会话
    const session = try ctx.getSession();

    // 设置会话数据
    try session.set("user_id", "123");
    try session.set("username", "alice");
    try session.set("role", "admin");

    try ctx.response.writeJSON(.{
        .success = true,
        .message = "Logged in successfully",
    });
}

fn dashboardHandler(ctx: *HTTPServer.Context) !void {
    // 获取会话
    const session = try ctx.getSession();

    const user_id = session.get("user_id") orelse {
        ctx.response.setStatus(.unauthorized);
        try ctx.response.writeJSON(.{ .error = "Not logged in" });
        return;
    };

    try ctx.response.writeJSON(.{
        .user_id = user_id,
        .username = session.get("username"),
        .role = session.get("role"),
    });
}

fn logoutHandler(ctx: *HTTPServer.Context) !void {
    // 销毁会话
    try ctx.destroySession();

    try ctx.response.writeJSON(.{
        .success = true,
        .message = "Logged out successfully",
    });
}
```

### 2. 文件会话存储

```zig
const FileSessionStore = @import("session.zig").FileSessionStore;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    var session_manager = SessionManager.init(allocator);
    defer session_manager.deinit();

    // 使用文件存储，会话保存在 ./sessions 目录
    var store = FileSessionStore.init(allocator, "./sessions", 3600);
    defer store.deinit();
    session_manager.setSessionStore(&store.base);

    server.setSessionManager(&session_manager);

    try server.get("/", indexHandler);
    try server.start();
}

fn indexHandler(ctx: *HTTPServer.Context) !void {
    const session = try ctx.getSession();

    const visits = session.get("visits") orelse "0";
    const count = std.fmt.parseInt(u32, visits, 10) catch 0;

    try session.set("visits", try std.fmt.allocPrint(ctx.allocator, "{d}", .{count + 1}));

    try ctx.response.writeJSON(.{
        .visits = count + 1,
    });
}
```

---

## WebSocket 示例

### 1. 简单的 Echo 服务器

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const WebSocketServer = @import("websocket.zig").WebSocketServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    var ws_server = WebSocketServer.init(allocator);
    defer ws_server.deinit();

    try ws_server.handle("/ws/echo", echoHandler);

    try server.get("/", indexHandler);
    try server.start();
}

fn indexHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.write(@embedFile("websocket_test.html"));
}

fn echoHandler(conn: *WebSocketServer.Connection) !void {
    while (conn.state == .connected) {
        const message = try conn.readMessage() orelse continue;
        defer message.deinit();

        switch (message.type) {
            .text => {
                std.log.info("Received text: {s}", .{message.data});
                try conn.sendMessage(.text, message.data);
            },
            .binary => {
                std.log.info("Received binary data: {d} bytes", .{message.data.len});
                try conn.sendMessage(.binary, message.data);
            },
            .ping => {
                try conn.sendPong(message.data);
            },
            .close => {
                try conn.sendClose(.normal_closure, "Goodbye!");
                return;
            },
        }
    }
}
```

### 2. 聊天室服务器

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const WebSocketServer = @import("websocket.zig").WebSocketServer;

var chat_clients = std.ArrayList(*WebSocketServer.Connection).init(std.heap.page_allocator);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    var ws_server = WebSocketServer.init(allocator);
    defer ws_server.deinit();

    try ws_server.handle("/ws/chat", chatHandler);

    try server.start();
}

fn chatHandler(conn: *WebSocketServer.Connection) !void {
    // 加入聊天室
    try chat_clients.append(conn);
    defer {
        // 离开聊天室
        const index = std.mem.indexOfScalar(*WebSocketServer.Connection, chat_clients.items, conn) orelse 0;
        _ = chat_clients.orderedRemove(index);
    }

    // 广播欢迎消息
    try broadcast(conn, "A new user has joined!");

    while (conn.state == .connected) {
        const message = try conn.readMessage() orelse continue;
        defer message.deinit();

        if (message.type == .text) {
            // 广播消息给所有客户端
            try broadcast(conn, message.data);
        }
    }
}

fn broadcast(sender: *WebSocketServer.Connection, message: []const u8) !void {
    for (chat_clients.items) |client| {
        if (client != sender) {
            try client.sendMessage(.text, message);
        }
    }
}
```

### 3. 实时通知推送

```zig
const std = @import("std");
const WebSocketServer = @import("websocket.zig").WebSocketServer;

var notification_subscribers = std.ArrayList(*WebSocketServer.Connection).init(std.heap.page_allocator);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    var ws_server = WebSocketServer.init(allocator);
    defer ws_server.deinit();

    try ws_server.handle("/ws/notifications", notificationHandler);

    try server.post("/api/notify", sendNotification);

    try server.start();
}

fn notificationHandler(conn: *WebSocketServer.Connection) !void {
    try notification_subscribers.append(conn);
    defer {
        const index = std.mem.indexOfScalar(*WebSocketServer.Connection, notification_subscribers.items, conn) orelse 0;
        _ = notification_subscribers.orderedRemove(index);
    }

    while (conn.state == .connected) {
        _ = try conn.readMessage() orelse continue;
    }
}

fn sendNotification(ctx: *HTTPServer.Context) !void {
    const Notification = struct { message: []const u8, type: []const u8 };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const notification = std.json.parseFromSlice(Notification, ctx.allocator, body, .{}) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };
    defer notification.deinit();

    // 构造 JSON 消息
    const json = try std.json.stringifyAlloc(ctx.allocator, notification.value, .{});
    defer ctx.allocator.free(json);

    // 广播给所有订阅者
    for (notification_subscribers.items) |client| {
        try client.sendMessage(.text, json);
    }

    try ctx.response.writeJSON(.{
        .success = true,
        .subscribers = notification_subscribers.items.len,
    });
}
```

---

## 文件上传示例

### 1. 单文件上传

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    try server.post("/upload", uploadHandler);
    try server.get("/", uploadFormHandler);

    try server.start();
}

fn uploadFormHandler(ctx: *HTTPServer.Context) !void {
    const html = @embedFile("upload_form.html");
    try ctx.response.setHeader("Content-Type", "text/html");
    try ctx.response.write(html);
}

fn uploadHandler(ctx: *HTTPServer.Context) !void {
    const multipart_form = try ctx.getMultipartForm();
    defer multipart_form.deinit(ctx.allocator);

    const files = multipart_form.getFiles("file");
    if (files.len == 0) {
        ctx.response.setStatus(.bad_request);
        try ctx.response.writeJSON(.{ .error = "No file uploaded" });
        return;
    }

    for (files) |file| {
        // 验证文件类型
        if (!isValidImageType(file.content_type)) {
            ctx.response.setStatus(.bad_request);
            try ctx.response.writeJSON(.{ .error = "Invalid file type" });
            return;
        }

        // 验证文件大小（最大 10MB）
        if (file.data.len > 10 * 1024 * 1024) {
            ctx.response.setStatus(.bad_request);
            try ctx.response.writeJSON(.{ .error = "File too large" });
            return;
        }

        // 生成安全的文件名
        const safe_filename = sanitizeFilename(file.filename);

        // 保存文件
        const upload_dir = "./uploads";
        try std.fs.cwd().makePath(upload_dir);

        const file_path = try std.fs.path.join(ctx.allocator, &.{ upload_dir, safe_filename });
        defer ctx.allocator.free(file_path);

        const out_file = try std.fs.cwd().createFile(file_path, .{});
        defer out_file.close();

        try out_file.writeAll(file.data);
    }

    try ctx.response.writeJSON(.{
        .success = true,
        .message = "File uploaded successfully",
        .files = files.len,
    });
}

fn isValidImageType(content_type: []const u8) bool {
    const allowed = &[_][]const u8{
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
    };

    for (allowed) |type_| {
        if (std.mem.eql(u8, content_type, type_)) {
            return true;
        }
    }
    return false;
}

fn sanitizeFilename(filename: []const u8) []const u8 {
    // 简化：只保留字母、数字、点、下划线和连字符
    // 实际实现应该更严格
    return filename;
}
```

**HTML 表单** (upload_form.html):
```html
<!DOCTYPE html>
<html>
<head><title>File Upload</title></head>
<body>
    <h1>Upload File</h1>
    <form action="/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="file" required>
        <button type="submit">Upload</button>
    </form>
</body>
</html>
```

### 2. 带进度跟踪的文件上传

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const UploadTracker = @import("upload_progress.zig").UploadTracker;
const utils = @import("utils.zig");

var upload_tracker: UploadTracker = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    upload_tracker = UploadTracker.init(allocator);
    defer upload_tracker.deinit();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    try server.post("/upload", uploadHandler);
    try server.get("/upload/progress/:id", progressHandler);

    try server.start();
}

fn uploadHandler(ctx: *HTTPServer.Context) !void {
    // 生成上传 ID
    const upload_id = try utils.generateShortId(ctx.allocator, ctx.io);

    // 开始跟踪
    _ = upload_tracker.startUpload(upload_id, "file.txt");

    try ctx.response.writeJSON(.{ .upload_id = upload_id });
}

fn progressHandler(ctx: *HTTPServer.Context) !void {
    const upload_id = ctx.params.get("id") orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const progress = upload_tracker.getProgress(upload_id) orelse {
        ctx.response.setStatus(.not_found);
        return;
    };

    try ctx.response.writeJSON(.{
        .upload_id = upload_id,
        .progress = progress.progress,
        .total = progress.total,
        .speed = progress.speed,
        .eta = progress.eta,
    });
}
```

---

## 静态文件服务示例

### 1. 基本静态文件服务

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const StaticServer = @import("static_server.zig").StaticServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    // 初始化静态文件服务器
    var static_server = try StaticServer.init(allocator, "./public");
    defer static_server.deinit();

    server.setStaticServer(&static_server);

    try server.start();
}
```

### 2. 自定义配置的静态文件服务

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const StaticServer = @import("static_server.zig").StaticServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    // 自定义配置
    const config = StaticServer.Config{
        .root_path = "./public",
        .index_file = "index.html",
        .enable_compression = true,
        .enable_range = true,
        .enable_etag = true,
        .max_file_size = 100 * 1024 * 1024, // 100MB
    };

    var static_server = try StaticServer.initWithConfig(allocator, config);
    defer static_server.deinit();

    server.setStaticServer(&static_server);

    try server.get("/static/*", staticHandler);
    try server.start();
}

fn staticHandler(ctx: *HTTPServer.Context) !void {
    const static_server = server.static_server orelse {
        ctx.response.setStatus(.internal_server_error);
        return;
    };

    try static_server.serve(ctx);
}
```

---

## 认证授权示例

### 1. JWT 认证（简化版）

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;

const User = struct {
    id: u32,
    username: []const u8,
    password_hash: []const u8,
};

// 模拟用户数据库
var users = [_]User{
    .{ .id = 1, .username = "alice", .password_hash = "hash1" },
    .{ .id = 2, .username = "bob", .password_hash = "hash2" },
};

// 模拟 token 存储
var tokens = std.StringHashMap(u32).init(std.heap.page_allocator);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ .port = 8080 });
    defer server.deinit();

    try server.post("/auth/login", loginHandler);
    try server.get("/auth/logout", logoutHandler);
    try server.get("/api/profile", profileHandler);

    try server.start();
}

fn loginHandler(ctx: *HTTPServer.Context) !void {
    const Credentials = struct { username: []const u8, password: []const u8 };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const creds = std.json.parseFromSlice(Credentials, ctx.allocator, body, .{}) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };
    defer creds.deinit();

    // 查找用户
    const user = for (users) |u| {
        if (std.mem.eql(u8, u.username, creds.value.username)) {
            break u;
        }
    } else {
        ctx.response.setStatus(.unauthorized);
        try ctx.response.writeJSON(.{ .error = "Invalid credentials" });
        return;
    };

    // 简化：实际应该验证密码哈希
    const token = try generateToken(ctx.allocator);
    try tokens.put(token, user.id);

    try ctx.response.writeJSON(.{
        .token = token,
        .user = .{ .id = user.id, .username = user.username },
    });
}

fn logoutHandler(ctx: *HTTPServer.Context) !void {
    const auth_header = ctx.getHeader("Authorization") orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const token = auth_header["Bearer ".len..];
    _ = tokens.remove(token);

    try ctx.response.writeJSON(.{ .message = "Logged out" });
}

fn profileHandler(ctx: *HTTPServer.Context) !void {
    const auth_header = ctx.getHeader("Authorization") orelse {
        ctx.response.setStatus(.unauthorized);
        return;
    };

    const token = auth_header["Bearer ".len..];
    const user_id = tokens.get(token) orelse {
        ctx.response.setStatus(.unauthorized);
        return;
    };

    // 查找用户
    for (users) |user| {
        if (user.id == user_id) {
            try ctx.response.writeJSON(.{
                .id = user.id,
                .username = user.username,
            });
            return;
        }
    }

    ctx.response.setStatus(.not_found);
}

fn generateToken(allocator: std.mem.Allocator) ![]const u8 {
    // 简化：实际应该使用加密安全的随机生成
    const token = try allocator.alloc(u8, 32);
    for (token) |*c| {
        c.* = @as(u8, @intCast(std.crypto.random.intRangeAtMost(u8, 97, 122)));
    }
    return token;
}
```

---

## 完整应用示例

### 博客应用

```zig
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const SessionManager = @import("session.zig").SessionManager;
const MemorySessionStore = @import("session.zig").MemorySessionStore;

const Post = struct {
    id: u32,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
};

var posts = std.ArrayList(Post).init(std.heap.page_allocator);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{
        .port = 8080,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // 初始化会话
    var session_manager = SessionManager.init(allocator);
    defer session_manager.deinit();
    var store = MemorySessionStore.init(allocator, 3600);
    defer store.deinit();
    session_manager.setSessionStore(&store.base);
    server.setSessionManager(&session_manager);

    // 静态文件
    var static_server = try @import("static_server.zig").StaticServer.init(allocator, "./public");
    defer static_server.deinit();
    server.setStaticServer(&static_server);

    // 路由
    try server.get("/", homeHandler);
    try server.get("/posts", listPosts);
    try server.get("/posts/:id", getPost);
    try server.post("/posts", createPost);
    try server.post("/auth/login", loginHandler);
    try server.get("/auth/logout", logoutHandler);

    try server.start();
}

fn homeHandler(ctx: *HTTPServer.Context) !void {
    try ctx.response.write("<h1>Blog Home</h1><a href=\"/posts\">All Posts</a>");
}

fn listPosts(ctx: *HTTPServer.Context) !void {
    var html = std.ArrayList(u8).init(ctx.allocator);
    defer html.deinit(ctx.allocator);

    try html.appendSlice("<h1>All Posts</h1>");

    for (posts.items) |post| {
        try html.writer().print(
            "<h2>{s}</h2><p>By {s}</p><a href=\"/posts/{d}\">Read more</a><hr>",
            .{ post.title, post.author, post.id },
        );
    }

    ctx.response.setHeader("Content-Type", "text/html") catch {};
    try ctx.response.writeAll(html.items);
}

fn getPost(ctx: *HTTPServer.Context) !void {
    const id_str = ctx.params.get("id") orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };

    for (posts.items) |post| {
        if (post.id == id) {
            ctx.response.setHeader("Content-Type", "text/html") catch {};
            try ctx.response.writer().print(
                "<h1>{s}</h1><p>By {s}</p><p>{s}</p>",
                .{ post.title, post.author, post.content },
            );
            return;
        }
    }

    ctx.response.setStatus(.not_found);
}

fn createPost(ctx: *HTTPServer.Context) !void {
    const session = ctx.session orelse {
        ctx.response.setStatus(.unauthorized);
        try ctx.response.writeJSON(.{ .error = "Not authenticated" });
        return;
    };

    const author = session.get("username") orelse {
        ctx.response.setStatus(.unauthorized);
        return;
    };

    const PostInput = struct { title: []const u8, content: []const u8 };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const input = std.json.parseFromSlice(PostInput, ctx.allocator, body, .{}) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };
    defer input.deinit();

    const new_post = Post{
        .id = @as(u32, @intCast(posts.items.len)) + 1,
        .title = input.value.title,
        .content = input.value.content,
        .author = author,
        .created_at = std.time.timestamp(),
    };
    try posts.append(new_post);

    ctx.response.setStatus(.created);
    try ctx.response.writeJSON(.{ .post = new_post });
}

fn loginHandler(ctx: *HTTPServer.Context) !void {
    const Credentials = struct { username: []const u8, password: []const u8 };

    const body = try ctx.getBody();
    defer ctx.allocator.free(body);

    const creds = std.json.parseFromSlice(Credentials, ctx.allocator, body, .{}) catch {
        ctx.response.setStatus(.bad_request);
        return;
    };
    defer creds.deinit();

    // 简化验证
    if (std.mem.eql(u8, creds.value.password, "password")) {
        const session = try ctx.getSession();
        try session.set("username", creds.value.username);
        try ctx.response.writeJSON(.{ .success = true });
    } else {
        ctx.response.setStatus(.unauthorized);
        try ctx.response.writeJSON(.{ .error = "Invalid credentials" });
    }
}

fn logoutHandler(ctx: *HTTPServer.Context) !void {
    try ctx.destroySession();
    try ctx.response.writeJSON(.{ .success = true });
}
```

---

## 测试方法

### 运行服务器

```bash
# 编译
zig build

# 运行
./zig-out/bin/zig_http

# 或直接运行
zig build run
```

### 测试 API

```bash
# 安装 httpie 或使用 curl
pip install httpie

# 测试端点
http GET http://127.0.0.1:8080/
http GET http://127.0.0.1:8080/api/users
http POST http://127.0.0.1:8080/api/users name=Alice email=alice@example.com
```

### WebSocket 测试

```javascript
// 在浏览器控制台中运行
const ws = new WebSocket('ws://127.0.0.1:8080/ws/echo');

ws.onmessage = (event) => {
    console.log('Received:', event.data);
};

ws.send('Hello, WebSocket!');
```

---

## 许可证

MIT License
