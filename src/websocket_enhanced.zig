const std = @import("std");
const http = std.http;
const Io = std.Io;

const WebSocket = http.Server.WebSocket;
const Opcode = http.Server.WebSocket.Opcode;
const SmallMessage = http.Server.WebSocket.SmallMessage;

/// Enhanced WebSocket context with heartbeat and subprotocol support
pub const WebSocketContextEnhanced = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    ws: WebSocket,
    read_buffer: []u8,

    // Heartbeat configuration
    ping_interval_ns: u64 = 30 * 1_000_000_000, // 30 seconds
    pong_timeout_ns: u64 = 5 * 1_000_000_000, // 5 seconds
    last_pong_time_ns: i64 = 0,
    ping_timer: ?std.time.Timer = null,

    // Subprotocol
    subprotocol: ?[]const u8 = null,

    // Connection state
    connected: bool = true,

    /// Initialize enhanced WebSocket context
    pub fn init(allocator: std.mem.Allocator, io: Io, stream: Io.net.Stream, ws: WebSocket, read_buffer: []u8) WebSocketContextEnhanced {
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .ws = ws,
            .read_buffer = read_buffer,
            .last_pong_time_ns = std.time.nanoTimestamp(),
        };
    }

    /// Send a text message
    pub fn sendText(ctx: *WebSocketContextEnhanced, data: []const u8) !void {
        if (!ctx.connected) return error.ConnectionClosed;
        std.log.debug("WebSocket sending text message: {s}", .{data});
        try ctx.ws.writeMessage(data, .text);
    }

    /// Send a binary message
    pub fn sendBinary(ctx: *WebSocketContextEnhanced, data: []const u8) !void {
        if (!ctx.connected) return error.ConnectionClosed;
        std.log.debug("WebSocket sending binary message ({d} bytes)", .{data.len});
        try ctx.ws.writeMessage(data, .binary);
    }

    /// Send a ping frame
    pub fn ping(ctx: *WebSocketContextEnhanced, data: []const u8) !void {
        if (!ctx.connected) return error.ConnectionClosed;
        std.log.debug("WebSocket sending ping", .{});
        try ctx.ws.writeMessage(data, .ping);
    }

    /// Send a pong frame
    pub fn pong(ctx: *WebSocketContextEnhanced, data: []const u8) !void {
        if (!ctx.connected) return error.ConnectionClosed;
        std.log.debug("WebSocket sending pong", .{});
        try ctx.ws.writeMessage(data, .pong);
    }

    /// Close the connection with custom code
    pub fn close(ctx: *WebSocketContextEnhanced, code: u16, reason: []const u8) void {
        if (!ctx.connected) return;

        ctx.connected = false;

        // Format close frame: 2 bytes code + UTF-8 reason
        var close_data = std.ArrayList(u8).init(ctx.allocator);
        defer close_data.deinit();

        close_data.writer().writeIntBig(u16, code) catch {};
        close_data.appendSlice(reason) catch {};

        _ = ctx.ws.writeMessage(close_data.items, .connection_close) catch {};
        std.log.info("WebSocket closed: code={d}, reason={s}", .{ code, reason });
    }

    /// Receive a message (blocking)
    pub fn receive(ctx: *WebSocketContextEnhanced) !Message {
        if (!ctx.connected) return error.ConnectionClosed;

        const msg = try ctx.ws.readSmallMessage();

        // Handle pong responses automatically
        if (msg.opcode == .pong) {
            ctx.last_pong_time_ns = std.time.nanoTimestamp();
            std.log.debug("WebSocket received pong", .{});
            // Continue waiting for next message
            return try ctx.receive();
        }

        // Handle ping automatically and respond with pong
        if (msg.opcode == .ping) {
            std.log.debug("WebSocket received ping, sending pong", .{});
            try ctx.pong(msg.data);
            // Continue waiting for next message
            return try ctx.receive();
        }

        std.log.debug("WebSocket received message with opcode: {}", .{msg.opcode});

        return .{
            .opcode = msg.opcode,
            .data = try ctx.allocator.dupe(u8, msg.data),
        };
    }

    /// Start heartbeat mechanism
    pub fn startHeartbeat(ctx: *WebSocketContextEnhanced) !void {
        ctx.ping_timer = try std.time.Timer.start();

        while (ctx.connected) {
            // Sleep for ping interval
            std.time.sleep(ctx.ping_interval_ns);

            if (!ctx.connected) break;

            // Check if pong timeout occurred
            const now_ns = ctx.ping_timer.?.read();
            const time_since_pong = now_ns - ctx.last_pong_time_ns;

            if (time_since_pong > ctx.pong_timeout_ns) {
                std.log.warn("WebSocket pong timeout, closing connection", .{});
                ctx.close(1001, "Pong timeout");
                return error.PongTimeout;
            }

            // Send ping
            try ctx.ping(&.{});
        }
    }

    /// Free message data
    pub fn freeMessage(ctx: *WebSocketContextEnhanced, msg: *Message) void {
        ctx.allocator.free(msg.data);
    }
};

/// WebSocket message
pub const Message = struct {
    opcode: Opcode,
    data: []u8,
};

/// Subprotocol negotiator
pub const SubprotocolNegotiator = struct {
    /// Negotiate subprotocol based on client preferences
    pub fn negotiate(client_protocols: []const []const u8, server_protocols: []const []const u8) ?[]const u8 {
        for (client_protocols) |client_proto| {
            for (server_protocols) |server_proto| {
                if (std.mem.eql(u8, client_proto, server_proto)) {
                    return server_proto;
                }
            }
        }
        return null;
    }

    /// Parse Sec-WebSocket-Protocol header
    pub fn parseProtocolHeader(header: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        var protocols = std.ArrayList([]const u8).init(allocator);

        var it = std.mem.splitScalar(u8, header, ',');
        while (it.next()) |proto| {
            const trimmed = std.mem.trim(u8, proto, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                try protocols.append(try allocator.dupe(u8, trimmed));
            }
        }

        return protocols.toOwnedSlice();
    }
};

/// Enhanced WebSocket server
pub const WebSocketServerEnhanced = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(WebSocketHandler),
    default_handler: ?WebSocketHandler = null,
    supported_subprotocols: []const []const u8,

    pub const WebSocketHandler = *const fn (*WebSocketContextEnhanced) anyerror!void;

    pub fn init(allocator: std.mem.Allocator, supported_subprotocols: []const []const u8) WebSocketServerEnhanced {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(WebSocketHandler).init(allocator),
            .default_handler = null,
            .supported_subprotocols = supported_subprotocols,
        };
    }

    pub fn deinit(server: *WebSocketServerEnhanced) void {
        var iter = server.handlers.iterator();
        while (iter.next()) |entry| {
            server.allocator.free(entry.key_ptr.*);
        }
        server.handlers.deinit();
    }

    /// Register a WebSocket handler for a specific path
    pub fn handle(server: *WebSocketServerEnhanced, path: []const u8, handler: WebSocketHandler) !void {
        const key = try server.allocator.dupe(u8, path);
        try server.handlers.put(key, handler);
    }

    /// Get handler for a path
    pub fn getHandler(server: *WebSocketServerEnhanced, path: []const u8) ?WebSocketHandler {
        return server.handlers.get(path);
    }

    /// Check if handler exists for a path
    pub fn hasHandler(server: *WebSocketServerEnhanced, path: []const u8) bool {
        return server.handlers.get(path) != null;
    }

    /// Negotiate subprotocol for a request
    pub fn negotiateSubprotocol(server: *WebSocketServerEnhanced, header: ?[]const u8) !?[]const u8 {
        if (header == null or server.supported_subprotocols.len == 0) return null;

        const client_protocols = try SubprotocolNegotiator.parseProtocolHeader(header.?, server.allocator);
        defer {
            for (client_protocols) |proto| {
                server.allocator.free(proto);
            }
            server.allocator.free(client_protocols);
        }

        return SubprotocolNegotiator.negotiate(client_protocols, server.supported_subprotocols);
    }

    /// Set default handler for unmatched paths
    pub fn setDefaultHandler(server: *WebSocketServerEnhanced, handler: WebSocketHandler) void {
        server.default_handler = handler;
    }
};
