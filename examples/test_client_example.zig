/// Example demonstrating the HTTP test client
const std = @import("std");
const HTTPClient = @import("http_client.zig").HTTPClient;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var client = try HTTPClient.init(allocator, io);
    defer client.deinit();

    // Set default headers
    try client.setDefaultHeader("User-Agent", "zig-http-test-client/1.0");

    std.log.info("HTTP Test Client Examples\n", .{});

    // Example 1: Simple GET request
    try testGetRequest(&client);

    // Example 2: POST JSON data
    try testPostJSON(&client);

    // Example 3: POST form data
    try testPostForm(&client);

    // Example 4: DELETE request
    try testDeleteRequest(&client);

    std.log.info("\nAll tests completed!", .{});
}

fn testGetRequest(client: *HTTPClient) !void {
    std.log.info("=== GET Request Test ===", .{});
    
    const response = try client.get("http://httpbin.org/get");
    defer response.deinit();

    std.log.info("Status: {d} {s}", .{ @intFromEnum(response.status), response.status.phrase() orelse "Unknown" });
    std.log.info("Content-Length: {d}", .{response.body.len});
    
    // Pretty print JSON response
    if (response.getHeader("Content-Type")) |ct| {
        if (std.mem.indexOf(u8, ct, "application/json") != null) {
            const parsed = try response.json();
            defer parsed.deinit();
            std.log.info("Response: {}", .{parsed.value});
        }
    }

    std.log.info("\n", .{});
}

fn testPostJSON(client: *HTTPClient) !void {
    std.log.info("=== POST JSON Test ===", .{});

    const json_data = 
        \\{
        \\  "name": "Test User",
        \\  "email": "test@example.com",
        \\  "age": 30
        \\}
    ;

    const response = try client.post("http://httpbin.org/post", json_data, "application/json");
    defer response.deinit();

    std.log.info("Status: {d} {s}", .{ @intFromEnum(response.status), response.status.phrase() orelse "Unknown" });
    
    // Parse and display response
    const parsed = try response.json();
    defer parsed.deinit();
    
    if (parsed.value.object.get("json")) |json_obj| {
        std.log.info("Sent JSON: {}", .{json_obj});
    }

    std.log.info("\n", .{});
}

fn testPostForm(client: *HTTPClient) !void {
    std.log.info("=== POST Form Test ===", .{});

    const form_data = "name=Test+User&email=test%40example.com&age=30";

    const response = try client.post(
        "http://httpbin.org/post", 
        form_data, 
        "application/x-www-form-urlencoded"
    );
    defer response.deinit();

    std.log.info("Status: {d} {s}", .{ @intFromEnum(response.status), response.status.phrase() orelse "Unknown" });
    
    const parsed = try response.json();
    defer parsed.deinit();
    
    if (parsed.value.object.get("form")) |form_obj| {
        std.log.info("Form data: {}", .{form_obj});
    }

    std.log.info("\n", .{});
}

fn testDeleteRequest(client: *HTTPClient) !void {
    std.log.info("=== DELETE Request Test ===", .{});

    const response = try client.delete("http://httpbin.org/delete");
    defer response.deinit();

    std.log.info("Status: {d} {s}", .{ @intFromEnum(response.status), response.status.phrase() orelse "Unknown" });
    std.log.info("Response length: {d} bytes", .{response.body.len});

    std.log.info("\n", .{});
}

/// Simple health check utility
pub fn healthCheck(url: []const u8) !bool {
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

    return @intFromEnum(response.status) >= 200 and @intFromEnum(response.status) < 300;
}
