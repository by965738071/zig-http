const std = @import("std");
const Context = @import("context.zig").Context;

/// Interceptor phase
pub const Phase = enum {
    /// Before request is processed
    before_request,
    /// After response is generated but before sending
    after_response,
    /// On error during request processing
    on_error,
};

/// Interceptor context
pub const InterceptorContext = struct {
    allocator: std.mem.Allocator,
    phase: Phase,
    context: *Context,
    error_val: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, phase: Phase, ctx: *Context) InterceptorContext {
        return .{
            .allocator = allocator,
            .phase = phase,
            .context = ctx,
            .error_val = null,
        };
    }

    pub fn setError(self: *InterceptorContext, err: anyerror) void {
        self.error_val = err;
    }
};

/// Interceptor trait
pub const Interceptor = struct {
    name: []const u8,
    /// Process the interceptor
    process: *const fn (ctx: *InterceptorContext) anyerror!void,

    pub fn init(name: []const u8, process_fn: *const fn (ctx: *InterceptorContext) anyerror!void) Interceptor {
        return .{
            .name = name,
            .process = process_fn,
        };
    }
};

/// Interceptor registry
pub const InterceptorRegistry = struct {
    allocator: std.mem.Allocator,
    before_request: std.ArrayList(*Interceptor),
    after_response: std.ArrayList(*Interceptor),
    on_error: std.ArrayList(*Interceptor),

    pub fn init(allocator: std.mem.Allocator) InterceptorRegistry {
        return .{
            .allocator = allocator,
            .before_request = std.ArrayList(*Interceptor).init(allocator),
            .after_response = std.ArrayList(*Interceptor).init(allocator),
            .on_error = std.ArrayList(*Interceptor).init(allocator),
        };
    }

    pub fn deinit(self: *InterceptorRegistry) void {
        self.before_request.deinit();
        self.after_response.deinit();
        self.on_error.deinit();
    }

    /// Add interceptor for before request phase
    pub fn addBeforeRequest(self: *InterceptorRegistry, interceptor: *Interceptor) !void {
        try self.before_request.append(interceptor);
    }

    /// Add interceptor for after response phase
    pub fn addAfterResponse(self: *InterceptorRegistry, interceptor: *Interceptor) !void {
        try self.after_response.append(interceptor);
    }

    /// Add interceptor for on error phase
    pub fn addOnError(self: *InterceptorRegistry, interceptor: *Interceptor) !void {
        try self.on_error.append(interceptor);
    }

    /// Execute all before request interceptors
    pub fn executeBeforeRequest(self: *InterceptorRegistry, ctx: *Context) !void {
        var interceptor_ctx = InterceptorContext.init(self.allocator, .before_request, ctx);
        for (self.before_request.items) |interceptor| {
            interceptor.process(&interceptor_ctx) catch |err| {
                std.log.warn("Interceptor '{s}' failed: {}", .{interceptor.name, err});
                return err;
            };
        }
    }

    /// Execute all after response interceptors
    pub fn executeAfterResponse(self: *InterceptorRegistry, ctx: *Context) !void {
        var interceptor_ctx = InterceptorContext.init(self.allocator, .after_response, ctx);
        for (self.after_response.items) |interceptor| {
            interceptor.process(&interceptor_ctx) catch |err| {
                std.log.warn("Interceptor '{s}' failed: {}", .{interceptor.name, err});
                // Don't fail the response if interceptor fails
            };
        }
    }

    /// Execute all on error interceptors
    pub fn executeOnError(self: *InterceptorRegistry, ctx: *Context, err: anyerror) void {
        var interceptor_ctx = InterceptorContext.init(self.allocator, .on_error, ctx);
        interceptor_ctx.setError(err);
        for (self.on_error.items) |interceptor| {
            interceptor.process(&interceptor_ctx) catch |e| {
                std.log.warn("Error interceptor '{s}' failed: {}", .{interceptor.name, e});
            };
        }
    }
};

/// Built-in interceptors

/// Logging interceptor - logs request/response details
pub fn loggingInterceptor(ctx: *InterceptorContext) !void {
    const request_id = ctx.context.getRequestId() orelse "unknown";

    switch (ctx.phase) {
        .before_request => {
            const method = @tagName(ctx.context.request.head.method);
            const path = ctx.context.request.head.target;
            std.log.info("[{s}] {s} {s}", .{ request_id, method, path });
        },
        .after_response => {
            const status = ctx.context.response.status;
            std.log.info("[{s}] Response: {}", .{ request_id, status });
        },
        .on_error => {
            if (ctx.error_val) |err| {
                std.log.err("[{s}] Error: {}", .{ request_id, err });
            }
        },
    }
}

/// Timing interceptor - measures request processing time
var request_timings = std.StringHashMap(i64).init(std.heap.page_allocator);

pub fn timingInterceptor(ctx: *InterceptorContext) !void {
    const request_id = ctx.context.getRequestId() orelse return error.NoRequestId;

    switch (ctx.phase) {
        .before_request => {
            const now = std.time.milliTimestamp();
            try request_timings.put(request_id, now);
        },
        .after_response => {
            const start_ms = request_timings.get(request_id) orelse return error.NoTiming;
            const now = std.time.milliTimestamp();
            const duration_ms = now - start_ms;
            std.log.info("[{s}] Processing time: {d}ms", .{ request_id, duration_ms });
            _ = request_timings.remove(request_id);
        },
        .on_error => {
            _ = request_timings.remove(request_id);
        },
    }
}

/// Request size interceptor - monitors request/response sizes
pub fn sizeInterceptor(ctx: *InterceptorContext) !void {
    switch (ctx.phase) {
        .before_request => {
            if (ctx.context.request.head.content_length) |len| {
                std.log.debug("Request body size: {d} bytes", .{len});
            }
        },
        .after_response => {
            const size = ctx.context.response.body.items.len;
            std.log.debug("Response body size: {d} bytes", .{size});
        },
        .on_error => {},
    }
}
