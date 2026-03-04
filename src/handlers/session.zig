const std = @import("std");
const http = std.http;
const Context = @import("../core/context.zig").Context;
const SessionManager = @import("../session.zig").SessionManager;
const globals = @import("globals.zig");

/// Handle GET /api/session - session management
pub fn handleSession(ctx: *Context) !void {
    ctx.response.setStatus(http.Status.ok);
    try ctx.response.setHeader("Content-Type", "application/json");

    if (globals.g_session_manager) |sm| {
        // Try to read session_id from cookie
        const jar = ctx.getCookieJar();
        const session_id_opt = jar.get("session_id");

        const session = try sm.get(session_id_opt);

        // Set visit count
        const visits_str = session.get("visits") orelse "0";
        const visits = std.fmt.parseInt(u32, visits_str, 10) catch 0;
        var buf: [16]u8 = undefined;
        const new_visits = std.fmt.bufPrint(&buf, "{d}", .{visits + 1}) catch "1";
        try session.set("visits", new_visits);
        try sm.save(session);

        // Set session cookie
        const cookie = try sm.createCookie(session.id);
        try ctx.setCookie(cookie);

        try ctx.response.writeJSON(.{
            .session_id = session.id,
            .visits = visits + 1,
            .message = "Session active",
        });
    } else {
        try ctx.response.writeJSON(.{
            .session_id = "unavailable",
            .message = "Session manager not initialized",
        });
    }
}
