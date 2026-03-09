const std = @import("std");
const http = std.http;
const Context = @import("core/context.zig").Context;
const UploadTracker = @import("features/upload_progress.zig").UploadTracker;
const globals = @import("globals.zig");
const MultipartParser = @import("core/body_parser.zig").MultipartParser;

/// Handle POST /api/upload - file upload handler
pub fn handleUpload(ctx: *Context) !void {
    const content_type = ctx.getHeader("Content-Type") orelse "";
    const body = ctx.getBody();

    if (body.len == 0) {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "No file uploaded",
        });
        return;
    }

    if (std.mem.indexOf(u8, content_type, "multipart/form-data") == null) {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Content-Type must be multipart/form-data",
        });
        return;
    }

    const boundary = MultipartParser.extractBoundary(content_type) catch |err| {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Invalid multipart boundary",
            .error_val = @errorName(err),
        });
        return;
    };

    var parser = MultipartParser.init(ctx.allocator, boundary);
    defer parser.deinit();

    var form = parser.parse(body) catch |err| {
        ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Failed to parse multipart form",
            .error_val = @errorName(err),
        });
        return;
    };
    defer form.deinit();

    var uploaded_files = std.ArrayList([]const u8){};
    defer uploaded_files.deinit(ctx.allocator);

    var file_count: usize = 0;
    for (form.getAllFiles()) |*part| {
        if (part.filename != null) {
            file_count += 1;
            try uploaded_files.append(ctx.allocator, part.filename.?);
        }
    }

    ctx.response.setStatus(http.Status.ok);
    try ctx.response.writeJSON(.{
        .status = "success",
        .message = "Files uploaded successfully",
        .files = uploaded_files.items,
        .count = file_count,
    });
}

/// Handle GET /api/upload/progress - upload progress tracking
pub fn handleUploadProgress(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    if (globals.g_upload_tracker) |tracker| {
        const ids = try tracker.getActiveUploads();
        defer ctx.allocator.free(ids);
        try ctx.response.writeJSON(.{
            .active_uploads = ids.len,
            .upload_ids = ids,
            .message = "Upload tracker active",
        });
    } else {
        try ctx.response.writeJSON(.{ .message = "Upload tracker not initialized" });
    }
}
