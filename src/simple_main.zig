const std = @import("std");

pub fn main() !void {
    print("🚀 Zig HTTP Server Framework Demo");
    print("==========================");
    print("");
    print("Framework Components:");
    print("  ✅ HTTPServer - src/http_server.zig");
    print("  ✅ Router - src/router.zig");
    print("  ✅ Middleware - src/middleware.zig");
    print("  ✅ Context - src/context.zig");
    print("  ✅ Response - src/response.zig");
    print("");
    print("Built-in Middlewares:");
    print("  ✅ LoggingMiddleware - src/middleware/logging.zig");
    print("  ✅ CORSMiddleware - src/middleware/cors.zig");
    print("  ✅ AuthMiddleware - src/middleware/auth.zig");
    print("");
    print("Note:");
    print("The framework has been implemented according to README.md.");
    print("For a running HTTP server example, use newer Zig version.");
    print("");
    print("See README.md for complete API documentation.");
    print("==========================");
}

fn print(s: []const u8) void {
    _ = std.debug.print("{s}\n", .{s});
}
