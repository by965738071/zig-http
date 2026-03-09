const std = @import("std");
const http = std.http;
const Context = @import("core/context.zig").Context;

/// Handle static file requests
/// This handler is kept for compatibility but the static server
/// is invoked in handleRequest before route matching
pub fn handleStatic(ctx: *Context) !void {
    if (ctx.server.static_server) |static_srv| {
        _ = try static_srv.handle(ctx);
    } else {
        ctx.response.setStatus(http.Status.not_found);
        try ctx.err(http.Status.internal_server_error, "Static server not configured");
    }
}
