const std = @import("std");

/// Multipart form data field
pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: []const u8,
};

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

/// Multipart form data container
pub const MultipartForm = struct {
    allocator: std.mem.Allocator,
    parts: std.ArrayList(Part),
    fields: std.StringHashMap([]const u8),
    files: std.StringHashMap(Part),

    pub fn init(allocator: std.mem.Allocator) MultipartForm {
        return .{
            .allocator = allocator,
            .parts = std.ArrayList(Part){},
            .fields = std.StringHashMap([]const u8).init(allocator),
            .files = std.StringHashMap(Part).init(allocator),
        };
    }

    pub fn deinit(form: *MultipartForm) void {
        for (form.parts.items) |*part| {
            form.allocator.free(part.name);
            if (part.filename) |f| form.allocator.free(f);
            if (part.content_type) |ct| form.allocator.free(ct);
            form.allocator.free(part.data);
        }
        form.parts.deinit(form.allocator);

        var field_it = form.fields.iterator();
        while (field_it.next()) |entry| {
            form.allocator.free(entry.key_ptr.*);
            form.allocator.free(entry.value_ptr.*);
        }
        form.fields.deinit();

        var file_it = form.files.iterator();
        while (file_it.next()) |entry| {
            form.allocator.free(entry.key_ptr.*);
        }
        form.files.deinit();
    }

    pub fn getField(form: MultipartForm, name: []const u8) ?[]const u8 {
        return form.fields.get(name);
    }

    pub fn getFile(form: MultipartForm, name: []const u8) ?*const Part {
        return form.files.get(name);
    }

    pub fn getAllFiles(form: MultipartForm) []const Part {
        return form.parts.items;
    }
};

/// Multipart form data parser
pub const MultipartParser = struct {
    allocator: std.mem.Allocator,
    boundary: []const u8,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, boundary: []const u8) MultipartParser {
        return .{
            .allocator = allocator,
            .boundary = boundary,
            .buffer = std.ArrayList(u8){},
        };
    }

    pub fn deinit(parser: *MultipartParser) void {
        parser.buffer.deinit(parser.allocator);
    }

    pub fn parse(parser: *MultipartParser, data: []const u8) !MultipartForm {
        var form = MultipartForm.init(parser.allocator);
        errdefer form.deinit();

        const boundary_marker = try std.fmt.allocPrint(parser.allocator, "--{s}", .{parser.boundary});
        defer parser.allocator.free(boundary_marker);

        var parts = std.mem.splitSequence(u8, data, boundary_marker);

        _ = parts.next();

        while (parts.next()) |part_data| {
            var trimmed = part_data;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }

            if (std.mem.eql(u8, trimmed, "--")) {
                break;
            }

            if (trimmed.len > 0) {
                const part = try parser.parsePart(trimmed);
                try form.parts.append(parser.allocator, part);

                if (part.filename != null) {
                    const name_copy = try parser.allocator.dupe(u8, part.name);
                    try form.files.put(name_copy, part);
                } else {
                    const value_copy = try parser.allocator.dupe(u8, part.data);
                    const name_copy = try parser.allocator.dupe(u8, part.name);
                    try form.fields.put(name_copy, value_copy);
                }
            }
        }

        return form;
    }

    fn parsePart(parser: *MultipartParser, data: []const u8) !Part {
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
            std.mem.indexOf(u8, data, "\n\n") orelse
            return error.InvalidMultipartFormat;

        const header_data = data[0..header_end];
        const body = data[header_end + 2 ..];

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;

        var header_it = std.mem.splitScalar(u8, header_data, '\n');
        while (header_it.next()) |line| {
            var trimmed = line;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (trimmed.len == 0) continue;

            if (std.ascii.indexOfIgnoreCase(trimmed, "content-disposition:")) |idx| {
                const content_disp = trimmed[idx + "content-disposition:".len ..];
                const trimmed_disp = std.mem.trim(u8, content_disp, &std.ascii.whitespace);

                if (std.mem.indexOf(u8, trimmed_disp, "name=\"")) |name_idx| {
                    const name_start = name_idx + "name=\"".len;
                    const name_end = std.mem.indexOf(u8, trimmed_disp[name_start..], "\"") orelse trimmed_disp.len;
                    name = try parser.allocator.dupe(u8, trimmed_disp[name_start .. name_start + name_end]);
                }

                if (std.mem.indexOf(u8, trimmed_disp, "filename=\"")) |file_idx| {
                    const file_start = file_idx + "filename=\"".len;
                    const file_end = std.mem.indexOf(u8, trimmed_disp[file_start..], "\"") orelse trimmed_disp.len;
                    filename = try parser.allocator.dupe(u8, trimmed_disp[file_start .. file_start + file_end]);
                }
            } else if (std.ascii.indexOfIgnoreCase(trimmed, "content-type:")) |idx| {
                const ct = trimmed[idx + "content-type:".len ..];
                content_type = try parser.allocator.dupe(u8, std.mem.trim(u8, ct, &std.ascii.whitespace));
            }
        }

        const body_copy = try parser.allocator.dupe(u8, body);

        return .{
            .name = name orelse "",
            .filename = filename,
            .content_type = content_type,
            .data = body_copy,
        };
    }

    pub fn extractBoundary(content_type: []const u8) ![]const u8 {
        const idx = std.mem.indexOf(u8, content_type, "boundary=") orelse
            return error.BoundaryNotFound;

        const boundary_start = idx + "boundary=".len;
        var boundary = content_type[boundary_start..];

        if (boundary.len > 0 and boundary[0] == '"') {
            boundary = boundary[1..];
        }
        if (boundary.len > 0 and boundary[boundary.len - 1] == '"') {
            boundary = boundary[0 .. boundary.len - 1];
        }

        return boundary;
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
        multipart: MultipartForm,
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
                .multipart => |*mf| mf.deinit(),
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
        } else if (std.mem.indexOf(u8, ct, "multipart/form-data") != null) {
            const boundary = try MultipartParser.extractBoundary(ct);
            var mp_parser = MultipartParser.init(parser.allocator, boundary);
            defer mp_parser.deinit();
            const multipart_form = try mp_parser.parse(parser.data);
            parser.parsed = .{ .multipart = multipart_form };
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

    pub fn getMultipart(parser: *BodyParser) ?*const MultipartForm {
        if (parser.parsed == null) {
            _ = parser.parse() catch return null;
        }
        if (parser.parsed) |p| {
            switch (p) {
                .multipart => |*mf| return mf,
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

test "extractBoundary" {
    const ct1 = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";
    const boundary1 = try MultipartParser.extractBoundary(ct1);
    try std.testing.expectEqualStrings("----WebKitFormBoundary7MA4YWxkTrZu0gW", boundary1);

    const ct2 = "multipart/form-data; boundary=\"----WebKitFormBoundary7MA4YWxkTrZu0gW\"";
    const boundary2 = try MultipartParser.extractBoundary(ct2);
    try std.testing.expectEqualStrings("----WebKitFormBoundary7MA4YWxkTrZu0gW", boundary2);
}
