/// Example demonstrating JSON and Form body parsing
const std = @import("std");
const HTTPServer = @import("http_server.zig").HTTPServer;
const Context = @import("context.zig").Context;
const http = std.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("Body Parser Example starting on {s}:{d}", .{ "127.0.0.1", 8081 });

    var server = try HTTPServer.init(allocator, .{
        .port = 8081,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Add route handlers for testing
    server.get("/api/json", handleJSON);
    server.post("/api/form", handleForm);
    server.post("/api/upload", handleUpload);

    try server.start(io);
}

/// Handle JSON POST request
fn handleJSON(ctx: *Context) !void {
    const json_val = ctx.getJSON() orelse {
        try ctx.err(http.Status.bad_request, "Invalid JSON");
        return;
    };

    std.log.info("Received JSON: {}", .{json_val});
    
    // Echo back the JSON
    try ctx.json(.{ 
        .received = json_val,
        .message = "JSON parsed successfully"
    });
}

/// Handle URL-encoded form POST request
fn handleForm(ctx: *Context) !void {
    const form = ctx.getForm() orelse {
        try ctx.err(http.Status.bad_request, "Invalid form");
        return;
    };

    std.log.info("Received form data:");

    // Log all form fields
    var it = form.fields.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .single => |value| {
                std.log.info("  {s} = {s}", .{ entry.key_ptr.*, value });
            },
            .multiple => |list| {
                std.log.info("  {s} (multiple):", .{ entry.key_ptr.* });
                for (list.items) |v| {
                    std.log.info("    - {s}", .{ v });
                }
            },
        }
    }
}

/// Handle file upload (multipart/form-data not yet implemented)
fn handleUpload(ctx: *Context) !void {
    const multipart = ctx.getMultipart() orelse {
        try ctx.err(http.Status.bad_request, "No multipart data found");
        return;
    };

    var result = std.StringHashMap([]const u8).init(ctx.allocator);
    defer {
        var it = result.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            ctx.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }

    try result.put("status", "Received multipart data");
    try result.put("files_count", try std.fmt.allocPrint(ctx.allocator, "{d}", .{multipart.parts.items.len}));

    const files = multipart.getAllFiles();
    try result.put("file_names", try std.fmt.allocPrint(ctx.allocator, "{s}", .{
        if (files.len > 0) files[0].filename orelse "unknown" else "none"
    }));

    try ctx.json(result);
}
