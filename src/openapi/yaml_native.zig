const std = @import("std");

const BlockStyle = enum {
    literal,
    folded,
};

const MappingEntry = struct {
    key: []const u8,
    value: ?[]const u8,
};

const Line = struct {
    raw: []const u8,
    indent: usize,
    content: []const u8,
};

pub const Diagnostics = struct {
    line: ?usize = null,
};

pub fn yamlToJson(allocator: std.mem.Allocator, yaml_text: []const u8) ![]u8 {
    var diagnostics: Diagnostics = .{};
    return yamlToJsonWithDiagnostics(allocator, yaml_text, &diagnostics);
}

pub fn yamlToJsonWithDiagnostics(
    allocator: std.mem.Allocator,
    yaml_text: []const u8,
    diagnostics: *Diagnostics,
) ![]u8 {
    diagnostics.* = .{};

    var parser = try Parser.init(allocator, yaml_text);
    defer parser.deinit();

    var root = parser.parseDocument() catch |err| {
        if (err != error.OutOfMemory and parser.idx < parser.lines.items.len) {
            diagnostics.line = parser.idx + 1;
        }
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.YamlParseFailed,
        };
    };
    defer deinitJsonValue(allocator, &root);

    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.json.Stringify.value(root, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

const Parser = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line),
    idx: usize,

    fn init(allocator: std.mem.Allocator, yaml_text: []const u8) !Parser {
        var parser: Parser = .{
            .allocator = allocator,
            .lines = .{},
            .idx = 0,
        };
        errdefer parser.lines.deinit(allocator);

        try parser.tokenize(yaml_text);
        return parser;
    }

    fn deinit(self: *Parser) void {
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    fn tokenize(self: *Parser, yaml_text: []const u8) !void {
        var start: usize = 0;
        while (start <= yaml_text.len) {
            const end = std.mem.indexOfScalarPos(u8, yaml_text, start, '\n') orelse yaml_text.len;
            var raw = yaml_text[start..end];
            if (raw.len > 0 and raw[raw.len - 1] == '\r') {
                raw = raw[0 .. raw.len - 1];
            }

            const indent = try countIndent(raw);
            const body = raw[indent..];
            const content = stripInlineComment(body);

            try self.lines.append(self.allocator, .{
                .raw = raw,
                .indent = indent,
                .content = content,
            });

            if (end == yaml_text.len) break;
            start = end + 1;
        }
    }

    fn parseDocument(self: *Parser) anyerror!std.json.Value {
        self.skipEmpty();
        if (self.idx >= self.lines.items.len) return error.YamlParseFailed;

        const root_indent = self.lines.items[self.idx].indent;
        var value = try self.parseBlock(root_indent);
        errdefer deinitJsonValue(self.allocator, &value);

        self.skipEmpty();
        if (self.idx != self.lines.items.len) return error.YamlParseFailed;

        return value;
    }

    fn parseBlock(self: *Parser, indent: usize) anyerror!std.json.Value {
        self.skipEmpty();
        if (self.idx >= self.lines.items.len) return error.YamlParseFailed;

        const line = self.lines.items[self.idx];
        if (line.indent != indent) return error.YamlParseFailed;

        if (isSequenceLine(line.content)) {
            return self.parseSequence(indent);
        }
        return self.parseMapping(indent);
    }

    fn parseSequence(self: *Parser, indent: usize) anyerror!std.json.Value {
        var arr = std.json.Array.init(self.allocator);
        errdefer {
            for (arr.items) |*item| deinitJsonValue(self.allocator, item);
            arr.deinit();
        }

        while (true) {
            self.skipEmpty();
            if (self.idx >= self.lines.items.len) break;

            const line = self.lines.items[self.idx];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.YamlParseFailed;
            if (!isSequenceLine(line.content)) break;

            const remainder = std.mem.trimLeft(u8, line.content[1..], " \t");
            self.idx += 1;

            var item = try self.parseSequenceItem(remainder, indent);
            errdefer deinitJsonValue(self.allocator, &item);
            try arr.append(item);
        }

        return .{ .array = arr };
    }

    fn parseSequenceItem(self: *Parser, remainder: []const u8, sequence_indent: usize) anyerror!std.json.Value {
        if (remainder.len == 0) {
            return self.parseNestedOrNull(sequence_indent);
        }

        if (try splitMappingEntry(remainder, true)) |entry| {
            return self.parseSequenceMappingItem(entry, sequence_indent);
        }

        return self.parseInlineValue(remainder);
    }

    fn parseSequenceMappingItem(self: *Parser, first_entry: MappingEntry, sequence_indent: usize) anyerror!std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer {
            var it_deinit = obj.iterator();
            while (it_deinit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                deinitJsonValue(self.allocator, entry.value_ptr);
            }
            obj.deinit();
        }

        try self.parseAndInsertEntry(&obj, first_entry, sequence_indent);

        while (true) {
            self.skipEmpty();
            if (self.idx >= self.lines.items.len) break;

            const line = self.lines.items[self.idx];
            if (line.indent <= sequence_indent) break;
            if (line.indent != sequence_indent + 2) return error.YamlParseFailed;
            if (isSequenceLine(line.content)) break;

            const entry = (try splitMappingEntry(line.content, true)) orelse return error.YamlParseFailed;
            self.idx += 1;
            try self.parseAndInsertEntry(&obj, entry, line.indent);
        }

        return .{ .object = obj };
    }

    fn parseMapping(self: *Parser, indent: usize) anyerror!std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer {
            var it_deinit = obj.iterator();
            while (it_deinit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                deinitJsonValue(self.allocator, entry.value_ptr);
            }
            obj.deinit();
        }

        while (true) {
            self.skipEmpty();
            if (self.idx >= self.lines.items.len) break;

            const line = self.lines.items[self.idx];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.YamlParseFailed;
            if (isSequenceLine(line.content)) return error.YamlParseFailed;

            const entry = (try splitMappingEntry(line.content, true)) orelse return error.YamlParseFailed;
            self.idx += 1;
            try self.parseAndInsertEntry(&obj, entry, line.indent);
        }

        return .{ .object = obj };
    }

    fn parseAndInsertEntry(
        self: *Parser,
        obj: *std.json.ObjectMap,
        entry: MappingEntry,
        line_indent: usize,
    ) anyerror!void {
        const key_owned = try parseKey(self.allocator, entry.key);
        errdefer self.allocator.free(key_owned);

        var value = try self.parseEntryValue(entry.value, line_indent);
        errdefer deinitJsonValue(self.allocator, &value);

        if (obj.get(key_owned) != null) return error.YamlParseFailed;
        try obj.put(key_owned, value);
    }

    fn parseEntryValue(self: *Parser, maybe_value: ?[]const u8, line_indent: usize) anyerror!std.json.Value {
        if (maybe_value) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) return self.parseNestedOrNull(line_indent);

            if (parseBlockStyle(trimmed)) |style| {
                return self.parseBlockScalar(line_indent, style);
            }
            return self.parseInlineValue(trimmed);
        }

        return self.parseNestedOrNull(line_indent);
    }

    fn parseNestedOrNull(self: *Parser, parent_indent: usize) anyerror!std.json.Value {
        self.skipEmpty();
        if (self.idx >= self.lines.items.len) return .null;
        const next = self.lines.items[self.idx];
        if (next.indent <= parent_indent) return .null;

        if (isSequenceLine(next.content)) {
            return self.parseBlock(next.indent);
        }
        if ((try splitMappingEntry(next.content, true)) != null) {
            return self.parseBlock(next.indent);
        }

        self.idx += 1;
        return self.parseInlineValue(next.content);
    }

    fn parseBlockScalar(self: *Parser, parent_indent: usize, style: BlockStyle) anyerror!std.json.Value {
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(self.allocator);

        var content_indent: ?usize = null;
        var wrote_non_empty = false;
        var pending_blank_lines: usize = 0;

        while (self.idx < self.lines.items.len) {
            const line = self.lines.items[self.idx];
            const trimmed = std.mem.trim(u8, line.raw, " \t");

            if (trimmed.len == 0) {
                if (content_indent == null) {
                    const next = self.peekNonEmptyFrom(self.idx + 1) orelse break;
                    if (next.indent <= parent_indent) break;
                }
                pending_blank_lines += 1;
                self.idx += 1;
                continue;
            }

            if (line.indent <= parent_indent) break;

            if (content_indent == null) {
                content_indent = line.indent;
            }

            const content_base = content_indent.?;
            if (line.indent < content_base) break;

            if (wrote_non_empty) {
                if (style == .literal) {
                    try out.append(self.allocator, '\n');
                    while (pending_blank_lines > 0) : (pending_blank_lines -= 1) {
                        try out.append(self.allocator, '\n');
                    }
                } else {
                    if (pending_blank_lines > 0) {
                        while (pending_blank_lines > 0) : (pending_blank_lines -= 1) {
                            try out.append(self.allocator, '\n');
                        }
                    } else {
                        try out.append(self.allocator, ' ');
                    }
                }
            }

            const segment = std.mem.trimRight(u8, line.raw[content_base..], " \t");
            try out.appendSlice(self.allocator, segment);

            wrote_non_empty = true;
            pending_blank_lines = 0;
            self.idx += 1;
        }

        const owned = try out.toOwnedSlice(self.allocator);
        return .{ .string = owned };
    }

    fn parseInlineValue(self: *Parser, raw_value: []const u8) anyerror!std.json.Value {
        const value = std.mem.trim(u8, raw_value, " \t");
        if (value.len == 0) return .null;

        if (isSingleQuoted(value) or isDoubleQuoted(value)) {
            const decoded = try parseQuotedString(self.allocator, value);
            return .{ .string = decoded };
        }

        if (value[0] == '[' and value[value.len - 1] == ']') {
            return self.parseFlowSequence(value);
        }

        if (value[0] == '{' and value[value.len - 1] == '}') {
            return self.parseFlowMapping(value);
        }

        if (isNullLiteral(value)) return .null;
        if (asciiEqlIgnoreCase(value, "true")) return .{ .bool = true };
        if (asciiEqlIgnoreCase(value, "false")) return .{ .bool = false };

        if (std.fmt.parseInt(i64, value, 10)) |i| {
            return .{ .integer = i };
        } else |_| {}

        if (looksLikeFloat(value)) {
            if (std.fmt.parseFloat(f64, value)) |f| {
                return .{ .float = f };
            } else |_| {}
        }

        return .{ .string = try self.allocator.dupe(u8, value) };
    }

    fn parseFlowSequence(self: *Parser, raw_value: []const u8) anyerror!std.json.Value {
        var arr = std.json.Array.init(self.allocator);
        errdefer {
            for (arr.items) |*item| deinitJsonValue(self.allocator, item);
            arr.deinit();
        }

        const inner = std.mem.trim(u8, raw_value[1 .. raw_value.len - 1], " \t");
        if (inner.len == 0) return .{ .array = arr };

        var start: usize = 0;
        var i: usize = 0;
        var depth: usize = 0;
        var in_single = false;
        var in_double = false;

        while (i < inner.len) : (i += 1) {
            const c = inner[i];

            if (in_single) {
                if (c == '\'') {
                    if (i + 1 < inner.len and inner[i + 1] == '\'') {
                        i += 1;
                    } else {
                        in_single = false;
                    }
                }
                continue;
            }

            if (in_double) {
                if (c == '\\') {
                    if (i + 1 < inner.len) i += 1;
                    continue;
                }
                if (c == '"') in_double = false;
                continue;
            }

            switch (c) {
                '\'' => in_single = true,
                '"' => in_double = true,
                '[', '{' => depth += 1,
                ']', '}' => {
                    if (depth == 0) return error.YamlParseFailed;
                    depth -= 1;
                },
                ',' => {
                    if (depth == 0) {
                        const token = std.mem.trim(u8, inner[start..i], " \t");
                        if (token.len == 0) return error.YamlParseFailed;

                        var item = try self.parseInlineValue(token);
                        errdefer deinitJsonValue(self.allocator, &item);
                        try arr.append(item);
                        start = i + 1;
                    }
                },
                else => {},
            }
        }

        if (in_single or in_double or depth != 0) return error.YamlParseFailed;

        const tail = std.mem.trim(u8, inner[start..], " \t");
        if (tail.len == 0) return error.YamlParseFailed;

        var tail_value = try self.parseInlineValue(tail);
        errdefer deinitJsonValue(self.allocator, &tail_value);
        try arr.append(tail_value);

        return .{ .array = arr };
    }

    fn parseFlowMapping(self: *Parser, raw_value: []const u8) anyerror!std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer {
            var it_deinit = obj.iterator();
            while (it_deinit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                deinitJsonValue(self.allocator, entry.value_ptr);
            }
            obj.deinit();
        }

        const inner = std.mem.trim(u8, raw_value[1 .. raw_value.len - 1], " \t");
        if (inner.len == 0) return .{ .object = obj };

        var start: usize = 0;
        var i: usize = 0;
        var depth: usize = 0;
        var in_single = false;
        var in_double = false;

        while (i < inner.len) : (i += 1) {
            const c = inner[i];

            if (in_single) {
                if (c == '\'') {
                    if (i + 1 < inner.len and inner[i + 1] == '\'') {
                        i += 1;
                    } else {
                        in_single = false;
                    }
                }
                continue;
            }

            if (in_double) {
                if (c == '\\') {
                    if (i + 1 < inner.len) i += 1;
                    continue;
                }
                if (c == '"') in_double = false;
                continue;
            }

            switch (c) {
                '\'' => in_single = true,
                '"' => in_double = true,
                '[', '{' => depth += 1,
                ']', '}' => {
                    if (depth == 0) return error.YamlParseFailed;
                    depth -= 1;
                },
                ',' => {
                    if (depth == 0) {
                        const token = std.mem.trim(u8, inner[start..i], " \t");
                        if (token.len == 0) return error.YamlParseFailed;

                        const entry = (try splitMappingEntry(token, false)) orelse return error.YamlParseFailed;
                        try self.insertFlowEntry(&obj, entry);
                        start = i + 1;
                    }
                },
                else => {},
            }
        }

        if (in_single or in_double or depth != 0) return error.YamlParseFailed;

        const tail = std.mem.trim(u8, inner[start..], " \t");
        if (tail.len == 0) return error.YamlParseFailed;

        const entry = (try splitMappingEntry(tail, false)) orelse return error.YamlParseFailed;
        try self.insertFlowEntry(&obj, entry);

        return .{ .object = obj };
    }

    fn insertFlowEntry(self: *Parser, obj: *std.json.ObjectMap, entry: MappingEntry) anyerror!void {
        const key_owned = try parseKey(self.allocator, entry.key);
        errdefer self.allocator.free(key_owned);

        const value_raw = entry.value orelse return error.YamlParseFailed;
        var value = try self.parseInlineValue(value_raw);
        errdefer deinitJsonValue(self.allocator, &value);

        if (obj.get(key_owned) != null) return error.YamlParseFailed;
        try obj.put(key_owned, value);
    }

    fn skipEmpty(self: *Parser) void {
        while (self.idx < self.lines.items.len) : (self.idx += 1) {
            if (self.lines.items[self.idx].content.len != 0) return;
        }
    }

    fn peekNonEmpty(self: *Parser) ?Line {
        return self.peekNonEmptyFrom(self.idx);
    }

    fn peekNonEmptyFrom(self: *Parser, start_index: usize) ?Line {
        var i = start_index;
        while (i < self.lines.items.len) : (i += 1) {
            const line = self.lines.items[i];
            if (line.content.len != 0) return line;
        }
        return null;
    }
};

fn countIndent(raw: []const u8) !usize {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == ' ') continue;
        if (raw[i] == '\t') return error.YamlParseFailed;
        break;
    }
    return i;
}

fn stripInlineComment(body: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    var end = body.len;

    while (i < body.len) : (i += 1) {
        const c = body[i];

        if (in_single) {
            if (c == '\'') {
                if (i + 1 < body.len and body[i + 1] == '\'') {
                    i += 1;
                } else {
                    in_single = false;
                }
            }
            continue;
        }

        if (in_double) {
            if (c == '\\') {
                if (i + 1 < body.len) i += 1;
                continue;
            }
            if (c == '"') in_double = false;
            continue;
        }

        if (c == '\'') {
            in_single = true;
            continue;
        }
        if (c == '"') {
            in_double = true;
            continue;
        }

        if (c == '#') {
            if (i == 0 or std.ascii.isWhitespace(body[i - 1])) {
                end = i;
                break;
            }
        }
    }

    return std.mem.trimRight(u8, body[0..end], " \t");
}

fn isSequenceLine(content: []const u8) bool {
    if (content.len == 0) return false;
    if (content[0] != '-') return false;
    if (content.len == 1) return true;
    return std.ascii.isWhitespace(content[1]);
}

fn splitMappingEntry(line: []const u8, require_space_after_colon: bool) !?MappingEntry {
    const sep = findMappingSeparator(line, require_space_after_colon) orelse return null;

    const key = std.mem.trim(u8, line[0..sep], " \t");
    if (key.len == 0) return error.YamlParseFailed;

    const rhs = std.mem.trimLeft(u8, line[sep + 1 ..], " \t");
    return .{
        .key = key,
        .value = if (rhs.len == 0) null else rhs,
    };
}

fn findMappingSeparator(line: []const u8, require_space_after_colon: bool) ?usize {
    var in_single = false;
    var in_double = false;
    var depth: usize = 0;
    var i: usize = 0;

    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (in_single) {
            if (c == '\'') {
                if (i + 1 < line.len and line[i + 1] == '\'') {
                    i += 1;
                } else {
                    in_single = false;
                }
            }
            continue;
        }

        if (in_double) {
            if (c == '\\') {
                if (i + 1 < line.len) i += 1;
                continue;
            }
            if (c == '"') in_double = false;
            continue;
        }

        switch (c) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            ':' => {
                if (depth != 0) continue;
                if (!require_space_after_colon) return i;
                if (i + 1 == line.len) return i;
                if (std.ascii.isWhitespace(line[i + 1])) return i;
            },
            else => {},
        }
    }

    return null;
}

fn parseBlockStyle(value: []const u8) ?BlockStyle {
    if (value.len == 0) return null;

    if (value[0] == '|') {
        if (value.len == 1) return .literal;
        if (value.len == 2 and (value[1] == '-' or value[1] == '+')) return .literal;
    }

    if (value[0] == '>') {
        if (value.len == 1) return .folded;
        if (value.len == 2 and (value[1] == '-' or value[1] == '+')) return .folded;
    }

    return null;
}

fn parseKey(allocator: std.mem.Allocator, raw_key: []const u8) ![]u8 {
    const key = std.mem.trim(u8, raw_key, " \t");
    if (key.len == 0) return error.YamlParseFailed;

    if (isSingleQuoted(key) or isDoubleQuoted(key)) {
        return parseQuotedString(allocator, key);
    }
    return allocator.dupe(u8, key);
}

fn parseQuotedString(allocator: std.mem.Allocator, raw_value: []const u8) ![]u8 {
    if (raw_value.len < 2) return error.YamlParseFailed;

    if (isSingleQuoted(raw_value)) {
        return parseSingleQuoted(allocator, raw_value[1 .. raw_value.len - 1]);
    }
    if (isDoubleQuoted(raw_value)) {
        return parseDoubleQuoted(allocator, raw_value[1 .. raw_value.len - 1]);
    }
    return error.YamlParseFailed;
}

fn parseSingleQuoted(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') {
            try out.append(allocator, '\'');
            i += 1;
            continue;
        }
        try out.append(allocator, inner[i]);
    }

    return out.toOwnedSlice(allocator);
}

fn parseDoubleQuoted(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c != '\\') {
            try out.append(allocator, c);
            continue;
        }

        if (i + 1 >= inner.len) return error.YamlParseFailed;
        const esc = inner[i + 1];
        i += 1;

        switch (esc) {
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            '/' => try out.append(allocator, '/'),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0c),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            else => try out.append(allocator, esc),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn isSingleQuoted(value: []const u8) bool {
    return value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'';
}

fn isDoubleQuoted(value: []const u8) bool {
    return value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
}

fn isNullLiteral(value: []const u8) bool {
    return value.len == 1 and value[0] == '~' or asciiEqlIgnoreCase(value, "null");
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn looksLikeFloat(value: []const u8) bool {
    if (std.mem.indexOfAny(u8, value, ".eE") == null) return false;

    var has_digit = false;
    for (value) |c| {
        if (std.ascii.isDigit(c)) {
            has_digit = true;
            break;
        }
    }
    return has_digit;
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| deinitJsonValue(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr);
            }
            obj.deinit();
        },
        else => {},
    }
    value.* = .null;
}

test "yamlToJson parses OpenAPI-like YAML without ruby" {
    const allocator = std.testing.allocator;

    const yaml =
        \\openapi: 3.0.3
        \\servers:
        \\  - url: http://localhost:3333
        \\paths:
        \\  /health:
        \\    get:
        \\      summary: Health check
        \\      responses:
        \\        '200':
        \\          description: ok
    ;

    const json_bytes = try yamlToJson(allocator, yaml);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("paths") != null);
    try std.testing.expect(root.get("servers") != null);
}

test "yamlToJson parses block scalar and flow arrays" {
    const allocator = std.testing.allocator;

    const yaml =
        \\info:
        \\  description: |
        \\    line 1
        \\    line 2
        \\required: [status, code]
    ;

    const json_bytes = try yamlToJson(allocator, yaml);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const info = parsed.value.object.get("info").?.object;
    const desc = info.get("description").?.string;
    try std.testing.expect(std.mem.indexOf(u8, desc, "line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "line 2") != null);

    const required = parsed.value.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 2), required.items.len);
}
