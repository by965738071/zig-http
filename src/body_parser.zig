const std = @import("std");

/// Body value type for form data
pub const BodyValue = union(enum) {
    single: []const u8,
    multiple: std.ArrayList([]const u8),
};

/// Form data container
pub const Form = struct {
    allocator: std.mem.Allocator,
    fields: std.StringHashMap(BodyValue),

    pub fn init(allocator: std.mem.Allocator) Form {
        return .{
            .allocator = allocator,
            .fields = std.StringHashMap(BodyValue).init(allocator),
        };
    }

    pub fn deinit(form: *Form) void {
        var it = form.fields.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .single => |s| form.allocator.free(s),
                .multiple => |*list| {
                    for (list.items) |item| {
                        form.allocator.free(item);
                    }
                    list.deinit(form.allocator);
                },
            }
        }
        form.fields.deinit();
    }

    pub fn get(form: *Form, key: []const u8) ?[]const u8 {
        if (form.fields.get(key)) |value| {
            switch (value) {
                .single => |s| return s,
                .multiple => |*list| {
                    if (list.items.len > 0) return list.items[0];
                },
            }
        }
        return null;
    }

    pub fn getAll(form: *Form, key: []const u8) ?*const std.ArrayList([]const u8) {
        if (form.fields.get(key)) |value| {
            switch (value) {
                .single => {
                    // For single values, getAll doesn't make sense
                    // User should use get() instead
                    return null;
                },
                .multiple => |*list| return list,
            }
        }
        return null;
    }
};

/// Body parser for HTTP request bodies
pub const BodyParser = struct {
    allocator: std.mem.Allocator,
    content_type: ?[]const u8,
    data: []const u8,
    parsed: ?Parsed,

    pub const Parsed = union(enum) {
        json: std.json.Parsed(std.json.Value),
        form: Form,
        raw: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, content_type: ?[]const u8, data: []const u8) BodyParser {
        return .{
            .allocator = allocator,
            .content_type = content_type,
            .data = data,
            .parsed = null,
        };
    }

    pub fn deinit(parser: *BodyParser) void {
        if (parser.parsed) |*p| {
            switch (p.*) {
                .json => |*parsed| parsed.deinit(),
                .form => |*f| f.deinit(),
                .raw => {},
            }
        }
    }

    pub fn parse(parser: *BodyParser) !Parsed {
        if (parser.parsed) |p| {
            return p;
        }

        const ct = parser.content_type orelse "application/octet-stream";

        if (std.mem.indexOf(u8, ct, "application/json") != null) {
            const parsed = try std.json.parseFromSlice(std.json.Value, parser.allocator, parser.data, .{
                .ignore_unknown_fields = true,
            });
            parser.parsed = .{ .json = parsed };
            return parser.parsed.?;
        } else if (std.mem.indexOf(u8, ct, "application/x-www-form-urlencoded") != null) {
            const form = try UrlEncodedFormParser.parse(parser.allocator, parser.data);
            parser.parsed = .{ .form = form };
            return parser.parsed.?;
        } else {
            parser.parsed = .{ .raw = parser.data };
            return parser.parsed.?;
        }
    }

    pub fn getJSON(parser: *BodyParser) ?*const std.json.Value {
        if (parser.parsed == null) {
            _ = parser.parse() catch return null;
        }
        if (parser.parsed) |p| {
            switch (p) {
                .json => |*parsed| return &parsed.value,
                else => return null,
            }
        }
        return null;
    }

    pub fn getForm(parser: *BodyParser) ?*const Form {
        if (parser.parsed == null) {
            _ = parser.parse() catch return null;
        }
        if (parser.parsed) |p| {
            switch (p) {
                .form => |*f| return f,
                else => return null,
            }
        }
        return null;
    }
};

/// URL-encoded form data parser
pub const UrlEncodedFormParser = struct {
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Form {
        var form = Form.init(allocator);
        errdefer form.deinit();

        var it = std.mem.splitScalar(u8, data, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;

            const eq_pos = std.mem.indexOfScalar(u8, pair, '=');
            if (eq_pos == null) {
                // Handle key without value
                const key = try percentDecode(allocator, pair);
                try form.fields.put(key, .{ .single = "" });
                continue;
            }

            const key_str = pair[0..eq_pos.?];
            const value_str = pair[eq_pos.? + 1 ..];

            const key = try percentDecode(allocator, key_str);
            const value = try percentDecode(allocator, value_str);

            if (form.fields.getPtr(key)) |existing_ref| {
                switch (existing_ref.*) {
                    .single => |s| {
                        // Free the old single value before replacing
                        form.allocator.free(s);
                        var list = std.ArrayList([]const u8).empty;
                        try list.append(form.allocator, value);
                        existing_ref.* = .{ .multiple = list };
                    },
                    .multiple => |*list| {
                        try list.append(form.allocator, value);
                    },
                }
            } else {
                try form.fields.put(key, .{ .single = value });
            }
        }

        return form;
    }

    /// Decode URL-encoded percent-encoding
    fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {

        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '%') {
                if (i + 2 >= input.len) return error.InvalidPercentEncoding;
                const hex_str = input[i + 1 .. i + 3];
                const byte_val = std.fmt.parseInt(u8, hex_str, 16) catch {
                    return error.InvalidPercentEncoding;
                };
                try result.append(allocator, byte_val);
                i += 3;
            } else if (input[i] == '+') {
                try result.append(allocator, ' ');
                i += 1;
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    test "parse simple form" {
        const allocator = std.testing.allocator;
        const data = "name=John&age=30&city=New+York";

        var form = try parse(allocator, data);
        defer form.deinit();

        try std.testing.expectEqualStrings("John", form.get("name").?);
        try std.testing.expectEqualStrings("30", form.get("age").?);
        try std.testing.expectEqualStrings("New York", form.get("city").?);
    }

    test "parse multiple values" {
        const allocator = std.testing.allocator;
        const data = "colors=red&colors=blue&colors=green";

        var form = try parse(allocator, data);
        defer form.deinit();

        const colors = form.getAll("colors").?;
        try std.testing.expectEqual(@as(usize, 3), colors.items.len);
        try std.testing.expectEqualStrings("red", colors.items[0]);
        try std.testing.expectEqualStrings("blue", colors.items[1]);
        try std.testing.expectEqualStrings("green", colors.items[2]);
    }

    test "percent decode" {
        const allocator = std.testing.allocator;
        const input = "Hello%20World%21";

        const decoded = try percentDecode(allocator, input);
        defer allocator.free(decoded);

        try std.testing.expectEqualStrings("Hello World!", decoded);
    }
};
