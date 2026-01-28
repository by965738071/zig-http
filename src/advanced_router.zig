const std = @import("std");

const http = std.http;
pub const Handler = *const fn (*Context) anyerror!void;
pub const Middleware = @import("middleware.zig").Middleware;
const Context = @import("context.zig").Context;


/// Regular expression route
pub const RegexRoute = struct {
    method: http.Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: std.ArrayList(*Middleware),
};



/// Route group with prefix
pub const RouteGroup = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    middlewares: std.ArrayList(*Middleware),
    routes: std.ArrayList(Route),

    pub const Route = struct {
        method: http.Method,
        path: []const u8,
        handler: Handler,
        middlewares: std.ArrayList(*Middleware),
        is_regex: bool,
    };

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8) RouteGroup {
        return .{
            .allocator = allocator,
            .prefix = allocator.dupe(u8, prefix) catch prefix,
            .middlewares = std.ArrayList(*Middleware).init(allocator),
            .routes = std.ArrayList(Route).init(allocator),
        };
    }

    pub fn deinit(group: *RouteGroup) void {
        group.allocator.free(group.prefix);
        group.middlewares.deinit();
        group.routes.deinit();
    }

    /// Add GET route
    pub fn get(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(.{
            .method = .GET,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(),
            .is_regex = false,
        });
    }

    /// Add POST route
    pub fn post(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(.{
            .method = .POST,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(),
            .is_regex = false,
        });
    }

    /// Add PUT route
    pub fn put(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(.{
            .method = .PUT,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(),
            .is_regex = false,
        });
    }

    /// Add DELETE route
    pub fn delete(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(.{
            .method = .DELETE,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(),
            .is_regex = false,
        });
    }

    /// Add regex route
    /// Note: Zig 0.16-dev does not have std.regex module yet
    /// This is a placeholder for future regex support
    pub fn addRegex(group: *RouteGroup, method: http.Method, pattern: []const u8, handler: Handler) !void {
        _ = group;
        _ = method;
        _ = pattern;
        _ = handler;
        @panic("Regex routes are not supported in Zig 0.16-dev yet (std.regex module not available)");
    }

    /// Add middleware to group
    pub fn use(group: *RouteGroup, middleware: *Middleware) !void {
        try group.middlewares.append(middleware);
    }

    /// Apply prefix to all routes
    pub fn applyPrefix(group: *RouteGroup) !void {
        for (group.routes.items) |*route| {
            const full_path = try std.fmt.allocPrint(group.allocator, "{s}{s}", .{ group.prefix, route.path });
            route.path = full_path;
        }
    }
};

/// Route validator
pub const RouteValidator = struct {
    allocator: std.mem.Allocator,
    validators: std.StringHashMap(*const fn ([]const u8) bool),

    pub fn init(allocator: std.mem.Allocator) RouteValidator {
        return .{
            .allocator = allocator,
            .validators = std.StringHashMap(*const fn ([]const u8) bool).init(allocator),
        };
    }

    pub fn deinit(validator: *RouteValidator) void {
        validator.validators.deinit();
    }

    /// Add validator for a parameter
    pub fn add(validator: *RouteValidator, param: []const u8, fn_ptr: *const fn ([]const u8) bool) !void {
        const param_copy = try validator.allocator.dupe(u8, param);
        try validator.validators.put(param_copy, fn_ptr);
    }

    /// Validate parameter
    pub fn validate(validator: RouteValidator, param: []const u8, value: []const u8) bool {
        if (validator.validators.get(param)) |fn_ptr| {
            return fn_ptr(value);
        }
        return true; // No validator, allow
    }
};

/// Common validators
pub const Validators = struct {
    pub fn isInt(value: []const u8) bool {
        return std.fmt.parseInt(i64, value, 10) == value.len;
    }

    pub fn isFloat(value: []const u8) bool {
        return std.fmt.parseFloat(f64, value) == value.len;
    }

    pub fn isEmail(value: []const u8) bool {
        if (std.mem.indexOf(u8, value, "@") == null) return false;
        if (std.mem.indexOf(u8, value, ".") == null) return false;
        return true; // Simplified validation
    }

    pub fn isAlphanumeric(value: []const u8) bool {
        for (value) |c| {
            if (!std.ascii.isAlphanumeric(c)) return false;
        }
        return true;
    }
};

/// Length validators that capture parameters
pub const LengthValidators = struct {
    min_len: usize = 0,
    max_len: usize = std.math.maxInt(usize),

    pub fn minLength(min: usize) LengthValidators {
        return .{ .min_len = min };
    }

    pub fn maxLength(max: usize) LengthValidators {
        return .{ .max_len = max };
    }

    pub fn validate(v: LengthValidators, value: []const u8) bool {
        return value.len >= v.min_len and value.len <= v.max_len;
    }
};
