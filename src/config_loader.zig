const std = @import("std");

/// Server configuration
pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_connections: u32 = 1000,
    request_timeout_ms: u32 = 30000,
    read_timeout_ms: u32 = 10000,
    write_timeout_ms: u32 = 10000,
    static_root: []const u8 = "./public",
    static_prefix: []const u8 = "/static",
    enable_logging: bool = true,
    log_level: []const u8 = "info",
    enable_compression: bool = false,
    enable_rate_limit: bool = false,
    rate_limit_max: u64 = 100,
    rate_limit_window: u64 = 60000,
};

/// Configuration loader
pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    env_vars: std.StringHashMap([]const u8),
    loaded_config: std.json.Value,

    pub fn init(allocator: std.mem.Allocator) ConfigLoader {
        // Load environment variables
        var env_vars = std.StringHashMap([]const u8).init(allocator);

        // Iterate through environment
        var env = std.process.EnvMap.init(allocator);
        defer env.deinit();

        var it = env.iterator();
        while (it.next()) |entry| {
            const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch continue;
            const value_copy = allocator.dupe(u8, entry.value_ptr.*) catch continue;
            env_vars.put(key_copy, value_copy) catch {};
        }

        return .{
            .allocator = allocator,
            .env_vars = env_vars,
            .loaded_config = .null,
        };
    }

    pub fn deinit(loader: *ConfigLoader) void {
        var it = loader.env_vars.iterator();
        while (it.next()) |entry| {
            loader.allocator.free(entry.key_ptr.*);
            loader.allocator.free(entry.value_ptr.*);
        }
        loader.env_vars.deinit();

        if (loader.loaded_config != .null) {
            loader.loaded_config.deinit();
        }
    }

    /// Load configuration from file
    pub fn loadFromFile(loader: *ConfigLoader, path: []const u8) !ServerConfig {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(loader.allocator, 10 * 1024 * 1024); // Max 10MB
        defer loader.allocator.free(content);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, loader.allocator, content, .{});
        loader.loaded_config = parsed;

        return loader.parseFromJson(parsed);
    }

    /// Load configuration from environment variables
    pub fn loadFromEnv(loader: *ConfigLoader) !ServerConfig {
        var config = ServerConfig{};

        // Override with environment variables
        if (loader.getEnv("SERVER_HOST")) |val| config.host = val;
        if (loader.getEnv("SERVER_PORT")) |val| {
            config.port = try std.fmt.parseInt(u16, val, 10);
        }
        if (loader.getEnv("MAX_CONNECTIONS")) |val| {
            config.max_connections = try std.fmt.parseInt(u32, val, 10);
        }
        if (loader.getEnv("REQUEST_TIMEOUT_MS")) |val| {
            config.request_timeout_ms = try std.fmt.parseInt(u32, val, 10);
        }
        if (loader.getEnv("STATIC_ROOT")) |val| config.static_root = val;
        if (loader.getEnv("STATIC_PREFIX")) |val| config.static_prefix = val;
        if (loader.getEnv("ENABLE_LOGGING")) |val| {
            config.enable_logging = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }
        if (loader.getEnv("LOG_LEVEL")) |val| config.log_level = val;

        return config;
    }

    /// Parse configuration from JSON
    fn parseFromJson(loader: *ConfigLoader, json: std.json.Value) ServerConfig {
        var config = ServerConfig{};

        if (json != .object) return config;

        const obj = json.object;

        if (obj.get("host")) |val| {
            if (val == .string) {
                config.host = val.string;
            }
        }

        if (obj.get("port")) |val| {
            if (val == .integer) {
                config.port = @intCast(val.integer);
            }
        }

        if (obj.get("max_connections")) |val| {
            if (val == .integer) {
                config.max_connections = @intCast(val.integer);
            }
        }

        if (obj.get("static_root")) |val| {
            if (val == .string) {
                config.static_root = val.string;
            }
        }

        if (obj.get("enable_rate_limit")) |val| {
            if (val == .bool) {
                config.enable_rate_limit = val.bool;
            }
        }

        if (obj.get("rate_limit_max")) |val| {
            if (val == .integer) {
                config.rate_limit_max = @intCast(val.integer);
            }
        }

        return config;
    }

    /// Get environment variable
    fn getEnv(loader: *ConfigLoader, key: []const u8) ?[]const u8 {
        return loader.env_vars.get(key);
    }

    /// Save configuration to file
    pub fn saveToFile(loader: *ConfigLoader, config: ServerConfig, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        // Write JSON config
        try writer.print(
            \\{{
            \\  "host": "{s}",
            \\  "port": {d},
            \\  "max_connections": {d},
            \\  "request_timeout_ms": {d},
            \\  "static_root": "{s}",
            \\  "static_prefix": "{s}",
            \\  "enable_logging": {},
            \\  "log_level": "{s}",
            \\  "enable_rate_limit": {},
            \\  "rate_limit_max": {d},
            \\  "rate_limit_window": {d}
            \\}}
        ,
            .{
                config.host,
                config.port,
                config.max_connections,
                config.request_timeout_ms,
                config.static_root,
                config.static_prefix,
                config.enable_logging,
                config.log_level,
                config.enable_rate_limit,
                config.rate_limit_max,
                config.rate_limit_window,
            }
        );
    }
};

test "config loader" {
    const allocator = std.testing.allocator;

    // Test environment loading
    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    const config = loader.loadFromEnv() catch return;
    try std.testing.expectEqual(@as(u16, 8080), config.port); // Default value
}
