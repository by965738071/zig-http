/// HTTP request handlers
/// This module contains all route handlers organized by category

// Basic handlers
pub const home = @import("home.zig").handleHome;
pub const health = @import("health.zig").handleHealth;

// API handlers
pub const api = @import("api.zig");
pub const upload = @import("upload.zig");
pub const session = @import("session.zig");

// Streaming handlers
pub const streaming = @import("streaming.zig");

// WebSocket handlers
pub const websocket = @import("websocket.zig");

// Static files handler
pub const static = @import("static.zig").handleStatic;
