const std = @import("std");
const http = std.http;
const Context = @import("core/context.zig").Context;

/// Health check endpoint
pub fn handleHealth(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");
    try ctx.response.writeJSON(.{
        .status = "healthy",
        .server = "Zig HTTP Server",
        .version = "0.16-dev",
        .uptime = "running",
    });
}
