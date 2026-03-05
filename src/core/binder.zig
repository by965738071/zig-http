const std = @import("std");
const Context = @import("context.zig").Context;

pub const Binder = @This();

allocator: std.mem.Allocator,
ctx: *Context,

pub fn init(allocator: std.mem.Allocator, ctx: *Context) Binder {
    return .{ .allocator = allocator, .ctx = ctx };
}

pub fn query(self: Binder, name: []const u8) ?[]const u8 {
    return self.ctx.getQuery(name);
}

pub fn param(self: Binder, name: []const u8) ?[]const u8 {
    return self.ctx.getParam(name);
}

pub fn header(self: Binder, name: []const u8) ?[]const u8 {
    return self.ctx.getHeader(name);
}

pub fn form(self: Binder, name: []const u8) ?[]const u8 {
    if (self.ctx.getForm()) |f| {
        return f.get(name);
    }
    return null;
}

pub fn json(self: Binder) ?*const std.json.Value {
    return self.ctx.getJSON();
}

pub fn body(self: Binder) []const u8 {
    return self.ctx.getBody();
}

pub fn cookie(self: Binder, name: []const u8) ?[]const u8 {
    return self.ctx.getCookie(name);
}

pub fn bind(self: Binder, comptime T: type) !T {
    return bindStruct(T, self.ctx, self.allocator);
}

fn bindStruct(comptime T: type, ctx: *Context, allocator: std.mem.Allocator) !T {
    _ = allocator;
    const info = @typeInfo(T);

    if (info == .@"struct") {
        return bindStructFields(T, ctx);
    }

    return error.InvalidType;
}

fn bindStructFields(comptime T: type, ctx: *Context) !T {
    var instance: T = undefined;

    inline for (std.meta.fields(T)) |field| {
        if (comptime isOptional(field.type)) {
            const child_type = @typeInfo(field.type).optional.child;
            const value = bindField(field.name, child_type, ctx) catch {
                @field(instance, field.name) = null;
                continue;
            };
            @field(instance, field.name) = value;
        } else {
            const value = try bindField(field.name, field.type, ctx);
            @field(instance, field.name) = value;
        }
    }

    return instance;
}

fn bindField(comptime name: []const u8, comptime T: type, ctx: *Context) !T {
    if (T == []const u8) {
        return try getStringField(name, ctx) orelse error.MissingField;
    }

    if (T == ?[]const u8) {
        return getStringField(name, ctx);
    }

    if (T == std.json.Value) {
        if (ctx.getJSON()) |j| {
            const json_val = j.*;
            if (json_val == .object) {
                if (json_val.object.get(name)) |val| {
                    return val;
                }
            }
        }
        return error.MissingField;
    }

    if (comptime isInteger(T)) {
        const str = try getStringField(name, ctx) orelse error.MissingField;
        return parseInteger(T, str);
    }

    if (comptime isFloat(T)) {
        const str = try getStringField(name, ctx) orelse error.MissingField;
        return parseFloat(T, str);
    }

    if (T == bool) {
        const str = try getStringField(name, ctx) orelse error.MissingField;
        return parseBool(str);
    }

    if (@typeInfo(T) == .optional) {
        const child = @typeInfo(T).optional.child;
        if (comptime isInteger(child)) {
            if (getStringField(name, ctx)) |s| {
                return try parseInteger(child, s);
            }
            return null;
        }
        if (comptime isFloat(child)) {
            if (getStringField(name, ctx)) |s| {
                return try parseFloat(child, s);
            }
            return null;
        }
        if (child == []const u8) {
            return getStringField(name, ctx);
        }
        if (child == bool) {
            if (getStringField(name, ctx)) |s| {
                return parseBool(s);
            }
            return null;
        }
        return null;
    }

    if (@typeInfo(T) == .@"enum") {
        const str = try getStringField(name, ctx) orelse error.MissingField;
        return parseEnum(T, str);
    }

    return error.UnsupportedType;
}

fn getStringField(name: []const u8, ctx: *Context) !?[]const u8 {
    if (ctx.getQuery(name)) |v| return v;
    if (ctx.getParam(name)) |v| return v;
    if (ctx.getForm()) |f| if (f.get(name)) |v| return v;
    if (ctx.getJSON()) |j| {
        const json_val = j.*;
        if (json_val == .object) {
            if (json_val.object.get(name)) |val| {
                return jsonValueToString(val, ctx.allocator);
            }
        }
    }
    return null;
}

fn jsonValueToString(val: std.json.Value, allocator: std.mem.Allocator) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch null,
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}) catch null,
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => null,
    };
}

fn isInteger(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        else => false,
    };
}

fn isFloat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        else => false,
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn parseInteger(comptime T: type, str: []const u8) !T {
    return std.fmt.parseInt(T, str, 10) catch return error.TypeConversionFailed;
}

fn parseFloat(comptime T: type, str: []const u8) !T {
    return std.fmt.parseFloat(T, str) catch return error.TypeConversionFailed;
}

fn parseBool(str: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(str, "true") or std.ascii.eqlIgnoreCase(str, "1") or std.ascii.eqlIgnoreCase(str, "yes")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(str, "false") or std.ascii.eqlIgnoreCase(str, "0") or std.ascii.eqlIgnoreCase(str, "no")) {
        return false;
    }
    return error.TypeConversionFailed;
}

fn parseEnum(comptime T: type, str: []const u8) !T {
    inline for (std.meta.fields(T)) |field| {
        if (std.ascii.eqlIgnoreCase(str, field.name)) {
            return @field(T, field.name);
        }
    }
    return error.InvalidEnumValue;
}
