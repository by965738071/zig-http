# Parameter Binding Examples

This document demonstrates how to use struct-based parameter binding in the Zig HTTP server.

## Overview

The parameter binding system automatically extracts parameters from multiple sources:
- Query string (`?name=value`)
- Form data (application/x-www-form-urlencoded)
- JSON body (application/json)
- Path parameters (`/users/:id`)

## Basic Usage

### Single Parameter

```zig
const std = @import("std");
const Context = @import("core/context.zig").Context;

// Define request struct
pub const HelloRequest = struct {
    name: []const u8,
};

// Handler with parameter binding
pub fn handleHello(ctx: *Context) !void {
    const data = ctx.bindOrError(HelloRequest) catch |err| {
        // Error response is automatically set by bindOrError
        return err;
    };

    try ctx.response.writeJSON(.{
        .message = "Hello, {s}!",
        .name = data.name,
    });
}
```

### Multiple Parameters

```zig
// Define request struct with multiple fields
pub const UserRequest = struct {
    username: []const u8,
    age: u32,
    email: []const u8,
};

pub fn handleCreateUser(ctx: *Context) !void {
    const data = ctx.bindOrError(UserRequest) catch return;

    try ctx.response.writeJSON(.{
        .status = "success",
        .user = data,
    });
}
```

### Optional Parameters

```zig
// Use optional types for non-required fields
pub const SearchRequest = struct {
    query: []const u8,
    page: ?u32 = null,  // Optional with default
    limit: ?u32 = null, // Optional with default
};

pub fn handleSearch(ctx: *Context) !void {
    const data = ctx.bindOrError(SearchRequest) catch return;

    const page = data.page orelse 1;
    const limit = data.limit orelse 10;

    try ctx.response.writeJSON(.{
        .query = data.query,
        .page = page,
        .limit = limit,
    });
}
```

## Supported Types

### Primitive Types

```zig
pub const ExampleRequest = struct {
    // String types
    name: []const u8,

    // Integer types
    age: u32,
    count: i64,
    flag: u8,

    // Float types
    price: f64,
    rating: f32,

    // Boolean type
    active: bool,
};
```

### Enum Types

```zig
// Define enum
pub const Status = enum {
    pending,
    active,
    completed,
};

pub const TaskRequest = struct {
    title: []const u8,
    status: Status,  // Will be parsed from string: "pending", "active", "completed"
};
```

## Advanced Usage

### JSON Body Binding

For pure JSON requests, you can use `bindJSON` for better performance:

```zig
pub const CreateUserRequest = struct {
    username: []const u8,
    email: []const u8,
    age: u32,
};

pub fn handleCreateUser(ctx: *Context) !void {
    // Only binds from JSON body (not query/form/path)
    const data = try ctx.bindJSON(CreateUserRequest);

    try ctx.response.writeJSON(.{
        .status = "success",
        .user = data,
    });
}
```

### Mixed Parameter Sources

```zig
pub const ProductRequest = struct {
    // From JSON body
    name: []const u8,
    price: f64,

    // From query string
    category: []const u8,

    // From path parameter (/products/:id)
    id: []const u8,
};
```

## Error Handling

### Custom Error Response

```zig
pub fn handleCustom(ctx: *Context) !void {
    var result = ctx.bind(CustomRequest);
    defer result.deinit(ctx.allocator);

    if (result.has_errors) {
        // Custom error handling
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Validation failed",
            .errors = result.errors.items,
        });
        return error.ValidationFailed;
    }

    const data = binder.getBoundValue(CustomRequest, &result).?;
    // Process data...
}
```

### Validation Example

```zig
pub const RegisterRequest = struct {
    username: []const u8,
    email: []const u8,
    password: []const u8,
};

pub fn handleRegister(ctx: *Context) !void {
    const data = ctx.bindOrError(RegisterRequest) catch return;

    // Custom validation
    if (data.username.len < 3) {
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Username must be at least 3 characters",
        });
        return error.ValidationError;
    }

    if (!std.mem.contains(u8, data.email, "@")) {
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Invalid email format",
        });
        return error.ValidationError;
    }

    // Process registration...
}
```

## Complete Examples

### Example 1: RESTful API Endpoint

```zig
const std = @import("std");
const Context = @import("core/context.zig").Context;

pub const CreateTodoRequest = struct {
    title: []const u8,
    description: []const u8,
    priority: u32 = 0,  // Default value
};

pub fn handleCreateTodo(ctx: *Context) !void {
    const data = ctx.bindOrError(CreateTodoRequest) catch return;

    // Validate
    if (data.title.len == 0) {
        ctx.response.setStatus(std.http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Title is required",
        });
        return error.ValidationError;
    }

    // Create todo...
    const todo_id = "12345";

    ctx.response.setStatus(std.http.Status.created);
    try ctx.response.writeJSON(.{
        .status = "success",
        .data = .{
            .id = todo_id,
            .title = data.title,
            .description = data.description,
            .priority = data.priority,
        },
    });
}
```

### Example 2: Search API with Pagination

```zig
pub const SearchQuery = struct {
    q: []const u8,          // Query string
    category: ?[]const u8 = null,  // Optional filter
    page: ?u32 = null,     // Optional page number
    limit: ?u32 = null,    // Optional limit
};

pub fn handleSearch(ctx: *Context) !void {
    const query = ctx.bindOrError(SearchQuery) catch return;

    const page = query.page orelse 1;
    const limit = query.limit orelse 20;

    // Perform search...
    const results = [][]const u8{};

    try ctx.response.writeJSON(.{
        .status = "success",
        .query = query.q,
        .category = query.category,
        .page = page,
        .limit = limit,
        .total = results.len,
        .results = results,
    });
}
```

### Example 3: Update with Path Parameter

```zig
pub const UpdateUserRequest = struct {
    id: []const u8,        // From path: /users/:id
    username: []const u8,   // From JSON body
    email: []const u8,      // From JSON body
};

pub fn handleUpdateUser(ctx: *Context) !void {
    const data = ctx.bindOrError(UpdateUserRequest) catch return;

    // Update user...
    try ctx.response.writeJSON(.{
        .status = "success",
        .message = "User updated",
        .user_id = data.id,
    });
}
```

## Testing

### Test with curl

```bash
# Query parameters
curl "http://localhost:8080/search?q=zig&page=1&limit=10"

# Form data
curl -X POST -d "username=john&age=25" http://localhost:8080/users

# JSON body
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"title":"Buy groceries","priority":1}' \
  http://localhost:8080/todos
```

## Best Practices

1. **Define request structs at module level** for reusability
2. **Use descriptive field names** that match API contract
3. **Use optional types** for non-required fields
4. **Provide default values** where appropriate
5. **Add validation** in handlers after binding
6. **Return detailed error messages** for debugging

## Migration from Old API

### Before (Single parameter binding)
```zig
pub fn handleSubmit(ctx: *Context, abc: []const u8) !void {
    try ctx.response.writeJSON(.{
        .param = abc,
    });
}
```

### After (Struct-based binding)
```zig
pub const SubmitRequest = struct {
    abc: []const u8,
};

pub fn handleSubmit(ctx: *Context) !void {
    const data = ctx.bindOrError(SubmitRequest) catch return;
    try ctx.response.writeJSON(.{
        .param = data.abc,
    });
}
```

## Benefits of Struct-Based Binding

- ✅ Type safety at compile time
- ✅ Clear API contract
- ✅ Automatic validation
- ✅ Better code organization
- ✅ Easier testing
- ✅ Support for complex nested structures
- ✅ Consistent error handling
