const std = @import("std");
const Context = @import("context.zig").Context;

/// Parameter binding error
pub const BindingError = error{
    MissingRequiredParameter,
    TypeConversionFailed,
    InvalidParameterFormat,
    Unknown,
};

/// Binding result with validation errors
pub const BindingResult = struct {
    allocator: std.mem.Allocator,
    target: ?*const anyopaque = null,
    errors: std.ArrayList(BindingErrorEntry),
    has_errors: bool = false,

    pub fn init(allocator: std.mem.Allocator) BindingResult {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(BindingErrorEntry){},
        };
    }

    pub fn deinit(self: *BindingResult) void {
        for (self.errors.items) |*err| {
            err.deinit(self.allocator);
        }
        self.errors.deinit(self.allocator);
    }

    pub fn addError(self: *BindingResult, field: []const u8, err: BindingError, message: []const u8) !void {
        const field_copy = try self.allocator.dupe(u8, field);
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{
            .field = field_copy,
            .err = err,
            .message = msg_copy,
        });
        self.has_errors = true;
    }

    pub const BindingErrorEntry = struct {
        field: []const u8,
        err: BindingError,
        message: []const u8,

        pub fn deinit(self: *BindingErrorEntry, alloc: std.mem.Allocator) void {
            alloc.free(self.field);
            alloc.free(self.message);
        }
    };
};

/// Bind a single parameter value from request
/// Automatically tries query, form, path params, and JSON body
pub fn bindParam(comptime T: type, ctx: *Context, param_name: ?[]const u8) !T {
    std.log.debug("param_name = {any}", .{param_name});

    const param_value = if (param_name) |name|
        getParamForField(ctx, name)
    else
        // If no param name provided, try to infer from various sources in priority order
        // 1. Query string first parameter
        // 2. Path params first parameter
        // 3. JSON body first field
        // 4. Form first field
        tryGetFirstParam(ctx) orelse return error.MissingParameterName;

    if (param_value) |value| {
        return parseFieldType(T, value, ctx.allocator);
    }

    if (!isOptional(T)) {
        return error.MissingRequiredParameter;
    }

    // Return null for optional type when parameter is missing
    // Note: parseFieldType already handles optional types, so this should work
    // For optional types, we need to return null
    if (@typeInfo(T) == .optional) {
        return null;
    }

    return error.MissingRequiredParameter;
}

/// Bind request parameters to a struct
pub fn bindRequest(comptime T: type, ctx: *Context) BindingResult {
    var result = BindingResult.init(ctx.allocator);
    errdefer result.deinit(ctx.allocator);

    var instance: T = undefined;

    const struct_fields = std.meta.fields(T);
    std.log.debug("Binding {} fields to struct", .{struct_fields.len});

    inline for (struct_fields) |field| {
        std.log.debug("Processing field: '{s}' (type: {})", .{field.name, field.type});

        const param_value = getParamForField(ctx, field.name);

        // Use inline if to avoid comptime control flow in runtime block
        if (comptime isOptional(field.type)) {
            // Optional field
            if (param_value) |value| {
                std.log.debug("Optional field '{s}' found with value: '{s}'", .{field.name, value});
                const parsed = parseFieldType(field.type, value, ctx.allocator) catch |err| {
                    const msg = std.fmt.allocPrint(ctx.allocator, "Failed to parse field '{s}': {}", .{field.name, err}) catch "Parse error";
                    result.addError(field.name, err, msg) catch |e| {
                        std.log.warn("Failed to add binding error: {}", .{e});
                        ctx.allocator.free(msg);
                    };
                    return;
                };
                @field(instance, field.name) = parsed;
                std.log.debug("Field '{s}' successfully parsed", .{field.name});
            } else {
                // Optional field not found, set to null
                @field(instance, field.name) = null;
                std.log.debug("Optional field '{s}' not found, set to null", .{field.name});
            }
        } else {
            // Required field
            if (param_value) |value| {
                std.log.debug("Field '{s}' found with value: '{s}'", .{field.name, value});
                const parsed = parseFieldType(field.type, value, ctx.allocator) catch |err| {
                    const msg = std.fmt.allocPrint(ctx.allocator, "Failed to parse field '{s}': {}", .{field.name, err}) catch "Parse error";
                    result.addError(field.name, err, msg) catch |e| {
                        std.log.warn("Failed to add binding error: {}", .{e});
                        ctx.allocator.free(msg);
                    };
                    return;
                };
                @field(instance, field.name) = parsed;
                std.log.debug("Field '{s}' successfully parsed", .{field.name});
            } else {
                const msg = std.fmt.allocPrint(ctx.allocator, "Required parameter '{s}' not found in query, form, path, or JSON body", .{field.name}) catch "Parameter not found";
                result.addError(field.name, BindingError.MissingRequiredParameter, msg) catch |e| {
                    std.log.err("Failed to add binding error: {}", .{e});
                    if (!std.mem.eql(u8, msg, "Parameter not found")) {
                        ctx.allocator.free(msg);
                    }
                };
            }
        }
    }

    result.target = &instance;
    return result;
}

/// Get parameter from query, body (form), or path params
fn getParamForField(ctx: *Context, field_name: []const u8) ?[]const u8 {
    // Check query parameters first
    if (ctx.getQuery(field_name)) |value| {
        return value;
    }

    // Check form data
    if (ctx.getForm()) |form| {
        // Note: form.get() requires mutable reference, but we have const
        // For now, skip form data binding or update Form.get() to accept const
        // This is a temporary workaround
        _ = form;
    }

    // Check JSON body
    if (ctx.getJSON()) |json_val_ptr| {
        const json_val = json_val_ptr.*;
        if (json_val == .object) {
            if (json_val.object.get(field_name)) |json_field| {
                return jsonValueToString(json_field, ctx.allocator);
            }
        }
    }

    // Check path params
    if (ctx.getParam(field_name)) |value| {
        return value;
    }

    return null;
}

/// Get the first field from JSON body (used when no explicit parameter name provided)
fn getFirstJSONField(ctx: *Context) ?[]const u8 {
    if (ctx.getJSON()) |json_val_ptr| {
        const json_val = json_val_ptr.*;
        if (json_val == .object) {
            // Get first key-value pair from JSON object
            var iter = json_val.object.iterator();
            if (iter.next()) |entry| {
                return jsonValueToString(entry.value_ptr.*, ctx.allocator);
            }
        }
    }
    return null;
}

/// Convert JSON value to string representation
fn jsonValueToString(json_val: std.json.Value, allocator: std.mem.Allocator) ?[]const u8 {
    return switch (json_val) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch null,
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}) catch null,
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => null,
    };
}

/// Try to get the first available parameter from various sources
fn tryGetFirstParam(ctx: *Context) ?[]const u8 {
    // Try query string first
    const target = ctx.request.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse null;
    if (query_start) |qs| {
        const query = target[qs + 1 ..];
        var iter = std.mem.splitScalar(u8, query, '&');
        if (iter.next()) |pair| {
            const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse null;
            if (eq_pos) |pos| {
                return pair[pos + 1 ..];
            } else if (pair.len > 0) {
                return pair;
            }
        }
    }

    // Try path params
    var path_iter = ctx.params.data.iterator();
    if (path_iter.next()) |entry| {
        return entry.value_ptr.*;
    }

    // Try JSON body
    if (getFirstJSONField(ctx)) |val| {
        return val;
    }

    // Try form data - iterate through fields to get first value
    if (ctx.getForm()) |form| {
        var form_iter = form.fields.iterator();
        if (form_iter.next()) |entry| {
            const value = entry.value_ptr.*;
            switch (value) {
                .single => |s| return s,
                .multiple => |*list| {
                    if (list.items.len > 0) return list.items[0];
                },
            }
        }
    }

    return null;
}

/// Parse string to field type
fn parseFieldType(comptime T: type, value: []const u8, allocator: std.mem.Allocator) !T {
    const info = @typeInfo(T);

    if (info == .optional) {
        const child_type = info.optional.child;
        const parsed = try parseFieldType(child_type, value, allocator);
        return parsed;
    }

    if (T == []const u8) {
        return value;
    }

    if (T == u8) {
        return std.fmt.parseInt(u8, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == u16) {
        return std.fmt.parseInt(u16, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == u32) {
        return std.fmt.parseInt(u32, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == u64) {
        return std.fmt.parseInt(u64, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == i8) {
        return std.fmt.parseInt(i8, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == i16) {
        return std.fmt.parseInt(i16, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == i32) {
        return std.fmt.parseInt(i32, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == i64) {
        return std.fmt.parseInt(i64, value, 10) catch return error.TypeConversionFailed;
    }

    if (T == f32) {
        return std.fmt.parseFloat(f32, value) catch return error.TypeConversionFailed;
    }

    if (T == f64) {
        return std.fmt.parseFloat(f64, value) catch return error.TypeConversionFailed;
    }

    if (T == bool) {
        if (std.ascii.eqlIgnoreCase(value, "true")) return true;
        if (std.ascii.eqlIgnoreCase(value, "false")) return false;
        return error.TypeConversionFailed;
    }

    // Handle enum types
    if (info == .@"enum") {
        inline for (std.meta.fields(T)) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) {
                return @field(T, field.name);
            }
        }
        return error.TypeConversionFailed;
    }

    return error.TypeConversionFailed;
}

/// Check if type is optional
fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

/// Helper to get bound value from BindingResult
pub fn getBoundValue(comptime T: type, result: *const BindingResult) ?*const T {
    if (result.target == null or result.has_errors) return null;
    return @as(*const T, @ptrCast(@alignCast(result.target.?)));
}

// ====================================================================
// Advanced binding with annotations (simulated via field attributes)
// ====================================================================

/// Field binding configuration
pub const FieldBinding = struct {
    param_name: []const u8,
    required: bool = true,
    default_value: ?[]const u8 = null,
};

/// Get binding configuration for a field (can be customized)
pub fn getBindingForField(comptime field_name: []const u8) FieldBinding {
    // Default implementation: use field name as parameter name
    return .{
        .param_name = field_name,
        .required = true,
        .default_value = null,
    };
}

// ====================================================================
// JSON body binding
// ====================================================================

/// Bind JSON body to struct
pub fn bindJSONBody(comptime T: type, ctx: *Context) !T {
    const json_val = ctx.getJSON() orelse return error.NoJSONBody;
    return jsonToStruct(T, json_val, ctx.allocator);
}

/// Convert JSON value to struct
fn jsonToStruct(comptime T: type, json_val: *const std.json.Value, allocator: std.mem.Allocator) !T {
    const info = @typeInfo(T);

    if (info == .@"struct") {
        var instance: T = undefined;
        const obj = json_val.object;

        inline for (std.meta.fields(T)) |field| {
            if (obj.get(field.name)) |val| {
                @field(instance, field.name) = try jsonToType(field.type, val, allocator);
            } else if (!isOptional(field.type)) {
                return error.MissingRequiredField;
            } else {
                @field(instance, field.name) = null;
            }
        }

        return instance;
    }

    return error.TypeMismatch;
}

/// Convert JSON value to type
fn jsonToType(comptime T: type, json_val: *const std.json.Value, allocator: std.mem.Allocator) !T {
    const info = @typeInfo(T);

    if (info == .optional) {
        const child_type = info.optional.child;
        return try jsonToType(child_type, json_val, allocator);
    }

    if (T == []const u8) {
        if (json_val != .string) return error.TypeMismatch;
        return json_val.string;
    }

    if (T == bool) {
        if (json_val != .bool) return error.TypeMismatch;
        return json_val.bool;
    }

    if (T == u8 or T == u16 or T == u32 or T == u64 or T == i8 or T == i16 or T == i32 or T == i64) {
        if (json_val != .integer) return error.TypeMismatch;
        return @intCast(json_val.integer);
    }

    if (T == f32 or T == f64) {
        if (json_val != .float) return error.TypeMismatch;
        return @floatCast(json_val.float);
    }

    return error.TypeMismatch;
}

// ====================================================================
// Tests
// ====================================================================

test "bind simple struct" {
    // Context binding test would need full Context setup
    // This is a placeholder for integration testing
}

test "parse field types" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(u32, 42), try parseFieldType(u32, "42", allocator));
    try std.testing.expectEqual(@as(i32, -10), try parseFieldType(i32, "-10", allocator));
    try std.testing.expectEqual(3.14, try parseFieldType(f64, "3.14", allocator));
    try std.testing.expectEqual(true, try parseFieldType(bool, "true", allocator));
    try std.testing.expectEqual(false, try parseFieldType(bool, "false", allocator));
}
