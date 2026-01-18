const std = @import("std");
const http = std.http;

const ParamList = @import("types.zig").ParamList;
const Handler = @import("types.zig").Handler;
const Middleware = @import("middleware.zig").Middleware;

pub const Router = struct {
    allocator: std.mem.Allocator,
    root: *RouteNode,

    pub const RouteNode = struct {
        allocator: std.mem.Allocator,
        path_segment: []const u8,
        children: std.StringHashMap(*RouteNode),
        param_child: ?*RouteNode,
        wildcard_child: ?*RouteNode,
        handler: ?Handler,
        method: http.Method,
        middlewares: std.ArrayList(*Middleware),

        pub fn init(allocator: std.mem.Allocator, segment: []const u8, method: http.Method) !*RouteNode {
            const node = try allocator.create(RouteNode);
            node.* = .{
                .allocator = allocator,
                .path_segment = try allocator.dupe(u8, segment),
                .children = std.StringHashMap(*RouteNode).init(allocator),
                .param_child = null,
                .wildcard_child = null,
                .handler = null,
                .method = method,
                .middlewares = std.ArrayList(*Middleware){},
            };
            return node;
        }

        pub fn deinit(node: *RouteNode) void {
            node.allocator.free(node.path_segment);
            var iter = node.children.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            node.children.deinit();

            if (node.param_child) |child| {
                child.deinit();
            }
            if (node.wildcard_child) |child| {
                child.deinit();
            }

            node.middlewares.deinit(node.allocator);
            node.allocator.destroy(node);
        }
    };

    pub const Route = struct {
        handler: Handler,
        params: ParamList,
        middlewares: []*Middleware,
    };

    pub fn init(allocator: std.mem.Allocator) !Router {
        const root = try RouteNode.init(allocator, "", .GET);
        return .{
            .allocator = allocator,
            .root = root,
        };
    }

    pub fn deinit(router: *Router) void {
        router.root.deinit();
    }

    pub fn addRoute(router: *Router, method: http.Method, path: []const u8, handler: Handler) !void {
        var segments = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
        var current = router.root;

        while (segments.next()) |segment| {
            if (segment.len == 0) continue;

            if (segment[0] == ':') {
                // Parameter segment
                if (current.param_child == null) {
                    current.param_child = try RouteNode.init(router.allocator, segment, method);
                }
                current = current.param_child.?;
            } else if (segment[0] == '*') {
                // Wildcard segment
                if (current.wildcard_child == null) {
                    current.wildcard_child = try RouteNode.init(router.allocator, segment, method);
                }
                current = current.wildcard_child.?;
            } else {
                // Regular segment
                // 修复: 使用正确的 getOrPut 返回变量名
                const gop = try current.children.getOrPut(segment);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try RouteNode.init(router.allocator, segment, method);
                }
                current = gop.value_ptr.*;
            }
        }

        current.handler = handler;
        current.method = method;
    }

    pub fn findRoute(router: *Router, method: http.Method, path: []const u8) !?Route {
        var params = ParamList.init(router.allocator);

        var trimmed_path = std.mem.trim(u8, path, "/");
        if (trimmed_path.len == 0) {
            if (router.root.handler) |handler| {
                return .{
                    .handler = handler,
                    .params = params,
                    .middlewares = router.root.middlewares.items,
                };
            }
            params.deinit();
            return null;
        }

        var segments = std.mem.splitScalar(u8, trimmed_path, '/');
        var current = router.root;

        while (segments.next()) |segment| {
            if (current.children.get(segment)) |child| {
                current = child;
            } else if (current.param_child) |child| {
                try params.put(child.path_segment[1..], segment);
                current = child;
            } else if (current.wildcard_child) |child| {
                try params.put(child.path_segment[1..], segment);
                current = child;
                break;
            } else {
                params.deinit();
                return null;
            }
        }

        if (current.handler != null and current.method == method) {
            return .{
                .handler = current.handler.?,
                .params = params,
                .middlewares = current.middlewares.items,
            };
        }

        params.deinit();
        return null;
    }
};
