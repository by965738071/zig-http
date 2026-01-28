const std = @import("std");

/// Multipart form data field
pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: []const u8,
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
            .parts = std.ArrayList(Part).empty,
            .fields = std.StringHashMap([]const u8).init(allocator),
            .files = std.StringHashMap(Part).init(allocator),
        };
    }

    pub fn deinit(form: *MultipartForm) void {
        for (form.parts.items) |*part| {
            form.allocator.free(part.name);
            if (part.filename) |f| form.allocator.free(f);
            if (part.content_type) |ct| form.allocator.free(ct);
            // Note: part.data is owned by the form's buffer, freed separately
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
            const part = entry.value_ptr.*;
            form.allocator.free(part.name);
            if (part.filename) |f| form.allocator.free(f);
            if (part.content_type) |ct| form.allocator.free(ct);
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
            .buffer = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(parser: *MultipartParser) void {
        parser.buffer.deinit(parser.allocator);
    }

    /// Parse multipart form data
    pub fn parse(parser: *MultipartParser, data: []const u8) !MultipartForm {
        var form = MultipartForm.init(parser.allocator);
        errdefer form.deinit();

        const boundary_marker = try std.fmt.allocPrint(parser.allocator, "--{s}", .{parser.boundary});
        defer parser.allocator.free(boundary_marker);

        var parts = std.mem.splitSequence(u8, data, boundary_marker);

        // Skip first empty part (before first boundary)
        _ = parts.next();

        while (parts.next()) |part_data| {
            // Remove trailing CRLF
            var trimmed = part_data;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }

            // Check for end marker
            if (std.mem.eql(u8, trimmed, "--")) {
                break;
            }

            if (trimmed.len > 0) {
                const part = try parser.parsePart(trimmed);
                try form.parts.append(parser.allocator, part);

                // Add to appropriate map
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

    /// Parse individual multipart part
    fn parsePart(parser: *MultipartParser, data: []const u8) !Part {
        // Split headers and body
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
            std.mem.indexOf(u8, data, "\n\n") orelse
            return error.InvalidMultipartFormat;

        const header_data = data[0..header_end];
        const body = data[header_end + 2 ..]; // Skip \r\n

        // Parse headers
        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;

        var header_it = std.mem.splitScalar(u8, header_data, '\n');
        while (header_it.next()) |line| {
            // Trim CRLF
            var trimmed = line;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (trimmed.len == 0) continue;

            // Parse header
            if (std.ascii.indexOfIgnoreCase(trimmed, "content-disposition:")) |idx| {
                const content_disp = trimmed[idx + "content-disposition:".len ..];
                const trimmed_disp = std.mem.trim(u8, content_disp, &std.ascii.whitespace);

                // Extract name
                if (std.mem.indexOf(u8, trimmed_disp, "name=\"")) |name_idx| {
                    const name_start = name_idx + "name=\"".len;
                    const name_end = std.mem.indexOf(u8, trimmed_disp[name_start..], "\"") orelse trimmed_disp.len;
                    name = try parser.allocator.dupe(u8, trimmed_disp[name_start .. name_start + name_end]);
                }

                // Extract filename
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

        // Copy body data
        const body_copy = try parser.allocator.dupe(u8, body);

        return .{
            .name = name orelse "",
            .filename = filename,
            .content_type = content_type,
            .data = body_copy,
        };
    }

    /// Extract boundary from Content-Type header
    pub fn extractBoundary(content_type: []const u8) ![]const u8 {
        const idx = std.mem.indexOf(u8, content_type, "boundary=") orelse
            return error.BoundaryNotFound;

        const boundary_start = idx + "boundary=".len;
        var boundary = content_type[boundary_start..];

        // Remove quotes if present
        if (boundary.len > 0 and boundary[0] == '"') {
            boundary = boundary[1..];
        }
        if (boundary.len > 0 and boundary[boundary.len - 1] == '"') {
            boundary = boundary[0 .. boundary.len - 1];
        }

        return boundary;
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
