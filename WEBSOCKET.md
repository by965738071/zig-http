# WebSocket 支持

本项目基于 Zig 的 `std.http` 模块实现了完整的 WebSocket 支持。

## 功能特性

- ✅ WebSocket 协议升级处理
- ✅ 文本消息和二进制消息
- ✅ Ping/Pong 心跳检测
- ✅ 优雅的连接关闭
- ✅ 多路径路由支持
- ✅ 聊天室示例

## 核心模块

### `WebSocketContext`

WebSocket 连接的上下文对象，提供消息发送和接收功能：

```zig
pub const WebSocketContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    ws: WebSocket,  // http.Server.WebSocket
    read_buffer: []u8,

    // 发送文本消息
    pub fn sendText(ctx: *WebSocketContext, data: []const u8) !void;

    // 发送二进制消息
    pub fn sendBinary(ctx: *WebSocketContext, data: []const u8) !void;

    // 发送 Ping 帧
    pub fn ping(ctx: *WebSocketContext, data: []const u8) !void;

    // 发送 Pong 帧
    pub fn pong(ctx: *WebSocketContext, data: []const u8) !void;

    // 关闭连接
    pub fn close(ctx: *WebSocketContext) void;

    // 接收消息（阻塞）
    pub fn receive(ctx: *WebSocketContext) !Message;

    // 释放消息数据
    pub fn freeMessage(ctx: *WebSocketContext, msg: *Message) void;
};
```

### `WebSocketServer`

WebSocket 服务器，用于管理 WebSocket 升级和路由：

```zig
pub const WebSocketServer = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(WebSocketHandler),
    default_handler: ?WebSocketHandler = null,

    // 初始化服务器
    pub fn init(allocator: std.mem.Allocator) WebSocketServer;

    // 注册路由处理器
    pub fn handle(server: *WebSocketServer, path: []const u8, handler: WebSocketHandler) !void;

    // 设置默认处理器
    pub fn setDefaultHandler(server: *WebSocketServer, handler: WebSocketHandler) void;

    // 检查路径是否有处理器
    pub fn hasHandler(server: *WebSocketServer, path: []const u8) bool;

    // 获取路径的处理器
    pub fn getHandler(server: *WebSocketServer, path: []const u8) ?WebSocketHandler;
};
```

## 使用示例

### 1. Echo 服务器

```zig
const WebSocketServer = @import("websocket.zig").WebSocketServer;

// 初始化 WebSocket 服务器
var ws_server = WebSocketServer.init(allocator);
defer ws_server.deinit();

// 注册 echo 处理器
try ws_server.handle("/ws/echo", echoHandler);

// 处理器函数
fn echoHandler(ws: *WebSocketContext) !void {
    std.log.info("WebSocket client connected", .{});

    // 发送欢迎消息
    try ws.sendText("Welcome to WebSocket echo server!");

    while (true) {
        var msg = try ws.receive();
        defer ws.freeMessage(&msg);

        switch (msg.opcode) {
            .text, .binary => {
                // 回显消息
                if (msg.opcode == .text) {
                    try ws.sendText(msg.data);
                } else {
                    try ws.sendBinary(msg.data);
                }
            },
            .ping => {
                try ws.pong(msg.data);
            },
            .connection_close => {
                return;
            },
            else => {},
        }
    }
}
```

### 2. 聊天室

```zig
const ChatRoom = @import("websocket.zig").ChatRoom;

var chat_room = ChatRoom.init(allocator);
defer chat_room.deinit();

fn chatHandler(ws: *WebSocketContext) !void {
    try chat_room.addClient(ws);
    defer chat_room.removeClient(ws);

    while (true) {
        var msg = try ws.receive();
        defer ws.freeMessage(&msg);

        switch (msg.opcode) {
            .text => {
                // 广播消息给所有客户端
                chat_room.broadcast(msg.data);
            },
            .connection_close => return,
            else => {},
        }
    }
}
```

## 集成到 HTTP 服务器

```zig
pub fn main() !void {
    // ... HTTP 服务器初始化 ...

    // 初始化 WebSocket 服务器
    var ws_server = WebSocketServer.init(allocator);
    defer ws_server.deinit();

    try ws_server.handle("/ws/echo", echoHandler);

    // 设置到 HTTP 服务器
    var server = try httpServer.init(allocator, .{
        .port = 8080,
        .host = "127.0.0.1",
    });
    server.setWebSocketServer(ws_server);

    // 启动服务器
    server.start(io) catch |err| {
        std.log.err("Error starting server: {}", .{err});
        return err;
    };
    defer server.deinit();
}
```

## 测试

访问 `http://127.0.0.1:8080/ws` 打开 WebSocket 测试页面，或使用以下 JavaScript 代码：

```javascript
const ws = new WebSocket('ws://127.0.0.1:8080/ws/echo');

ws.onopen = function() {
    console.log('Connected!');
    ws.send('Hello, WebSocket!');
};

ws.onmessage = function(event) {
    console.log('Received:', event.data);
};

ws.onclose = function() {
    console.log('Disconnected');
};
```

## Opcode 类型

```zig
// 从 std.http.Server.WebSocket.Opcode 重新导出
pub const Opcode = enum(u4) {
    continuation = 0,    // 继续帧
    text = 1,           // 文本帧
    binary = 2,         // 二进制帧
    connection_close = 8,// 关闭连接
    ping = 9,           // Ping 帧
    pong = 10,          // Pong 帧
};
```

## 注意事项

1. **内存管理**: `receive()` 返回的消息数据需要使用 `freeMessage()` 释放
2. **阻塞调用**: `receive()` 是阻塞调用，需要处理可能的错误
3. **连接关闭**: 正确处理 `connection_close` opcode 以实现优雅关闭
4. **Ping/Pong**: 可以实现心跳检测机制保持连接活跃
5. **缓冲区限制**: `readSmallMessage()` 有消息大小限制，基于输入缓冲区大小

## 性能建议

1. 使用合适的缓冲区大小（当前使用 8192 字节）
2. 考虑异步处理多个 WebSocket 连接
3. 实现消息队列处理高并发场景
4. 添加连接超时和重连机制

## 技术细节

### 依赖的 std.http API

- `http.Server.Request.upgradeRequested()` - 检测 WebSocket 升级请求
- `http.Server.Request.respondWebSocket()` - 执行 WebSocket 协议升级
- `http.Server.WebSocket` - WebSocket 连接对象
- `http.Server.WebSocket.readSmallMessage()` - 读取小消息
- `http.Server.WebSocket.writeMessage()` - 写入消息

### WebSocket 升级流程

1. 客户端发送 HTTP GET 请求，包含：
   - `Upgrade: websocket`
   - `Connection: Upgrade`
   - `Sec-WebSocket-Key: <随机值>`

2. 服务器检测到升级请求（`upgradeRequested()`）

3. 服务器调用 `respondWebSocket()` 返回：
   - HTTP 101 Switching Protocols
   - `Sec-WebSocket-Accept: <hash(key + GUID)>`

4. 连接升级为 WebSocket 协议
