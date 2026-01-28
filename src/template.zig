const std = @import("std");

/// Template engine
pub const Template = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    variables: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Template {
        return .{
            .allocator = allocator,
            .source = source,
            .variables = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(template_obj: *Template) void {
        var it = template_obj.variables.iterator();
        while (it.next()) |entry| {
            template_obj.allocator.free(entry.key_ptr.*);
            template_obj.allocator.free(entry.value_ptr.*);
        }
        template_obj.variables.deinit();
    }

    /// Set template variable
    pub fn set(template_obj: *Template, key: []const u8, value: []const u8) !void {
        const key_copy = try template_obj.allocator.dupe(u8, key);
        const value_copy = try template_obj.allocator.dupe(u8, value);
        try template_obj.variables.put(key_copy, value_copy);
    }

    /// Render template
    pub fn render(template_obj: Template) ![]const u8 {
        var result = std.ArrayList(u8){};
        errdefer result.deinit(template_obj.allocator);

        var i: usize = 0;
        while (i < template_obj.source.len) {
            // Check for variable placeholder {{variable}}
            if (i + 2 < template_obj.source.len and
                template_obj.source[i] == '{' and template_obj.source[i + 1] == '{')
            {
                const end = std.mem.indexOf(u8, template_obj.source[i..], "}}") orelse template_obj.source.len - i;
                if (end > 0) {
                    const var_name = template_obj.source[i + 2 .. i + end];
                    const trimmed = std.mem.trim(u8, var_name, &std.ascii.whitespace);

                    if (template_obj.variables.get(trimmed)) |value| {
                        try result.appendSlice(template_obj.allocator, value);
                    } else {
                        // Keep original if variable not found
                        try result.appendSlice(template_obj.allocator, template_obj.source[i .. i + end + 2]);
                    }
                    i += end + 2;
                    continue;
                }
            }

            // Check for conditional {{#if variable}}...{{/if}}
            if (i + 4 < template_obj.source.len and
                std.mem.eql(u8, template_obj.source[i..i+4], "{{#if"))
            {
                const end_if = std.mem.indexOf(u8, template_obj.source[i..], "{{/if}}") orelse template_obj.source.len - i;
                const content_start = i + 4;
                const var_start = content_start;
                const var_end = std.mem.indexOf(u8, template_obj.source[var_start..], "}}") orelse content_start;

                if (var_end > 0) {
                    const var_name = std.mem.trim(u8, template_obj.source[var_start .. var_start + var_end], &std.ascii.whitespace);

                    // Check if variable is truthy
                    if (template_obj.variables.get(var_name)) |value| {
                        if (value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false")) {
                            // Include content
                            const content = template_obj.source[var_start + var_end + 2 .. i + end_if];
                            try result.appendSlice(template_obj.allocator, content);
                        }
                    }

                    i += end_if + 6;
                    continue;
                }
            }

            // Check for loop {{#each variable}}...{{/each}}
            if (i + 6 < template_obj.source.len and
                std.mem.eql(u8, template_obj.source[i..i+6], "{{#each"))
            {
                const end_each = std.mem.indexOf(u8, template_obj.source[i..], "{{/each}}") orelse template_obj.source.len - i;
                const content_start = i + 6;
                const var_start = content_start;
                const var_end = std.mem.indexOf(u8, template_obj.source[var_start..], "}}") orelse content_start;

                if (var_end > 0) {
                    const var_name = std.mem.trim(u8, template_obj.source[var_start .. var_start + var_end], &std.ascii.whitespace);

                    // Get array value (simplified: comma-separated string)
                    if (template_obj.variables.get(var_name)) |value| {
                        var items = std.mem.splitScalar(u8, value, ',');
                        while (items.next()) |item| {
                            const trimmed = std.mem.trim(u8, item, &std.ascii.whitespace);
                            // Replace {{this}} with item
                            const content = template_obj.source[var_start + var_end + 2 .. i + end_each];
                            var content_iter = std.mem.splitSequence(u8, content, "{{this}}");
                            var first = true;
                            while (content_iter.next()) |part| {
                                if (first) {
                                    first = false;
                                } else {
                                    try result.appendSlice(template_obj.allocator, trimmed);
                                }
                                try result.appendSlice(template_obj.allocator, part);
                            }
                        }
                    }

                    i += end_each + 8;
                    continue;
                }
            }

            // Copy character as-is
            try result.append(template_obj.allocator, template_obj.source[i]);
            i += 1;
        }

        return result.toOwnedSlice(template_obj.allocator);
    }

    /// Escape HTML for XSS prevention
    pub fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        for (input) |c| {
            switch (c) {
                '<' => try result.appendSlice(allocator, "&lt;"),
                '>' => try result.appendSlice(allocator, "&gt;"),
                '&' => try result.appendSlice(allocator, "&amp;"),
                '"' => try result.appendSlice(allocator, "&quot;"),
                '\'' => try result.appendSlice(allocator, "&#39;"),
                else => try result.append(allocator, c),
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Render template with HTML escaping
    pub fn renderSafe(template_obj: Template) ![]const u8 {
        // First escape all variable values
        var it = template_obj.variables.iterator();
        while (it.next()) |entry| {
            const escaped = try escapeHtml(template_obj.allocator, entry.value_ptr.*);
            template_obj.allocator.free(entry.value_ptr.*);
            try template_obj.variables.put(entry.key_ptr.*, escaped);
        }

        return try template_obj.render();
    }
};

test "template rendering" {
    const allocator = std.testing.allocator;
    const source = "Hello {{name}}, your score is {{score}}!";
    var tmpl = Template.init(allocator, source);
    defer tmpl.deinit();

    try tmpl.set("name", "Alice");
    try tmpl.set("score", "95");

    const result = try tmpl.render();
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello Alice, your score is 95!", result);
}

test "template conditional" {
    const allocator = std.testing.allocator;
    const source = "{{#if logged_in}}Welcome back!{{/if}}{{#if logged_in}}Please login.{{/if}}";
    var tmpl = Template.init(allocator, source);
    defer tmpl.deinit();

    try tmpl.set("logged_in", "true");

    const result = try tmpl.render();
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Welcome back!") != null);
}

test "html escaping" {
    const allocator = std.testing.allocator;
    const result = try Template.escapeHtml(allocator, "<script>alert('xss')</script>");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;", result);
}
