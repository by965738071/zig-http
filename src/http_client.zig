const std = @import("std");
const http = std.http;
const Io = std.Io;

/// HTTP client for making HTTP requests
pub const HTTPClient = struct {
    allocator: std.mem.Allocator,
    io: Io,
    default_headers: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: Io) !HTTPClient {
        return .{
            .allocator = allocator,
            .io = io,
            .default_headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *HTTPClient) void {
        var it = self.default_headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.default_headers.deinit();
    }

    /// Set a default header for all requests
    pub fn setDefaultHeader(self: *HTTPClient, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        
        // Remove existing if any
        if (self.default_headers.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        
        try self.default_headers.put(name_copy, value_copy);
    }

    /// Perform HTTP GET request
    pub fn get(self: *HTTPClient, url: []const u8) !HTTPResponse {
        return self.request(.GET, url, null, null);
    }

    /// Perform HTTP POST request
    pub fn post(self: *HTTPClient, url: []const u8, body: ?[]const u8, content_type: ?[]const u8) !HTTPResponse {
        return self.request(.POST, url, body, content_type);
    }

    /// Perform HTTP PUT request
    pub fn put(self: *HTTPClient, url: []const u8, body: ?[]const u8, content_type: ?[]const u8) !HTTPResponse {
        return self.request(.PUT, url, body, content_type);
    }

    /// Perform HTTP DELETE request
    pub fn delete(self: *HTTPClient, url: []const u8) !HTTPResponse {
        return self.request(.DELETE, url, null, null);
    }

    /// Perform HTTP request
    pub fn request(
        self: *HTTPClient,
        method: http.Method,
        url: []const u8,
        body: ?[]const u8,
        content_type: ?[]const u8,
    ) !HTTPResponse {
        // Parse URL (simplified - assumes http://host:port/path)
        const parsed = try self.parseURL(url);
        
        // Connect to server
        const address = try std.net.Address.parseIp4(parsed.host, parsed.port);
        var stream = try address.connect(self.io);
        defer stream.close(self.io);

        // Create buffers
        var read_buffer: [8192]u8 = undefined;

        // Create HTTP client
        var http_client = http.Client{
            .allocator = self.allocator,
        };

        // Build request headers
        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer {
            for (headers.items) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            headers.deinit();
        }

        // Add default headers
        var header_it = self.default_headers.iterator();
        while (header_it.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(name);
            const value = try self.allocator.dupe(u8, entry.value_ptr.*);
            try headers.append(.{ .name = name, .value = value });
        }

        // Add content-type if body provided
        if (body != null) {
            if (content_type) |ct| {
                const name = try self.allocator.dupe(u8, "Content-Type");
                errdefer self.allocator.free(name);
                const value = try self.allocator.dupe(u8, ct);
                try headers.append(.{ .name = name, .value = value });
            }
        }

        // Make request
        const result = try http_client.request(
            method,
            try std.Uri.parse(url),
            .{ .server_header_buffer = &read_buffer },
            .{
                .headers = headers.items,
                .body = body orelse "",
            },
        );

        defer {
            result.deinit();
        }

        // Read response body
        var response_body = std.ArrayList(u8).init(self.allocator, {});
        defer response_body.deinit();

        const reader = result.reader();
        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try reader.readAll(&buffer);
            if (bytes_read == 0) break;
            try response_body.appendSlice(buffer[0..bytes_read]);
        }

        return HTTPResponse{
            .allocator = self.allocator,
            .status = result.status,
            .headers = try self.cloneHeaders(result.headers),
            .body = try response_body.toOwnedSlice(),
        };
    }

    /// Clone headers from HTTP response
    fn cloneHeaders(self: *HTTPClient, http_headers: std.http.HeaderList) !std.ArrayList(http.Header) {
        var headers = std.ArrayList(http.Header).init(self.allocator);
        
        var it = http_headers.iterator();
        while (it.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            const value = try self.allocator.dupe(u8, entry.value);
            errdefer self.allocator.free(value);
            try headers.append(.{ .name = name, .value = value });
        }

        return headers;
    }

    /// Simple URL parser (http://host:port/path)
    fn parseURL(self: *HTTPClient, url: []const u8) !struct { host: []const u8, port: u16, path: []const u8 } {
        _ = self;
        
        // Remove protocol
        const without_proto = if (std.mem.startsWith(u8, url, "http://"))
            url[7..]
        else if (std.mem.startsWith(u8, url, "https://"))
            url[8..]
        else
            url;

        // Find first '/' to split host and path
        const slash_idx = std.mem.indexOfScalar(u8, without_proto, '/') orelse without_proto.len;
        const host_part = without_proto[0..slash_idx];
        const path = if (slash_idx < without_proto.len)
            without_proto[slash_idx..]
        else
            "/";

        // Split host and port
        const colon_idx = std.mem.lastIndexOfScalar(u8, host_part, ':') orelse host_part.len;
        const host = host_part[0..colon_idx];
        const port = if (colon_idx < host_part.len)
            try std.fmt.parseInt(u16, host_part[colon_idx + 1 ..], 10)
        else
            80;

        return .{
            .host = host,
            .port = port,
            .path = path,
        };
    }
};

/// HTTP response
pub const HTTPResponse = struct {
    allocator: std.mem.Allocator,
    status: http.Status,
    headers: std.ArrayList(http.Header),
    body: []const u8,

    pub fn deinit(self: *HTTPResponse) void {
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    /// Get header value
    pub fn getHeader(self: HTTPResponse, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    /// Parse body as JSON
    pub fn json(self: HTTPResponse) !std.json.Value {
        return std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            self.body,
            .{ .ignore_unknown_fields = true },
        );
    }
};

/// Utility function to make a simple GET request
pub fn get(url: []const u8) ![]const u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var client = try HTTPClient.init(allocator, io);
    defer client.deinit();

    const response = try client.get(url);
    defer response.deinit();

    return allocator.dupe(u8, response.body);
}
