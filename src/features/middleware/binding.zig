const std = @import("std");
const Context = @import("../../core/context.zig").Context;
const Binder = @import("../../core/binder.zig").Binder;

pub const BindingMiddleware = struct {
    pub fn handle(ctx: *Context, comptime T: type, handler: *const fn (ctx: *Context, data: T) anyerror!void) !void {
        const binder = Binder.init(ctx.allocator, ctx);
        const data = binder.bind(T) catch |err| {
            try ctx.response.setStatus(std.http.Status.bad_request);
            try ctx.response.writeJSON(.{
                .status = "error",
                .message = "Parameter binding failed",
                .reason = @errorName(err),
            });
            return;
        };
        try handler(ctx, data);
    }
};

pub fn bindHandler(comptime Fn: type) type {
    return struct {
        pub fn call(ctx: *Context) !void {
            const fn_info = @typeInfo(Fn).@"fn";

            if (fn_info.params.len < 2) {
                return error.InvalidHandler;
            }

            const param_type = fn_info.params[1].type.?;

            const binder = Binder.init(ctx.allocator, ctx);
            const param = binder.bind(param_type) catch |err| {
                try ctx.response.setStatus(std.http.Status.bad_request);
                try ctx.response.writeJSON(.{
                    .status = "error",
                    .message = "Binding failed",
                    .reason = @errorName(err),
                });
                return;
            };

            const args: std.meta.ArgsTuple(Fn) = .{ ctx, param };
            try @call(.auto, fn_info.return_type.?, args);
        }
    };
}

pub const User = struct {
    id: ?u32 = null,
    name: []const u8,
    email: ?[]const u8 = null,
    age: u32,
    active: bool = true,
};

pub fn createUserHandler(ctx: *Context, user: User) !void {
    try ctx.response.writeJSON(.{
        .status = "success",
        .user = user,
    });
}

pub const boundCreateUserHandler = bindHandler(@TypeOf(createUserHandler));
