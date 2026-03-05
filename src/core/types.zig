const std = @import("std");
const Context = @import("context.zig").Context;

pub const Handler = *const fn (ctx: *Context) anyerror!void;

pub fn HandlerWithParams(comptime Fn: type) type {
    return struct {
        func: Fn,

        pub fn call(self: @This(), ctx: *Context) !void {
            const binder = @import("binder.zig").Binder;

            const info = @typeInfo(Fn).@"fn";

            comptime std.debug.assert(info.params.len > 0);
            comptime std.debug.assert(info.params[0].type.? == *Context);

            var args: std.meta.ArgsTuple(Fn) = undefined;
            args[0] = ctx;

            const b = binder.init(ctx.allocator, ctx);

            inline for (info.params[1..], 1..) |param, i| {
                const param_type = param.type.?;

                const value = b.bind(param_type) catch |err| {
                    ctx.response.setStatus(std.http.Status.bad_request);
                    try ctx.response.writeJSON(.{
                        .error_val = "Parameter binding failed",
                        .reason = @errorName(err),
                    });
                    return;
                };

                args[i] = value;
            }

            try @call(.auto, self.func, args);
        }
    };
}

pub fn wrapHandler(comptime fn_ptr: anytype) Handler {
    const HandlerWrapper = HandlerWithParams(@TypeOf(fn_ptr));
    const wrapper = HandlerWrapper{ .func = fn_ptr };
    return struct {
        fn wrapped(ctx: *Context) anyerror!void {
            try wrapper.call(ctx);
        }
    }.wrapped;
}

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
                        const binder = @import("binder.zig").Binder;
                        const actual_func = @as(Fn, @ptrCast(@alignCast(ptr)));
                        const info = @typeInfo(Fn).@"fn";

                        var args: std.meta.ArgsTuple(Fn) = undefined;

                        const b = binder.init(ctx.allocator, ctx);

                        inline for (info.params, 0..) |param, i| {
                            if (i == 0) {
                                args[i] = ctx;
                            } else {
                                const param_type = param.type.?;

                                const value = b.bind(param_type) catch |err| {
                                    ctx.response.setStatus(std.http.Status.bad_request);
                                    try ctx.response.writeJSON(.{
                                        .error_val = "Parameter binding failed",
                                        .reason = @errorName(err),
                                    });
                                    return;
                                };

                                args[i] = value;
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
    request_timeout: u64 = 30_000,
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 4096,
    max_request_body_size: usize = 10 * 1024 * 1024,
    max_header_size: usize = 8192,
    connection_timeout: u64 = 60_000,
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

    pub fn iterator(list: ParamList) std.StringHashMap([]const u8).Iterator {
        return list.data.iterator();
    }
};
