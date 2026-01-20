const std = @import("std");
const http = std.http;

const Context = @import("context.zig").Context;

pub const Middleware = struct {
    name: []const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        process: *const fn (*anyopaque, *Context) anyerror!NextAction,
        destroy: *const fn (*anyopaque) void,
    };

    pub const NextAction = enum {
        @"continue",  // Continue to next middleware
        respond,   // Respond immediately, don't continue
        err,     // Error handling
    };

    pub fn init(comptime T: type) Middleware {
        return .{
            .name = @typeName(T),
            .vtable = &.{
                .process = struct {
                    fn process(ptr: *anyopaque, ctx: *Context) !NextAction {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.process(ctx);
                    }
                }.process,
                .destroy = struct {
                    fn destroy(ptr: *anyopaque) void {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        if (@hasDecl(T, "deinit")) {
                            self.deinit();
                        }
                    }
                }.destroy,
            },
        };
    }
};
