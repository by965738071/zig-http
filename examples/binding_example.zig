const std = @import("std");
const http = std.http;
const Context = @import("../src/core/context.zig").Context;
const binder = @import("../src/core/binder.zig");
const bind = @import("../src/middleware/binding.zig").bind;

// ====================================================================
// Example 1: Define your data models
// ====================================================================

/// User data model
pub const User = struct {
    id: ?u32 = null,
    name: []const u8,
    email: []const u8,
    age: u32,
    is_active: bool = true,
};

/// Login request model
pub const LoginRequest = struct {
    username: []const u8,
    password: []const u8,
    remember_me: bool = false,
};

/// Product search request
pub const SearchRequest = struct {
    query: ?[]const u8 = null,
    category: ?[]const u8 = null,
    min_price: ?f64 = null,
    max_price: ?f64 = null,
    page: u32 = 1,
    limit: u32 = 10,
};

// ====================================================================
// Example 2: Create handlers with auto-binding
// ====================================================================

/// Handler: POST /api/users
/// Request: POST /api/users?name=John&email=john@example.com&age=30
pub fn addUserHandler(ctx: *Context, user: User) !void {
    // The `user` parameter is automatically populated from:
    // - Query parameters: ?name=John&email=john@example.com&age=30
    // - Form data: POST form with these fields
    // - JSON body: {"name": "John", "email": "john@example.com", "age": 30}

    // You can now use the bound user struct directly
    std.log.info("Creating user: {s}, age: {}", .{user.name, user.age});

    try ctx.response.writeJSON(.{
        .status = "success",
        .user = user,
    });
}

/// Handler: POST /api/login
/// Request: POST /api/login?username=admin&password=secret&remember_me=true
pub fn loginHandler(ctx: *Context, req: LoginRequest) !void {
    // Validate credentials
    if (std.mem.eql(u8, req.username, "admin") and std.mem.eql(u8, req.password, "secret")) {
        // Create session or JWT token
        try ctx.response.writeJSON(.{
            .status = "success",
            .message = "Login successful",
            .remember_me = req.remember_me,
        });
    } else {
        try ctx.response.setStatus(http.Status.unauthorized);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Invalid username or password",
        });
    }
}

/// Handler: GET /api/products/search
/// Request: GET /api/products/search?query=phone&category=electronics&min_price=100&max_price=1000&page=1
pub fn searchHandler(ctx: *Context, search: SearchRequest) !void {
    // Use the bound search parameters
    std.log.info("Searching: query={?s}, category={?s}, price_range={?d}..{?d}", .{
        search.query, search.category, search.min_price, search.max_price,
    });

    // Simulate search results
    try ctx.response.writeJSON(.{
        .status = "success",
        .query = search.query,
        .results = &[_]std.json.Value{
            .{ .id = 1, .name = "iPhone", .price = 999.99 },
            .{ .id = 2, .name = "Samsung", .price = 899.99 },
        },
    });
}

// ====================================================================
// Example 3: Create bound handlers (one line!)
// ====================================================================

/// Automatically create a handler that binds parameters
pub const boundAddUserHandler = bind(addUserHandler);
pub const boundLoginHandler = bind(loginHandler);
pub const boundSearchHandler = bind(searchHandler);

// ====================================================================
// Example 4: Manual binding with validation
// ====================================================================

pub fn createUserHandler(ctx: *Context) !void {
    // Manual binding with custom validation
    var result = binder.bindRequest(User, ctx);
    defer result.deinit(ctx.allocator);

    if (result.has_errors) {
        try ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Validation failed",
            .errors = result.errors.items,
        });
        return;
    }

    // Additional custom validation
    const user = binder.getBoundValue(User, &result).?;
    if (user.age < 18) {
        try ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "User must be at least 18 years old",
        });
        return;
    }

    // Valid - create user
    try ctx.response.writeJSON(.{
        .status = "success",
        .user = user.*,
    });
}

// ====================================================================
// Example 5: JSON body binding
// ====================================================================

pub const UpdateUserRequest = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    age: ?u32 = null,
};

pub fn updateUserHandler(ctx: *Context) !void {
    // Bind from JSON body
    const update = binder.bindJSONBody(UpdateUserRequest, ctx) catch |err| {
        try ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Invalid JSON body",
            .error_val = @errorName(err),
        });
        return;
    };

    // Process update
    try ctx.response.writeJSON(.{
        .status = "success",
        .updated = update,
    });
}

// ====================================================================
// Example 6: Routing with bound handlers
// ====================================================================

pub fn setupRoutes(router: anytype) void {
    // Regular handlers
    // router.addRoute("POST", "/api/users", addUserHandler);

    // Auto-binding handlers (preferred)
    router.addRoute("POST", "/api/users", boundAddUserHandler);
    router.addRoute("POST", "/api/login", boundLoginHandler);
    router.addRoute("GET", "/api/products/search", boundSearchHandler);
    router.addRoute("POST", "/api/users/create", createUserHandler);
    router.addRoute("PUT", "/api/users/:id", updateUserHandler);
}

// ====================================================================
// Test example
// ====================================================================

test "binding example" {
    const allocator = std.testing.allocator;

    // Simulate a user from query params
    const user = User{
        .name = "John Doe",
        .email = "john@example.com",
        .age = 30,
    };

    try std.testing.expectEqualStrings("John Doe", user.name);
    try std.testing.expectEqual(@as(u32, 30), user.age);
}
