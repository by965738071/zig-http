const std = @import("std");
const Context = @import("../core/context.zig").Context;
const binder = @import("../core/binder.zig");

/// Parameter binding middleware
/// Automatically binds request parameters to handler arguments
pub const BindingMiddleware = struct {
    /// Next handler in the chain
    next: Handler,

    pub const Handler = *const fn (ctx: *Context) anyerror!void;

    pub fn init(next: Handler) BindingMiddleware {
        return .{ .next = next };
    }

    pub fn handle(middleware: BindingMiddleware, ctx: *Context) !void {
        try middleware.next(ctx);
    }
};

/// Generic handler wrapper that auto-binds parameters
pub fn bindHandler(comptime HandlerFunc: type, comptime ParamTypes: []const type) type {
    return struct {
        ctx: *Context,

        pub fn call(ctx: *Context) !void {
            // const handler = @This();

            comptime var args: [ParamTypes.len]ParamTypes = undefined;

            inline for (ParamTypes, 0..) |T, i| {
                // Try to bind from request
                var result = binder.bindRequest(T, ctx);
                defer result.deinit(ctx.allocator);

                if (result.has_errors) {
                    // Return validation errors
                    try ctx.response.setStatus(std.http.Status.bad_request);
                    try ctx.response.writeJSON(.{
                        .status = "error",
                        .message = "Parameter binding failed",
                        .errors = result.errors.items,
                    });
                    return;
                }

                if (binder.getBoundValue(T, &result)) |bound| {
                    args[i] = bound.*;
                }
            }

            // Call the actual handler with bound parameters
            @call(.auto, HandlerFunc, .{ ctx } ++ args);
        }
    };
}

// ====================================================================
// Decorator pattern for parameter binding
// ====================================================================

/// Decorator that auto-binds parameters to a handler
pub fn bind(comptime HandlerFunc: type) type {
    // Extract parameter types from handler function signature
    const fn_info = @typeInfo(HandlerFunc).@"fn";
    comptime var param_types: [fn_info.params.len - 1]type = undefined;

    inline for (fn_info.params[1..], 0..) |param, i| {
        param_types[i] = param.type.?;
    }

    return bindHandler(HandlerFunc, &param_types);
}

// ====================================================================
// Example usage
// ====================================================================

// Example data model
pub const User = struct {
    id: ?u32 = null,
    name: []const u8,
    email: []const u8,
    age: u32,
    active: bool = true,
};

// Example handler with auto-binding
pub fn addUserHandler(ctx: *Context, user: User) !void {
    // user is already bound from request parameters
    try ctx.response.writeJSON(.{
        .status = "success",
        .user = user,
    });
}

// Create a bound handler
pub const boundAddUserHandler = bind(addUserHandler);

// ====================================================================
// Advanced: Custom binding with annotations
// ====================================================================

/// Custom binding attribute marker
/// In Zig, we can use const declarations to simulate annotations
pub const BindParam = struct {
    name: []const u8,
    required: bool = true,
};

// Example struct with "annotations" as comments (simulated)
// pub const CreateUserRequest = struct {
//     // @QueryParam("userId")
//     user_id: u32,
//
//     // @RequestHeader("Authorization")
//     auth_token: []const u8,
//
//     // @RequestBody
//     user_data: User,
// };

// ====================================================================
// Middleware that auto-binds before calling handler
// ====================================================================

/// Auto-binding middleware for specific parameter types
pub fn AutoBindMiddleware(comptime T: type, comptime handler: *const fn (ctx: *Context, param: T) anyerror!void) type {
    return struct {
        pub fn call(ctx: *Context) !void {
            var result = binder.bindRequest(T, ctx);
            defer result.deinit(ctx.allocator);

            if (result.has_errors) {
                try ctx.response.setStatus(std.http.Status.bad_request);
                try ctx.response.writeJSON(.{
                    .status = "error",
                    .errors = result.errors.items,
                });
                return;
            }

            if (binder.getBoundValue(T, &result)) |bound| {
                try handler(ctx, bound.*);
            }
        }
    };
}

// ====================================================================
// Examples
// ====================================================================

// Example 1: Simple struct binding
pub const LoginRequest = struct {
    username: []const u8,
    password: []const u8,
    remember_me: bool = false,
};

pub fn loginHandler(ctx: *Context, req: LoginRequest) !void {
    // Validate login
    if (std.mem.eql(u8, req.username, "admin") and std.mem.eql(u8, req.password, "secret")) {
        try ctx.response.writeJSON(.{
            .status = "success",
            .message = "Login successful",
        });
    } else {
        try ctx.response.setStatus(std.http.Status.unauthorized);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Invalid credentials",
        });
    }
}

// Example 2: Create a bound handler
pub const boundLoginHandler = bind(loginHandler);

// Example 3: Using AutoBindMiddleware directly
pub const boundLoginMiddleware = AutoBindMiddleware(LoginRequest, loginHandler);
