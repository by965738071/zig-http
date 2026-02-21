const std = @import("std");
const http = std.http;

const Response = @import("response.zig").Response;
const ParamList = @import("types.zig").ParamList;
const HTTPServer = @import("http_server.zig").HTTPServer;
const BodyParser = @import("body_parser.zig").BodyParser;
const MultipartParser = @import("multipart.zig").MultipartParser;
const MultipartForm = @import("multipart.zig").MultipartForm;
const CookieJar = @import("cookie.zig").CookieJar;
const Cookie = @import("cookie.zig").Cookie;
const Session = @import("session.zig").Session;
const SessionManager = @import("session.zig").SessionManager;
const utils = @import("utils.zig");

pub const Context = struct {
    server: *HTTPServer,
    request: *http.Server.Request,
    response: *Response,
    params: ParamList,
    state: std.StringHashMap(*anyopaque),
    body_parser: ?BodyParser,
    body_data: ?[]u8,
    multipart_form: ?*MultipartForm,
    cookie_jar: ?CookieJar,
    session: ?Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    request_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, server: *HTTPServer, request: *http.Server.Request, response: *Response, io: std.Io) !Context {
        const request_id = utils.generateRequestId(allocator, io) catch |gen_err| blk: {
            std.log.warn("Failed to generate request ID: {}", .{gen_err});
            break :blk try allocator.dupe(u8, "unknown");
        };
        return .{
            .server = server,
            .request = request,
            .response = response,
            .params = ParamList.init(allocator),
            .state = std.StringHashMap(*anyopaque).init(allocator),
            .body_parser = null,
            .body_data = null,
            .multipart_form = null,
            .cookie_jar = null,
            .session = null,
            .allocator = allocator,
            .io = io,
            .request_id = request_id,
        };
    }

    pub fn deinit(ctx: *Context) void {
        // Deinit body parser if present
        if (ctx.body_parser) |*parser| {
            parser.deinit();
            ctx.body_parser = null;
        }

        // If we stored a heap-allocated multipart form, deinit and destroy it
        if (ctx.multipart_form) |form_ptr| {
            form_ptr.deinit();
            ctx.allocator.destroy(form_ptr);
            ctx.multipart_form = null;
        }

        // Free body data buffer if ownership was transferred here
        if (ctx.body_data) |b| {
            ctx.allocator.free(b);
            ctx.body_data = null;
        }

        // Free request ID if allocated
        if (ctx.request_id) |rid| {
            ctx.allocator.free(rid);
            ctx.request_id = null;
        }

        // Cookie jar and session are stored inline (if present) — deinit them
        if (ctx.cookie_jar) |*jar| {
            jar.deinit();
            ctx.cookie_jar = null;
        }
        if (ctx.session) |*sess| {
            sess.deinit();
            ctx.session = null;
        }

        ctx.params.deinit();
        ctx.state.deinit();
    }

    /// Get request ID for tracing
    pub fn getRequestId(ctx: Context) ?[]const u8 {
        return ctx.request_id;
    }

    pub fn getParam(ctx: Context, name: []const u8) ?[]const u8 {
        return ctx.params.get(name);
    }

    /// Get query parameter from URL query string
    pub fn getQuery(ctx: *Context, name: []const u8) ?[]const u8 {
        // Parse query string from request.target
        const target = ctx.request.head.target;
        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
        const query = target[query_start + 1 ..];

        var iter = std.mem.splitScalar(u8, query, '&');
        while (iter.next()) |pair| {
            const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, name)) {
                return value;
            }
        }
        return null;
    }

    /// Get all query parameters as a HashMap
    pub fn getAllQueries(ctx: *Context) !std.StringHashMap([]const u8) {
        const target = ctx.request.head.target;
        var result = std.StringHashMap([]const u8).init(ctx.allocator);
        errdefer result.deinit();

        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return result;
        const query = target[query_start + 1 ..];

        var iter = std.mem.splitScalar(u8, query, '&');
        while (iter.next()) |pair| {
            if (pair.len == 0) continue;

            const eq_pos = std.mem.indexOfScalar(u8, pair, '=');
            if (eq_pos) |pos| {
                const key = pair[0..pos];
                const value = pair[pos + 1 ..];
                const key_copy = try ctx.allocator.dupe(u8, key);
                errdefer ctx.allocator.free(key_copy);
                const value_copy = try ctx.allocator.dupe(u8, value);
                try result.put(key_copy, value_copy);
            } else {
                const key_copy = try ctx.allocator.dupe(u8, pair);
                try result.put(key_copy, "");
            }
        }

        return result;
    }

    /// Get request header by name (case-insensitive)
    pub fn getHeader(ctx: *Context, name: []const u8) ?[]const u8 {
        var it = ctx.request.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }

    /// Get all headers as a HashMap
    pub fn getAllHeaders(ctx: *Context) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(ctx.allocator);
        errdefer result.deinit();

        var it = ctx.request.iterateHeaders();
        while (it.next()) |header| {
            const key_copy = try ctx.allocator.dupe(u8, header.name);
            errdefer ctx.allocator.free(key_copy);
            const value_copy = try ctx.allocator.dupe(u8, header.value);
            try result.put(key_copy, value_copy);
        }

        return result;
    }

    pub fn setState(ctx: *Context, key: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        const ptr = try ctx.allocator.create(T);
        ptr.* = value;

        const key_copy = try ctx.allocator.dupe(u8, key);
        try ctx.state.put(key_copy, @ptrCast(ptr));
    }

    pub fn getState(ctx: Context, key: []const u8) ?*anyopaque {
        return ctx.state.get(key);
    }

    /// Parse and return JSON body
    pub fn json(ctx: *Context, value: anytype) !void {
        try ctx.response.writeJSON(value);
    }

    /// Get parsed JSON from request body
    pub fn getJSON(ctx: *Context) ?*const std.json.Value {
        if (ctx.body_parser) |parser| {
            return parser.getJSON();
        }
        return null;
    }

    /// Get parsed form data from request body
    pub fn getForm(ctx: *Context) ?*const BodyParser.Form {
        if (ctx.body_parser) |parser| {
            return parser.getForm();
        }
        return null;
    }

    /// Get raw body data
    pub fn getBody(ctx: *Context) []const u8 {
        if (ctx.body_data) |d| return @as([]const u8, d);
        return &.{};
    }

    /// Get multipart form data
    pub fn getMultipart(ctx: *Context) ?*const MultipartForm {
        if (ctx.multipart_form) |*form| {
            return form;
        }

        // Try to parse multipart if not already parsed
        const content_type = ctx.getHeader("Content-Type") orelse return null;
        if (std.mem.indexOf(u8, content_type, "multipart/form-data") == null) {
            return null;
        }

        // Parse multipart
        const data = ctx.getBody();
        if (data.len == 0) return null;

        const boundary = MultipartParser.extractBoundary(content_type) catch |parse_err| {
            std.log.warn("Failed to extract multipart boundary: {}", .{parse_err});
            return null;
        };
        var parser = MultipartParser.init(ctx.allocator, boundary);
        defer parser.deinit();

        const form = parser.parse(data) catch |parse_err| {
            std.log.warn("Failed to parse multipart form data: {}", .{parse_err});
            return null;
        };

        // Store parsed form - we need a mutable reference
        const form_ptr = ctx.allocator.create(MultipartForm) catch return null;
        form_ptr.* = form;

        // Transfer ownership into the context so it will be freed with ctx.deinit
        ctx.multipart_form = form_ptr;

        return form_ptr;
    }

    /// Get uploaded file from multipart form
    pub fn getFile(ctx: *Context, name: []const u8) ?*const MultipartForm.Part {
        const form = ctx.getMultipart() orelse return null;
        return form.getFile(name);
    }

    /// Get all uploaded files
    pub fn getAllFiles(ctx: *Context) []const MultipartForm.Part {
        const form = ctx.getMultipart() orelse return &.{};
        return form.getAllFiles();
    }

    /// Get cookie jar (lazy initialization)
    pub fn getCookieJar(ctx: *Context) *CookieJar {
        if (ctx.cookie_jar == null) {
            var jar = CookieJar.init(ctx.allocator);
            if (ctx.getHeader("Cookie")) |cookie_header| {
                jar.parse(cookie_header) catch |parse_err| {
                    std.log.warn("Failed to parse cookie header: {}", .{parse_err});
                };
            }
            ctx.cookie_jar = jar;
        }
        return &ctx.cookie_jar.?;
    }

    /// Get cookie value by name
    pub fn getCookie(ctx: *Context, name: []const u8) ?[]const u8 {
        const jar = ctx.getCookieJar();
        return jar.get(name);
    }

    /// Set cookie
    pub fn setCookie(ctx: *Context, cookie: Cookie) !void {
        const cookie_str = try cookie.toString(ctx.allocator);
        defer ctx.allocator.free(cookie_str);
        try ctx.response.addHeader("Set-Cookie", cookie_str);
    }

    /// Check if cookie exists
    pub fn hasCookie(ctx: *Context, name: []const u8) bool {
        const jar = ctx.getCookieJar();
        return jar.has(name);
    }

    /// Get or create session
    pub fn getSession(ctx: *Context, session_manager: *SessionManager) !*Session {
        if (ctx.session) |*sess| {
            return sess;
        }

        const session_id = ctx.getCookie(session_manager.config.cookie_name);
        const session = try session_manager.get(session_id);
        ctx.session = session;

        // Set session cookie
        const cookie = try session_manager.createCookie(session.id);
        try ctx.setCookie(cookie);

        return ctx.session.?;
    }

    /// Get session value
    pub fn getSessionValue(ctx: *Context, key: []const u8) ?[]const u8 {
        if (ctx.session) |*sess| {
            return sess.get(key);
        }
        return null;
    }

    /// Set session value
    pub fn setSessionValue(ctx: *Context, key: []const u8, value: []const u8, session_manager: *SessionManager) !void {
        const session = try ctx.getSession(session_manager);
        try session.set(key, value);
    }

    /// Destroy session
    pub fn destroySession(ctx: *Context, session_manager: *SessionManager) void {
        if (ctx.session) |*sess| {
            session_manager.destroy(sess.id);
            ctx.session = null;
        }
    }

    pub fn html(ctx: *Context, content: []const u8) !void {
        try ctx.response.setHeader("Content-Type", "text/html; charset=utf-8");
        try ctx.response.write(content);
    }

    pub fn text(ctx: *Context, content: []const u8) !void {
        try ctx.response.setHeader("Content-Type", "text/plain; charset=utf-8");
        try ctx.response.write(content);
    }

    pub fn setStatus(ctx: *Context, status_code: http.Status) void {
        ctx.response.setStatus(status_code);
    }

    pub fn err(ctx: *Context, status_code: http.Status, message: []const u8) !void {
        ctx.setStatus(status_code);
        try ctx.json(.{ .error_val = message });
    }
};
