const std = @import("std");
const app_config = @import("../config/config.zig");
const operation = @import("../core/operation.zig");

pub const OperationDetails = struct {
    id: []u8,
    method: []u8,
    path: []u8,
    summary: ?[]u8 = null,
    description: ?[]u8 = null,
    request_body_required: bool = false,
    request_body_content_types: [][]u8,
    request_body_schemas: [][]u8,
    request_body_fields: [][]u8,
    parameters: [][]u8,
    responses: [][]u8,

    pub fn deinit(self: *OperationDetails, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.method);
        allocator.free(self.path);
        if (self.summary) |s| allocator.free(s);
        if (self.description) |d| allocator.free(d);
        freeStringSlice(allocator, self.request_body_content_types);
        freeStringSlice(allocator, self.request_body_schemas);
        freeStringSlice(allocator, self.request_body_fields);
        freeStringSlice(allocator, self.parameters);
        freeStringSlice(allocator, self.responses);
        self.* = undefined;
    }
};

pub fn resolveSpecPath(allocator: std.mem.Allocator) ![]u8 {
    var loaded_cfg = try app_config.loadMerged(allocator);
    defer loaded_cfg.deinit(allocator);

    if (loaded_cfg.config.openapi_spec) |spec| {
        return resolveConfiguredSpecPath(
            allocator,
            spec,
            loaded_cfg.project_path,
            loaded_cfg.global_path,
        );
    }

    if (fileExists("openapi.remote.yaml")) {
        return allocator.dupe(u8, "openapi.remote.yaml");
    }
    if (fileExists("openapi.yaml")) {
        return allocator.dupe(u8, "openapi.yaml");
    }

    return error.SpecPathNotConfigured;
}

fn resolveConfiguredSpecPath(
    allocator: std.mem.Allocator,
    spec: []const u8,
    project_config_path: ?[]const u8,
    global_config_path: []const u8,
) ![]u8 {
    if (isHttpUrl(spec) or std.fs.path.isAbsolute(spec)) {
        return allocator.dupe(u8, spec);
    }

    if (project_config_path) |project_cfg| {
        const project_root = std.fs.path.dirname(std.fs.path.dirname(project_cfg) orelse "") orelse "";
        if (project_root.len > 0) {
            const candidate = try std.fs.path.join(allocator, &.{ project_root, spec });
            if (pathExists(candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    if (pathExists(spec)) {
        return allocator.dupe(u8, spec);
    }

    const global_dir = std.fs.path.dirname(global_config_path) orelse "";
    if (global_dir.len > 0) {
        const candidate = try std.fs.path.join(allocator, &.{ global_dir, spec });
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }

    return allocator.dupe(u8, spec);
}

pub fn loadOperationsFromFile(
    allocator: std.mem.Allocator,
    spec_path: []const u8,
) !operation.OperationList {
    var doc = try parseOpenApiDocument(allocator, spec_path);
    defer doc.deinit();

    const root_obj = asObject(doc.parsed.value) orelse return error.InvalidOpenApiDocument;
    const paths_val = root_obj.get("paths") orelse return error.InvalidOpenApiDocument;
    const paths_obj = asObject(paths_val) orelse return error.InvalidOpenApiDocument;

    var items: std.ArrayList(operation.Operation) = .{};
    defer items.deinit(allocator);

    var it = paths_obj.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const path_item_obj = asObject(entry.value_ptr.*) orelse continue;

        var method_it = path_item_obj.iterator();
        while (method_it.next()) |m_entry| {
            const method_name = m_entry.key_ptr.*;
            if (!isMethod(method_name)) continue;

            var op_item = try makeOperation(allocator, method_name, path);
            errdefer op_item.deinit(allocator);

            const op_obj = asObject(m_entry.value_ptr.*) orelse {
                try items.append(allocator, op_item);
                continue;
            };
            if (getStringField(op_obj, "summary")) |summary| {
                op_item.summary = try allocator.dupe(u8, summary);
            }

            try items.append(allocator, op_item);
        }
    }

    return .{ .items = try items.toOwnedSlice(allocator) };
}

pub fn loadDefaultServerUrlFromFile(
    allocator: std.mem.Allocator,
    spec_path: []const u8,
) !?[]u8 {
    var doc = try parseOpenApiDocument(allocator, spec_path);
    defer doc.deinit();

    const root_obj = asObject(doc.parsed.value) orelse return null;
    const servers_val = root_obj.get("servers") orelse return null;
    const servers_arr = asArray(servers_val) orelse return null;
    if (servers_arr.items.len == 0) return null;

    const first = asObject(servers_arr.items[0]) orelse return null;
    const url = getStringField(first, "url") orelse return null;
    if (url.len == 0) return null;

    const owned = try allocator.dupe(u8, url);
    return owned;
}

pub fn loadOperationDetailsFromFile(
    allocator: std.mem.Allocator,
    spec_path: []const u8,
    operation_id: []const u8,
) !?OperationDetails {
    const sep = std.mem.indexOfScalar(u8, operation_id, ':') orelse return error.InvalidOperationId;
    const wanted_method = operation_id[0..sep];
    const wanted_path = operation_id[sep + 1 ..];

    var doc = try parseOpenApiDocument(allocator, spec_path);
    defer doc.deinit();

    const root_obj = asObject(doc.parsed.value) orelse return error.InvalidOpenApiDocument;
    const paths_val = root_obj.get("paths") orelse return null;
    const paths_obj = asObject(paths_val) orelse return null;

    const path_item_val = paths_obj.get(wanted_path) orelse return null;
    const path_item_obj = asObject(path_item_val) orelse return null;

    var op_val: ?std.json.Value = null;
    var method_iter = path_item_obj.iterator();
    while (method_iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, wanted_method)) {
            op_val = entry.value_ptr.*;
            break;
        }
    }
    if (op_val == null) return null;

    const op_obj = asObject(op_val.?) orelse return null;

    var details: OperationDetails = .{
        .id = try allocator.dupe(u8, operation_id),
        .method = try allocator.dupe(u8, wanted_method),
        .path = try allocator.dupe(u8, wanted_path),
        .request_body_content_types = &.{},
        .request_body_schemas = &.{},
        .request_body_fields = &.{},
        .parameters = &.{},
        .responses = &.{},
    };
    errdefer details.deinit(allocator);

    if (getStringField(op_obj, "summary")) |summary| {
        details.summary = try allocator.dupe(u8, summary);
    }
    if (getStringField(op_obj, "description")) |description| {
        details.description = try allocator.dupe(u8, description);
    }

    var parameters: std.ArrayList([]u8) = .{};
    defer parameters.deinit(allocator);

    var rb_content_types: std.ArrayList([]u8) = .{};
    defer rb_content_types.deinit(allocator);

    var rb_schemas: std.ArrayList([]u8) = .{};
    defer rb_schemas.deinit(allocator);

    var rb_fields: std.ArrayList([]u8) = .{};
    defer rb_fields.deinit(allocator);

    var responses: std.ArrayList([]u8) = .{};
    defer responses.deinit(allocator);

    if (path_item_obj.get("parameters")) |path_params_val| {
        try appendParameterList(allocator, doc.parsed.value, doc.source_path, path_params_val, &parameters);
    }
    if (op_obj.get("parameters")) |op_params_val| {
        try appendParameterList(allocator, doc.parsed.value, doc.source_path, op_params_val, &parameters);
    }

    if (op_obj.get("requestBody")) |rb_val| {
        var rb_resolved = try resolveRefsAny(allocator, doc.parsed.value, doc.source_path, rb_val);
        defer rb_resolved.deinit();
        const rb_obj = asObject(rb_resolved.value) orelse null;
        if (rb_obj) |o| {
            details.request_body_required = getBoolField(o, "required") orelse false;

            if (o.get("content")) |content_val| {
                const content_obj = asObject(content_val) orelse null;
                if (content_obj) |co| {
                    var ct_it = co.iterator();
                    while (ct_it.next()) |ct_entry| {
                        try rb_content_types.append(allocator, try allocator.dupe(u8, ct_entry.key_ptr.*));

                        const media_obj = asObject(ct_entry.value_ptr.*) orelse continue;
                        if (media_obj.get("schema")) |schema_val| {
                            const summary = try summarizeSchemaWithRef(
                                allocator,
                                rb_resolved.root,
                                rb_resolved.spec_path,
                                schema_val,
                            );
                            defer allocator.free(summary);
                            try rb_schemas.append(allocator, try allocator.dupe(u8, summary));
                            try appendSchemaFieldLines(
                                allocator,
                                rb_resolved.root,
                                rb_resolved.spec_path,
                                schema_val,
                                &rb_fields,
                            );
                        }
                    }
                }
            }
        }
    }

    if (op_obj.get("responses")) |responses_val| {
        const responses_obj = asObject(responses_val) orelse null;
        if (responses_obj) |ro| {
            var r_it = ro.iterator();
            while (r_it.next()) |resp_entry| {
                const code = resp_entry.key_ptr.*;
                var resolved_resp = try resolveRefsAny(
                    allocator,
                    doc.parsed.value,
                    doc.source_path,
                    resp_entry.value_ptr.*,
                );
                defer resolved_resp.deinit();
                const resp_obj = asObject(resolved_resp.value) orelse continue;

                const desc = getStringField(resp_obj, "description") orelse "";

                var content_types: std.ArrayList([]u8) = .{};
                defer deinitOwnedArrayListStrings(allocator, &content_types);

                var schemas: std.ArrayList([]u8) = .{};
                defer deinitOwnedArrayListStrings(allocator, &schemas);

                if (resp_obj.get("content")) |content_val| {
                    const content_obj = asObject(content_val) orelse null;
                    if (content_obj) |co| {
                        var c_it = co.iterator();
                        while (c_it.next()) |c_entry| {
                            try content_types.append(allocator, try allocator.dupe(u8, c_entry.key_ptr.*));

                            const media_obj = asObject(c_entry.value_ptr.*) orelse continue;
                            if (media_obj.get("schema")) |schema_val| {
                                const schema_summary = try summarizeSchemaWithRef(
                                    allocator,
                                    resolved_resp.root,
                                    resolved_resp.spec_path,
                                    schema_val,
                                );
                                defer allocator.free(schema_summary);
                                try schemas.append(allocator, try allocator.dupe(u8, schema_summary));
                            }
                        }
                    }
                }

                const line = try formatResponseLine(allocator, code, desc, content_types.items, schemas.items);
                try responses.append(allocator, line);
            }
        }
    }

    details.parameters = try parameters.toOwnedSlice(allocator);
    details.request_body_content_types = try rb_content_types.toOwnedSlice(allocator);
    details.request_body_schemas = try rb_schemas.toOwnedSlice(allocator);
    details.request_body_fields = try rb_fields.toOwnedSlice(allocator);
    details.responses = try responses.toOwnedSlice(allocator);

    return details;
}

const ParsedDocument = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(std.json.Value),
    source_path: []u8,

    fn deinit(self: *ParsedDocument) void {
        self.allocator.free(self.source_path);
        self.parsed.deinit();
    }
};

const ResolvedValue = struct {
    value: std.json.Value,
    root: std.json.Value,
    spec_path: []const u8,
    external_doc: ?ParsedDocument = null,

    fn deinit(self: *ResolvedValue) void {
        if (self.external_doc) |*doc| doc.deinit();
    }
};

fn parseOpenApiDocument(allocator: std.mem.Allocator, spec_path: []const u8) !ParsedDocument {
    const normalized_path = try normalizeSpecPath(allocator, spec_path);
    errdefer allocator.free(normalized_path);

    const bytes = try readFile(allocator, spec_path);
    defer allocator.free(bytes);

    const first = firstNonWhitespace(bytes) orelse return error.InvalidOpenApiDocument;
    if (first == '{' or first == '[') {
        return .{
            .allocator = allocator,
            .parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}),
            .source_path = normalized_path,
        };
    }

    const json_bytes = try yamlToJsonViaRuby(allocator, spec_path);
    defer allocator.free(json_bytes);

    return .{
        .allocator = allocator,
        .parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}),
        .source_path = normalized_path,
    };
}

fn parseOpenApiDocumentFromUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedDocument {
    const normalized_path = try allocator.dupe(u8, url);
    errdefer allocator.free(normalized_path);

    const bytes = try readUrl(allocator, url);
    defer allocator.free(bytes);

    const first = firstNonWhitespace(bytes) orelse return error.InvalidOpenApiDocument;
    if (first == '{' or first == '[') {
        return .{
            .allocator = allocator,
            .parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}),
            .source_path = normalized_path,
        };
    }

    const json_bytes = try yamlTextToJsonViaRuby(allocator, bytes);
    defer allocator.free(json_bytes);

    return .{
        .allocator = allocator,
        .parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}),
        .source_path = normalized_path,
    };
}

fn normalizeSpecPath(allocator: std.mem.Allocator, spec_path: []const u8) ![]u8 {
    if (isHttpUrl(spec_path)) return allocator.dupe(u8, spec_path);
    if (std.fs.path.isAbsolute(spec_path)) return allocator.dupe(u8, spec_path);
    return std.fs.cwd().realpathAlloc(allocator, spec_path);
}

fn yamlToJsonViaRuby(allocator: std.mem.Allocator, spec_path: []const u8) ![]u8 {
    var child = std.process.Child.init(&.{
        "ruby",
        "-ryaml",
        "-rjson",
        "-e",
        "obj = YAML.safe_load(File.read(ARGV[0]), aliases: true); puts JSON.generate(obj)",
        spec_path,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout_bytes = try child.stdout.?.readToEndAlloc(allocator, 16 * 1024 * 1024);
    errdefer allocator.free(stdout_bytes);

    const stderr_bytes = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr_bytes);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.YamlParseFailed;
        },
        else => return error.YamlParseFailed,
    }

    return stdout_bytes;
}

fn yamlTextToJsonViaRuby(allocator: std.mem.Allocator, yaml_text: []const u8) ![]u8 {
    var child = std.process.Child.init(&.{
        "ruby",
        "-ryaml",
        "-rjson",
        "-e",
        "obj = YAML.safe_load(STDIN.read, aliases: true); puts JSON.generate(obj)",
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    try child.stdin.?.writeAll(yaml_text);
    child.stdin.?.close();
    child.stdin = null;

    const stdout_bytes = try child.stdout.?.readToEndAlloc(allocator, 16 * 1024 * 1024);
    errdefer allocator.free(stdout_bytes);

    const stderr_bytes = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr_bytes);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.YamlParseFailed;
        },
        else => return error.YamlParseFailed,
    }

    return stdout_bytes;
}

fn readUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&.{});

    var read_buf: [4096]u8 = undefined;
    var body_reader = response.reader(&read_buf);
    return body_reader.allocRemaining(allocator, .unlimited);
}

fn appendParameterList(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    params_val: std.json.Value,
    out: *std.ArrayList([]u8),
) !void {
    const arr = asArray(params_val) orelse return;
    for (arr.items) |raw_param| {
        var resolved = try resolveRefsAny(allocator, root, spec_path, raw_param);
        defer resolved.deinit();
        const param_obj = asObject(resolved.value) orelse continue;

        const name = getStringField(param_obj, "name") orelse "(unnamed)";
        const location = getStringField(param_obj, "in") orelse "unknown";
        const required = getBoolField(param_obj, "required") orelse false;

        const line = if (required)
            try std.fmt.allocPrint(allocator, "{s} [{s}] required", .{ name, location })
        else
            try std.fmt.allocPrint(allocator, "{s} [{s}] optional", .{ name, location });
        try out.append(allocator, line);
    }
}

fn formatResponseLine(
    allocator: std.mem.Allocator,
    code: []const u8,
    desc: []const u8,
    content_types: []const []u8,
    schemas: []const []u8,
) ![]u8 {
    const ct = if (content_types.len > 0) content_types[0] else "";
    const schema = pickPreferredSchema(schemas) orelse "";

    const has_desc = desc.len > 0;
    const has_ct = ct.len > 0;
    const has_schema = schema.len > 0;

    return if (has_desc and has_ct and has_schema)
        std.fmt.allocPrint(allocator, "{s} - {s} | content:{s}{s} | schema:{s}{s}", .{
            code,
            desc,
            ct,
            if (content_types.len > 1) " (+more)" else "",
            schema,
            if (schemas.len > 1) " (+more)" else "",
        })
    else if (has_desc and has_ct)
        std.fmt.allocPrint(allocator, "{s} - {s} | content:{s}{s}", .{
            code,
            desc,
            ct,
            if (content_types.len > 1) " (+more)" else "",
        })
    else if (has_desc and has_schema)
        std.fmt.allocPrint(allocator, "{s} - {s} | schema:{s}{s}", .{
            code,
            desc,
            schema,
            if (schemas.len > 1) " (+more)" else "",
        })
    else if (has_desc)
        std.fmt.allocPrint(allocator, "{s} - {s}", .{ code, desc })
    else if (has_ct and has_schema)
        std.fmt.allocPrint(allocator, "{s} | content:{s}{s} | schema:{s}{s}", .{
            code,
            ct,
            if (content_types.len > 1) " (+more)" else "",
            schema,
            if (schemas.len > 1) " (+more)" else "",
        })
    else if (has_ct)
        std.fmt.allocPrint(allocator, "{s} | content:{s}{s}", .{
            code,
            ct,
            if (content_types.len > 1) " (+more)" else "",
        })
    else if (has_schema)
        std.fmt.allocPrint(allocator, "{s} | schema:{s}{s}", .{
            code,
            schema,
            if (schemas.len > 1) " (+more)" else "",
        })
    else
        allocator.dupe(u8, code);
}

fn summarizeSchemaWithRef(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    schema_val: std.json.Value,
) anyerror![]u8 {
    const ref_name = extractRefName(schema_val);
    const summary = try summarizeSchema(allocator, root, spec_path, schema_val);
    defer allocator.free(summary);

    if (ref_name) |name| {
        return std.fmt.allocPrint(allocator, "$ref:{s} -> {s}", .{ name, summary });
    }
    return allocator.dupe(u8, summary);
}

fn summarizeSchema(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    raw_schema: std.json.Value,
) anyerror![]u8 {
    var resolved = try resolveRefsAny(allocator, root, spec_path, raw_schema);
    defer resolved.deinit();
    const obj = asObject(resolved.value) orelse return allocator.dupe(u8, "unknown");

    var parts: std.ArrayList([]u8) = .{};
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }

    if (getStringField(obj, "type")) |t| {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "type:{s}", .{t}));
    }

    if (obj.get("properties")) |props_val| {
        if (asObject(props_val)) |props_obj| {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "props:{d}", .{props_obj.count()}));
        }
    }

    if (obj.get("required")) |required_val| {
        if (asArray(required_val)) |arr| {
            const rendered = try renderStringArray(allocator, arr);
            defer allocator.free(rendered);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "required:{s}", .{rendered}));
        }
    }

    if (obj.get("items")) |items_val| {
        const item_summary = try summarizeSchemaWithRef(allocator, resolved.root, resolved.spec_path, items_val);
        defer allocator.free(item_summary);
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "items:{s}", .{item_summary}));
    }

    if (obj.get("additionalProperties")) |ap_val| {
        switch (ap_val) {
            .bool => |b| try parts.append(allocator, try allocator.dupe(u8, if (b) "additionalProperties:true" else "additionalProperties:false")),
            else => {
                const ap_summary = try summarizeSchemaWithRef(allocator, resolved.root, resolved.spec_path, ap_val);
                defer allocator.free(ap_summary);
                try parts.append(allocator, try std.fmt.allocPrint(allocator, "additionalProperties:{s}", .{ap_summary}));
            },
        }
    }

    try appendComposedSchemas(allocator, resolved.root, resolved.spec_path, obj, "allOf", &parts);
    try appendComposedSchemas(allocator, resolved.root, resolved.spec_path, obj, "anyOf", &parts);
    try appendComposedSchemas(allocator, resolved.root, resolved.spec_path, obj, "oneOf", &parts);

    if (parts.items.len == 0) return allocator.dupe(u8, "unknown");

    return joinParts(allocator, parts.items);
}

fn appendSchemaFieldLines(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    raw_schema: std.json.Value,
    out: *std.ArrayList([]u8),
) anyerror!void {
    var resolved = try resolveRefsAny(allocator, root, spec_path, raw_schema);
    defer resolved.deinit();
    try appendSchemaFieldLinesResolved(allocator, resolved.root, resolved.spec_path, resolved.value, out);
}

fn appendSchemaFieldLinesResolved(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    schema_val: std.json.Value,
    out: *std.ArrayList([]u8),
) anyerror!void {
    const obj = asObject(schema_val) orelse return;

    if (obj.get("properties")) |props_val| {
        if (asObject(props_val)) |props_obj| {
            var props_it = props_obj.iterator();
            while (props_it.next()) |entry| {
                const name = entry.key_ptr.*;
                const required = isRequiredProperty(obj, name);
                const type_name = try inferSchemaTypeName(allocator, root, spec_path, entry.value_ptr.*);
                defer allocator.free(type_name);

                const line = if (required)
                    try std.fmt.allocPrint(allocator, "{s}: {s} (required)", .{ name, type_name })
                else
                    try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, type_name });

                if (!containsString(out.items, line)) {
                    try out.append(allocator, line);
                } else {
                    allocator.free(line);
                }
            }
        }
    }

    const composed_keys = [_][]const u8{ "allOf", "anyOf", "oneOf" };
    for (composed_keys) |key| {
        const composed = obj.get(key) orelse continue;
        const arr = asArray(composed) orelse continue;
        for (arr.items) |part| {
            try appendSchemaFieldLines(allocator, root, spec_path, part, out);
        }
    }
}

fn inferSchemaTypeName(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    raw_schema: std.json.Value,
) anyerror![]u8 {
    if (extractRefName(raw_schema)) |ref_name| {
        return std.fmt.allocPrint(allocator, "$ref:{s}", .{ref_name});
    }

    var resolved = try resolveRefsAny(allocator, root, spec_path, raw_schema);
    defer resolved.deinit();
    const obj = asObject(resolved.value) orelse return allocator.dupe(u8, "unknown");

    if (getStringField(obj, "type")) |t| {
        if (std.mem.eql(u8, t, "array")) {
            if (obj.get("items")) |items| {
                const item_type = try inferSchemaTypeName(allocator, resolved.root, resolved.spec_path, items);
                defer allocator.free(item_type);
                return std.fmt.allocPrint(allocator, "array<{s}>", .{item_type});
            }
        }
        return allocator.dupe(u8, t);
    }

    if (obj.get("enum") != null) return allocator.dupe(u8, "enum");
    if (obj.get("oneOf") != null) return allocator.dupe(u8, "oneOf");
    if (obj.get("anyOf") != null) return allocator.dupe(u8, "anyOf");
    if (obj.get("allOf") != null) return allocator.dupe(u8, "allOf");
    if (obj.get("properties") != null) return allocator.dupe(u8, "object");
    return allocator.dupe(u8, "unknown");
}

fn isRequiredProperty(schema_obj: std.json.ObjectMap, prop_name: []const u8) bool {
    const required_val = schema_obj.get("required") orelse return false;
    const arr = asArray(required_val) orelse return false;
    for (arr.items) |v| {
        const s = asString(v) orelse continue;
        if (std.mem.eql(u8, s, prop_name)) return true;
    }
    return false;
}

fn containsString(values: []const []u8, wanted: []const u8) bool {
    for (values) |v| {
        if (std.mem.eql(u8, v, wanted)) return true;
    }
    return false;
}

fn appendComposedSchemas(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    obj: std.json.ObjectMap,
    key: []const u8,
    parts: *std.ArrayList([]u8),
) anyerror!void {
    const composed_val = obj.get(key) orelse return;
    const arr = asArray(composed_val) orelse return;

    var rendered_items: std.ArrayList([]u8) = .{};
    defer {
        for (rendered_items.items) |s| allocator.free(s);
        rendered_items.deinit(allocator);
    }

    for (arr.items) |item| {
        const summary = try summarizeSchemaWithRef(allocator, root, spec_path, item);
        try rendered_items.append(allocator, summary);
    }

    const joined = try joinParts(allocator, rendered_items.items);
    defer allocator.free(joined);

    try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}:[{s}]", .{ key, joined }));
}

fn joinParts(allocator: std.mem.Allocator, parts: []const []u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    for (parts, 0..) |p, idx| {
        if (idx != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, p);
    }

    return out.toOwnedSlice(allocator);
}

fn renderStringArray(allocator: std.mem.Allocator, arr: std.json.Array) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (arr.items, 0..) |item, idx| {
        const s = asString(item) orelse continue;
        if (idx != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, s);
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}

const RefParts = struct {
    document: []const u8,
    pointer: ?[]const u8,
};

fn splitRef(ref_str: []const u8) RefParts {
    const hash = std.mem.indexOfScalar(u8, ref_str, '#');
    if (hash) |i| {
        const doc = ref_str[0..i];
        const after = ref_str[i + 1 ..];
        if (after.len == 0) return .{ .document = doc, .pointer = null };
        if (after[0] == '/') return .{ .document = doc, .pointer = after[1..] };
        return .{ .document = doc, .pointer = after };
    }
    return .{ .document = ref_str, .pointer = null };
}

fn resolveRefDocumentPath(
    allocator: std.mem.Allocator,
    current_spec_path: []const u8,
    ref_doc: []const u8,
) ![]u8 {
    if (isHttpUrl(ref_doc)) return allocator.dupe(u8, ref_doc);

    if (isHttpUrl(current_spec_path)) {
        const slash = std.mem.lastIndexOfScalar(u8, current_spec_path, '/') orelse return error.InvalidRefPath;
        const base = current_spec_path[0 .. slash + 1];
        return std.mem.concat(allocator, u8, &.{ base, ref_doc });
    }

    if (std.fs.path.isAbsolute(ref_doc)) return allocator.dupe(u8, ref_doc);

    const base_dir = std.fs.path.dirname(current_spec_path) orelse ".";
    return std.fs.path.join(allocator, &.{ base_dir, ref_doc });
}

fn isHttpUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

fn resolveRefsAny(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    spec_path: []const u8,
    value: std.json.Value,
) !ResolvedValue {
    var current = value;
    var current_root = root;
    var current_path = spec_path;
    var external_doc: ?ParsedDocument = null;

    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        const obj = asObject(current) orelse break;
        const ref_val = obj.get("$ref") orelse break;
        const ref_str = asString(ref_val) orelse break;

        const parts = splitRef(ref_str);
        if (parts.document.len == 0) {
            if (parts.pointer) |pointer| {
                current = resolveJsonPointer(allocator, current_root, pointer) orelse break;
                continue;
            }
            break;
        }

        if (external_doc != null) {
            external_doc.?.deinit();
            external_doc = null;
        }

        const target_doc_path = try resolveRefDocumentPath(allocator, current_path, parts.document);
        errdefer allocator.free(target_doc_path);

        var doc = if (isHttpUrl(target_doc_path))
            try parseOpenApiDocumentFromUrl(allocator, target_doc_path)
        else
            try parseOpenApiDocument(allocator, target_doc_path);

        allocator.free(target_doc_path);

        var ext_value: std.json.Value = doc.parsed.value;
        if (parts.pointer) |pointer| {
            ext_value = resolveJsonPointer(allocator, doc.parsed.value, pointer) orelse {
                doc.deinit();
                return error.RefPointerNotFound;
            };
        }

        current = ext_value;
        current_root = doc.parsed.value;
        current_path = doc.source_path;
        external_doc = doc;
    }

    return .{
        .value = current,
        .root = current_root,
        .spec_path = current_path,
        .external_doc = external_doc,
    };
}

fn resolveJsonPointer(allocator: std.mem.Allocator, root: std.json.Value, pointer: []const u8) ?std.json.Value {
    var cur = root;
    var seg_it = std.mem.splitScalar(u8, pointer, '/');
    while (seg_it.next()) |seg_raw| {
        if (seg_raw.len == 0) continue;
        const seg = unescapeJsonPointerOwned(allocator, seg_raw) catch return null;
        defer allocator.free(seg);
        switch (cur) {
            .object => |obj| {
                cur = obj.get(seg) orelse return null;
            },
            .array => |arr| {
                const idx = std.fmt.parseInt(usize, seg, 10) catch return null;
                if (idx >= arr.items.len) return null;
                cur = arr.items[idx];
            },
            else => return null,
        }
    }
    return cur;
}

fn unescapeJsonPointerOwned(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (segment[i] == '~' and i + 1 < segment.len) {
            if (segment[i + 1] == '0') {
                try out.append(allocator, '~');
                i += 1;
                continue;
            }
            if (segment[i + 1] == '1') {
                try out.append(allocator, '/');
                i += 1;
                continue;
            }
        }
        try out.append(allocator, segment[i]);
    }

    return out.toOwnedSlice(allocator);
}

fn extractRefName(value: std.json.Value) ?[]const u8 {
    const obj = asObject(value) orelse return null;
    const ref_val = obj.get("$ref") orelse return null;
    const ref_str = asString(ref_val) orelse return null;

    var it = std.mem.splitScalar(u8, ref_str, '/');
    var last: ?[]const u8 = null;
    while (it.next()) |part| {
        if (part.len > 0) last = part;
    }
    return last;
}

fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn asArray(v: std.json.Value) ?std.json.Array {
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

fn asString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return asString(v);
}

fn getBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn makeOperation(
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
) !operation.Operation {
    const method_owned = try allocator.dupe(u8, method);
    errdefer allocator.free(method_owned);

    const path_owned = try allocator.dupe(u8, path);
    errdefer allocator.free(path_owned);

    const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ method, path });
    errdefer allocator.free(id);

    return .{
        .id = id,
        .method = method_owned,
        .path = path_owned,
    };
}

fn isMethod(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "get") or
        std.ascii.eqlIgnoreCase(name, "post") or
        std.ascii.eqlIgnoreCase(name, "put") or
        std.ascii.eqlIgnoreCase(name, "patch") or
        std.ascii.eqlIgnoreCase(name, "delete") or
        std.ascii.eqlIgnoreCase(name, "head") or
        std.ascii.eqlIgnoreCase(name, "options") or
        std.ascii.eqlIgnoreCase(name, "trace");
}

fn pickPreferredSchema(schemas: []const []u8) ?[]const u8 {
    for (schemas) |s| {
        if (std.mem.startsWith(u8, s, "$ref:")) return s;
    }
    if (schemas.len == 0) return null;
    return schemas[0];
}

fn firstNonWhitespace(s: []const u8) ?u8 {
    for (s) |c| {
        if (!std.ascii.isWhitespace(c)) return c;
    }
    return null;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, 32 * 1024 * 1024);
    }

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 32 * 1024 * 1024);
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        return true;
    }
    return fileExists(path);
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |v| allocator.free(v);
    allocator.free(values);
}

fn freeOwnedArrayListStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |v| allocator.free(v);
    list.clearRetainingCapacity();
}

fn deinitOwnedArrayListStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    freeOwnedArrayListStrings(allocator, list);
    list.deinit(allocator);
}
