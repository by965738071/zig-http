const std = @import("std");
const http = std.http;
const Io = std.Io;

/// WebSocket handler function type
pub const WebSocketHandler = *const fn (*WebSocketContext) anyerror!void;

/// Re-export http.WebSocket types for convenience
pub const WebSocket = http.Server.WebSocket;
pub const Opcode = http.Server.WebSocket.Opcode;
pub const SmallMessage = http.Server.WebSocket.SmallMessage;
pub const ReadSmallTextMessageError = http.Server.WebSocket.ReadSmallTextMessageError;

/// WebSocket context for handling WebSocket connections
pub const WebSocketContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    ws: WebSocket,
    read_buffer: []u8,

    /// Send a text message
    pub fn sendText(ctx: *WebSocketContext, data: []const u8) !void {
        try ctx.ws.writeMessage(data, .text);
    }

    /// Send a binary message
    pub fn sendBinary(ctx: *WebSocketContext, data: []const u8) !void {
        try ctx.ws.writeMessage(data, .binary);
    }

    /// Send a ping frame
    pub fn ping(ctx: *WebSocketContext, data: []const u8) !void {
        try ctx.ws.writeMessage(data, .ping);
    }

    /// Send a pong frame
    pub fn pong(ctx: *WebSocketContext, data: []const u8) !void {
        try ctx.ws.writeMessage(data, .pong);
    }

    /// Close the connection
    pub fn close(ctx: *WebSocketContext) void {
        const data = [_]u8{ 0x03, 0xE8 }; // Normal closure code 1000
        _ = ctx.ws.writeMessage(&data, .connection_close) catch {};
    }

    /// Receive a message (blocking)
    pub fn receive(ctx: *WebSocketContext) !Message {
        const msg = try ctx.ws.readSmallMessage();
        return .{
            .opcode = msg.opcode,
            .data = try ctx.allocator.dupe(u8, msg.data),
        };
    }

    /// Free message data
    pub fn freeMessage(ctx: *WebSocketContext, msg: *Message) void {
        ctx.allocator.free(msg.data);
    }
};

/// WebSocket message
pub const Message = struct {
    opcode: Opcode,
    data: []u8,
};

/// WebSocket server for managing WebSocket upgrades
pub const WebSocketServer = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(WebSocketHandler),
    default_handler: ?WebSocketHandler = null,

    pub fn init(allocator: std.mem.Allocator) WebSocketServer {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(WebSocketHandler).init(allocator),
            .default_handler = null,
        };
    }

    pub fn deinit(server: *WebSocketServer) void {
        var iter = server.handlers.iterator();
        while (iter.next()) |entry| {
            server.allocator.free(entry.key_ptr.*);
        }
        server.handlers.deinit();
    }

    /// Register a WebSocket handler for a specific path
    pub fn handle(server: *WebSocketServer, path: []const u8, handler: WebSocketHandler) !void {
        const key = try server.allocator.dupe(u8, path);
        try server.handlers.put(key, handler);
    }

    /// Set default handler for unmatched paths
    pub fn setDefaultHandler(server: *WebSocketServer, handler: WebSocketHandler) void {
        server.default_handler = handler;
    }

    /// Check if a path has a WebSocket handler
    pub fn hasHandler(server: *WebSocketServer, path: []const u8) bool {
        return server.handlers.get(path) != null or server.default_handler != null;
    }

    /// Get handler for a path
    pub fn getHandler(server: *WebSocketServer, path: []const u8) ?WebSocketHandler {
        return server.handlers.get(path) orelse server.default_handler;
    }
};

/// Simple WebSocket echo server example
pub fn echoServer(ws: *WebSocketContext) !void {
    std.log.info("WebSocket client connected", .{});

    // Send welcome message
    try ws.sendText("Welcome to WebSocket echo server!");

    while (true) {
        var msg = try ws.receive();
        defer ws.freeMessage(&msg);

        switch (msg.opcode) {
            .text, .binary => {
                std.log.debug("Received {s} message: {s}", .{
                    @tagName(msg.opcode),
                    msg.data,
                });

                // Echo back
                if (msg.opcode == .text) {
                    try ws.sendText(msg.data);
                } else {
                    try ws.sendBinary(msg.data);
                }
            },
            .ping => {
                // Respond with pong
                try ws.pong(msg.data);
            },
            .connection_close => {
                std.log.info("Client requested close", .{});
                return;
            },
            else => {},
        }
    }
}

/// Chat room example
pub const ChatRoom = struct {
    clients: std.ArrayList(*WebSocketContext),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ChatRoom {
        return .{
            .clients = std.ArrayList(*WebSocketContext).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(room: *ChatRoom) void {
        for (room.clients.items) |client| {
            client.close();
        }
        room.clients.deinit();
    }

    pub fn addClient(room: *ChatRoom, client: *WebSocketContext) !void {
        try room.clients.append(client);
        std.log.info("Client joined. Total clients: {d}", .{room.clients.items.len});
    }

    pub fn removeClient(room: *ChatRoom, client: *WebSocketContext) void {
        for (room.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = room.clients.orderedRemove(i);
                break;
            }
        }
        std.log.info("Client left. Total clients: {d}", .{room.clients.items.len});
    }

    pub fn broadcast(room: *ChatRoom, message: []const u8) void {
        var failed_clients = std.ArrayList(usize).init(room.allocator);
        defer failed_clients.deinit();

        for (room.clients.items, 0..) |client, i| {
            client.sendText(message) catch |err| {
                std.log.err("Failed to send to client {d}: {}", .{ i, err });
                failed_clients.append(room.allocator, i) catch {};
            };
        }

        // Remove failed clients (in reverse order to maintain indices)
        var i = failed_clients.items.len;
        while (i > 0) {
            i -= 1;
            const idx = failed_clients.items[i];
            _ = room.clients.orderedRemove(idx);
        }
    }
};

test "WebSocket message parsing" {
    // Test that we can import and use WebSocket types
    const WS = http.Server.WebSocket;
    _ = WS;
    const op = http.Server.WebSocket.Opcode.text;
    _ = op;
}
