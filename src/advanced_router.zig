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
        owns_path: bool = false, // Track if we need to free path
    };

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8) RouteGroup {
        return .{
            .allocator = allocator,
            .prefix = allocator.dupe(u8, prefix) catch prefix,
            .middlewares = std.ArrayList(*Middleware){},
            .routes = std.ArrayList(Route){},
        };
    }

    pub fn deinit(group: *RouteGroup) void {
        group.allocator.free(group.prefix);

        // Clean up middlewares and paths in routes
        for (group.routes.items) |*route| {
            route.middlewares.deinit(group.allocator);
            if (route.owns_path) {
                group.allocator.free(route.path);
            }
        }

        group.middlewares.deinit(group.allocator);
        group.routes.deinit(group.allocator);
    }

    /// Add GET route
    pub fn get(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(group.allocator,.{
            .method = .GET,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(group.allocator),
            .is_regex = false,
        });
    }

    /// Add POST route
    pub fn post(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(group.allocator,.{
            .method = .POST,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(group.allocator),
            .is_regex = false,
        });
    }

    /// Add PUT route
    pub fn put(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(group.allocator,.{
            .method = .PUT,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(group.allocator),
            .is_regex = false,
        });
    }

    /// Add DELETE route
    pub fn delete(group: *RouteGroup, path: []const u8, handler: Handler) !void {
        try group.routes.append(group.allocator,.{
            .method = .DELETE,
            .path = path,
            .handler = handler,
            .middlewares = try group.middlewares.clone(group.allocator),
            .is_regex = false,
        });
    }

    /// Add regex route (simplified pattern matching)
    /// Supports basic patterns:
    ///   {name}      - matches any segment (e.g., /users/{id})
    ///   {name:int}  - matches integers only
    ///   {name:alpha} - matches alphabetic characters only
    ///   *           - wildcard (matches any path)
    pub fn addRegex(group: *RouteGroup, method: http.Method, pattern: []const u8, handler: Handler) !void {
        try group.routes.append(group.allocator, .{
            .method = method,
            .path = try group.allocator.dupe(u8, pattern),
            .handler = handler,
            .middlewares = try group.middlewares.clone(group.allocator),
            .is_regex = true,
            .owns_path = true, // We dupe'd the pattern, so we own it
        });
    }

    /// Add middleware to group
    pub fn use(group: *RouteGroup, middleware: *Middleware) !void {
        try group.middlewares.append(group.allocator,middleware);
    }

    /// Apply prefix to all routes
    pub fn applyPrefix(group: *RouteGroup) !void {
        for (group.routes.items) |*route| {
            const full_path = try std.fmt.allocPrint(group.allocator, "{s}{s}", .{ group.prefix, route.path });
            route.path = full_path;
            route.owns_path = true; // Mark that we own this path and need to free it
        }
    }
};

/// Simple pattern matcher for routes (regex-lite)
pub const PatternMatcher = struct {
    /// Match a pattern against a path
    /// Patterns can contain:
    ///   {name}      - matches any segment
    ///   {name:int}  - matches integers
    ///   {name:alpha} - matches alphabetic characters
    ///   *           - wildcard
    pub fn matchPattern(pattern: []const u8, path: []const u8, params: ?*std.StringHashMap([]const u8)) !bool {
        // Handle wildcard
        if (std.mem.eql(u8, pattern, "*")) {
            return true;
        }

        // Split both pattern and path into segments
        var pattern_iter = std.mem.splitScalar(u8, pattern, '/');
        var path_iter = std.mem.splitScalar(u8, path, '/');

        while (true) {
            const pattern_seg = pattern_iter.next();
            const path_seg = path_iter.next();

            // Both exhausted - match
            if (pattern_seg == null and path_seg == null) {
                break;
            }

            // Only one exhausted - no match
            if (pattern_seg == null or path_seg == null) {
                return false;
            }

            if (try matchSegment(pattern_seg.?, path_seg.?, params)) {
                continue;
            }

            return false;
        }

        return true;
    }

    fn matchSegment(pattern: []const u8, segment: []const u8, params: ?*std.StringHashMap([]const u8)) !bool {
        // Check for parameter pattern {name} or {name:type}
        if (pattern.len > 2 and pattern[0] == '{' and pattern[pattern.len - 1] == '}') {
            const inner = pattern[1 .. pattern.len - 1];
            var type_iter = std.mem.splitScalar(u8, inner, ':');
            const param_name = type_iter.first();
            const param_type = type_iter.next() orelse "";

            // Validate type if specified
            if (param_type.len > 0) {
                if (std.mem.eql(u8, param_type, "int")) {
                    // Must be an integer
                    const parsed = std.fmt.parseInt(i64, segment, 10) catch return false;
                    _ = parsed;
                } else if (std.mem.eql(u8, param_type, "alpha")) {
                    // Must be alphabetic
                    for (segment) |c| {
                        if (!std.ascii.isAlphabetic(c)) return false;
                    }
                } else if (std.mem.eql(u8, param_type, "alnum")) {
                    // Must be alphanumeric
                    for (segment) |c| {
                        if (!std.ascii.isAlphanumeric(c)) return false;
                    }
                }
            }

            // Store parameter if params map provided
            if (params) |p| {
                const allocator = p.allocator;
                const name_copy = try allocator.dupe(u8, param_name);
                const value_copy = try allocator.dupe(u8, segment);
                try p.put(name_copy, value_copy);
            }

            return true;
        }

        // Exact match
        return std.mem.eql(u8, pattern, segment);
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
        var it = validator.validators.iterator();
        while (it.next()) |entry| {
            validator.allocator.free(entry.key_ptr.*);
        }
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
