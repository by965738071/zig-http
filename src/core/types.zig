const std = @import("std");
// Context is defined in context.zig to avoid circular dependency
const Context = @import("context.zig").Context;

/// Basic handler with only Context parameter (for backward compatibility)
pub const Handler = *const fn (ctx: *Context) anyerror!void;

/// Advanced handler with automatic parameter binding
/// Users can use HandlerWithParams to define handlers with custom parameters
/// Example:
///   pub fn getUser(ctx: *Context, id: u32) !void { ... }
///   router.get("/users/:id", wrapHandler(getUser));
pub fn HandlerWithParams(comptime Fn: type) type {
    return struct {
        func: Fn,

        pub fn call(self: @This(), ctx: *Context) !void {
            const binder = @import("binder.zig");

            // Get function parameter info
            const info = @typeInfo(Fn).@"fn";

            // Only support functions with Context as first parameter
            comptime std.debug.assert(info.params.len > 0);
            comptime std.debug.assert(info.params[0].type.? == *Context);

            // Bind parameters
            var args: std.meta.ArgsTuple(Fn) = undefined;
            args[0] = ctx; // First arg is always Context

            // Bind remaining parameters
            // Note: Zig doesn't expose parameter names via @typeInfo, so we use index-based binding
            // Users should ensure parameter order matches their expectation
            inline for (info.params[1..], 1..) |param, i| {
                const param_type = param.type.?;

                // For now, we use null as parameter name and rely on default behavior
                // This means binding will try to find a parameter, but without knowing the expected name
                // This is a limitation - in a full implementation, users would provide a mapping
                const param_value = binder.bindParam(param_type, ctx, null) catch |err| {
                    std.log.debug("Failed to bind parameter at index {d}: {}", .{i, err});
                    ctx.response.setStatus(std.http.Status.bad_request);
                    try ctx.response.writeJSON(.{ .error_val = "Failed to bind parameter", .message = "Parameter binding failed" });
                    return;
                };

                args[i] = param_value;
            }

            // Call the original function
            try @call(.auto, self.func, args);
        }
    };
}

/// Wrap a handler function with automatic parameter binding
/// Example:
///   pub fn getUser(ctx: *Context, id: u32) !void { ... }
///   router.get("/users/:id", wrapHandler(getUser));
pub fn wrapHandler(comptime fn_ptr: anytype) Handler {
    const HandlerWrapper = HandlerWithParams(@TypeOf(fn_ptr));
    const wrapper = HandlerWrapper{ .func = fn_ptr };
    return struct {
        fn wrapped(ctx: *Context) anyerror!void {
            try wrapper.call(ctx);
        }
    }.wrapped;
}

/// Alternative: Handler that accepts any function and wraps it
pub const AnyHandler = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        call: *const fn (ctx: *Context, ptr: *const anyopaque) anyerror!void,
    };

    pub fn init(comptime Fn: type, func_ptr: Fn) AnyHandler {
        return .{
            .ptr = func_ptr,
            .vtable = &.{
                .call = struct {
                    fn callWrapper(ctx: *Context, ptr: *const anyopaque) anyerror!void {
                        const binder = @import("binder.zig");
                        const actual_func = @as(Fn, @ptrCast(@alignCast(ptr)));
                        const info = @typeInfo(Fn).@"fn";

                        var args: std.meta.ArgsTuple(Fn) = undefined;

                        inline for (info.params, 0..) |param, i| {
                            if (i == 0) {
                                // First parameter is always Context
                                args[i] = ctx;
                            } else {
                                // Bind remaining parameters
                                // Note: Zig doesn't expose parameter names via @typeInfo
                                const param_type = param.type.?;

                                args[i] = binder.bindParam(param_type, ctx, null) catch |err| {
                                    std.log.debug("Failed to bind parameter at index {d}: {}", .{i, err});
                                    ctx.response.setStatus(std.http.Status.bad_request);
                                    try ctx.response.writeJSON(.{ .error_val = "Failed to bind parameter", .message = "Parameter binding failed" });
                                    return;
                                };
                            }
                        }

                        try @call(.auto, actual_func, args);
                    }
                }.callWrapper,
            },
        };
    }

    pub fn call(self: AnyHandler, ctx: *Context) anyerror!void {
        return self.vtable.call(ctx, self.ptr);
    }
};

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_connections: usize = 1000,
    request_timeout: u64 = 30_000, // 30s
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 4096,
    max_request_body_size: usize = 10 * 1024 * 1024, // 10MB
    max_header_size: usize = 8192, // 8KB
    connection_timeout: u64 = 60_000, // 60s connection timeout
};

pub const Method = std.http.Method;
pub const Status = std.http.Status;

pub const ParamList = struct {
    data: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ParamList {
        return .{
            .data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(list: *ParamList) void {
        list.data.deinit();
    }

    pub fn get(list: ParamList, name: []const u8) ?[]const u8 {
        return list.data.get(name);
    }

    pub fn put(list: *ParamList, name: []const u8, value: []const u8) !void {
        try list.data.put(name, value);
    }
};
