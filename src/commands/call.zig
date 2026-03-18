const std = @import("std");
const http = @import("../http/client.zig");
const app_config = @import("../config/config.zig");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        printUsage();
        return;
    }

    var parsed = parseCallArgs(allocator, args) catch |err| {
        printCallError(err);
        return;
    };
    defer parsed.deinit(allocator);

    if (parsed.use_name) |preset_name| {
        applyPreset(allocator, &parsed, preset_name) catch |err| {
            printCallError(err);
            return;
        };
    }

    const target = parsed.target orelse {
        printCallError(error.MissingTarget);
        return;
    };

    if (parsed.save_name) |preset_name| {
        savePreset(allocator, parsed, preset_name) catch |err| {
            printCallError(err);
            return;
        };
    }

    var loaded_cfg = try app_config.loadMerged(allocator);
    defer loaded_cfg.deinit(allocator);

    const resolved_target = resolveTarget(allocator, target, loaded_cfg.config.base_url, parsed) catch |err| {
        if (err == error.OperationNotFound) {
            if (trySuggestOperationId(allocator, target)) |hint| {
                defer allocator.free(hint);
                std.debug.print("Did you mean: {s}\n", .{hint});
            }
        }
        printCallError(err);
        return;
    };
    defer allocator.free(resolved_target.url);
    defer allocator.free(resolved_target.method_name);

    var body = resolveBody(allocator, parsed.body) catch |err| {
        printCallError(err);
        return;
    };
    defer if (body.owned) |buf| allocator.free(buf);

    var body_source: ?BodySource = if (body.slice != null) .explicit else null;

    if (parsed.use_example and body.slice == null) {
        const maybe_example = autoBodyForOperation(allocator, target, false) catch |err| {
            printCallError(err);
            return;
        };
        if (maybe_example) |auto_body| {
            body.slice = auto_body.body;
            body.owned = auto_body.body;
            body_source = .generated;
        }
    }

    if (isOperationId(target) and body.slice == null and !parsed.no_auto_body) {
        const maybe_auto = autoBodyForOperation(allocator, target, !parsed.no_body_cache) catch |err| {
            printCallError(err);
            return;
        };
        if (maybe_auto) |auto_body| {
            body.slice = auto_body.body;
            body.owned = auto_body.body;
            body_source = auto_body.source;
        }
    }

    if (parsed.explain) {
        printExplain(target, resolved_target, parsed, body_source);
    }

    if (parsed.dry_run) {
        printCallResultText(resolved_target, body.slice, null, null, body_source, true, parsed.show_body_source);
        if (parsed.output == .json) {
            printCallResultJson(resolved_target, body.slice, null, null, body_source, true);
        }
        return;
    }

    const content_type: ?[]const u8 = if (body.slice != null) "application/json" else null;

    const res = http.request(
        allocator,
        resolved_target.method,
        resolved_target.url,
        body.slice,
        content_type,
    ) catch |err| {
        printCallError(err);
        return;
    };
    defer allocator.free(res.body);

    if (parsed.output == .json) {
        printCallResultJson(resolved_target, body.slice, res.status, res.body, body_source, false);
    } else {
        printCallResultText(resolved_target, body.slice, res.status, res.body, body_source, false, parsed.show_body_source);
    }

    appendCallHistory(allocator, .{
        .target = target,
        .method = resolved_target.method_name,
        .url = resolved_target.url,
        .status = res.status,
        .body_source = bodySourceLabel(body_source),
        .body = body.slice,
    }) catch {};

    if (isOperationId(target) and body.slice != null and res.status >= 200 and res.status < 300 and !parsed.no_body_cache) {
        rememberSuccessfulBody(allocator, target, body.slice.?) catch {};
    }
}

fn trySuggestOperationId(allocator: std.mem.Allocator, target: []const u8) ?[]u8 {
    return resolveFuzzyOperationId(allocator, target) catch null;
}

const OutputMode = enum {
    text,
    json,
};

const CallArgs = struct {
    target: ?[]u8 = null,
    method_override: ?[]u8 = null,
    body: ?[]u8 = null,
    use_name: ?[]u8 = null,
    save_name: ?[]u8 = null,
    use_example: bool = false,
    no_auto_body: bool = false,
    no_body_cache: bool = false,
    show_body_source: bool = false,
    dry_run: bool = false,
    explain: bool = false,
    output: OutputMode = .text,
    path_params: []KeyValue,
    query_params: []KeyValue,

    fn deinit(self: *CallArgs, allocator: std.mem.Allocator) void {
        if (self.target) |v| allocator.free(v);
        if (self.method_override) |v| allocator.free(v);
        if (self.body) |v| allocator.free(v);
        if (self.use_name) |v| allocator.free(v);
        if (self.save_name) |v| allocator.free(v);

        for (self.path_params) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(self.path_params);

        for (self.query_params) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(self.query_params);
        self.* = undefined;
    }
};

const KeyValue = struct {
    key: []u8,
    value: []u8,
};

const ResolvedTarget = struct {
    method: std.http.Method,
    method_name: []u8,
    url: []u8,
};

const ResolvedBody = struct {
    slice: ?[]const u8,
    owned: ?[]u8,
};

const BodySource = enum {
    explicit,
    cache,
    generated,
    fallback,
};

const AutoBody = struct {
    body: []u8,
    source: BodySource,
};

const HistoryEntryInput = struct {
    target: []const u8,
    method: []const u8,
    url: []const u8,
    status: u16,
    body_source: []const u8,
    body: ?[]const u8,
};

const PresetRaw = struct {
    target: ?[]const u8 = null,
    method_override: ?[]const u8 = null,
    body: ?[]const u8 = null,
    path_params: ?[]RawKeyValue = null,
    query_params: ?[]RawKeyValue = null,
};

const RawKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn parseCallArgs(allocator: std.mem.Allocator, args: []const []const u8) !CallArgs {
    var path_params: std.ArrayList(KeyValue) = .{};
    defer path_params.deinit(allocator);

    var query_params: std.ArrayList(KeyValue) = .{};
    defer query_params.deinit(allocator);

    var out: CallArgs = .{
        .path_params = &.{},
        .query_params = &.{},
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--param")) {
            if (i + 1 >= args.len) return error.MissingParamValue;
            i += 1;
            const kv = try parseKeyValueOwned(allocator, args[i]);
            try path_params.append(allocator, kv);
            continue;
        }
        if (std.mem.eql(u8, arg, "--query")) {
            if (i + 1 >= args.len) return error.MissingQueryValue;
            i += 1;
            const kv = try parseKeyValueOwned(allocator, args[i]);
            try query_params.append(allocator, kv);
            continue;
        }
        if (std.mem.eql(u8, arg, "--body")) {
            if (i + 1 >= args.len) return error.MissingBodyValue;
            i += 1;
            if (out.body) |old| allocator.free(old);
            out.body = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--method")) {
            if (i + 1 >= args.len) return error.MissingMethodValue;
            i += 1;
            if (out.method_override) |old| allocator.free(old);
            out.method_override = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--use")) {
            if (i + 1 >= args.len) return error.MissingPresetName;
            i += 1;
            if (out.use_name) |old| allocator.free(old);
            out.use_name = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--save")) {
            if (i + 1 >= args.len) return error.MissingPresetName;
            i += 1;
            if (out.save_name) |old| allocator.free(old);
            out.save_name = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--example")) {
            out.use_example = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutputMode;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) {
                out.output = .json;
            } else if (std.mem.eql(u8, args[i], "text")) {
                out.output = .text;
            } else {
                return error.InvalidOutputMode;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-auto-body")) {
            out.no_auto_body = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-body-cache")) {
            out.no_body_cache = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--show-body-source")) {
            out.show_body_source = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            out.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--explain")) {
            out.explain = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownFlag;
        if (out.target != null) return error.UnexpectedPositionalArg;
        out.target = try allocator.dupe(u8, arg);
    }

    out.path_params = try path_params.toOwnedSlice(allocator);
    out.query_params = try query_params.toOwnedSlice(allocator);
    return out;
}

fn applyPreset(allocator: std.mem.Allocator, parsed: *CallArgs, name: []const u8) !void {
    const preset_path = try presetFilePath(allocator, name, false);
    defer allocator.free(preset_path);

    const file = try std.fs.openFileAbsolute(preset_path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed_json = try std.json.parseFromSlice(PresetRaw, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed_json.deinit();

    if (parsed.target == null) {
        if (parsed_json.value.target) |target| {
            parsed.target = try allocator.dupe(u8, target);
        }
    }
    if (parsed.method_override == null) {
        if (parsed_json.value.method_override) |method| {
            parsed.method_override = try allocator.dupe(u8, method);
        }
    }
    if (parsed.body == null) {
        if (parsed_json.value.body) |body| {
            parsed.body = try allocator.dupe(u8, body);
        }
    }

    if (parsed.path_params.len == 0) {
        if (parsed_json.value.path_params) |params| {
            allocator.free(parsed.path_params);
            parsed.path_params = try cloneRawKeyValues(allocator, params);
        }
    }
    if (parsed.query_params.len == 0) {
        if (parsed_json.value.query_params) |params| {
            allocator.free(parsed.query_params);
            parsed.query_params = try cloneRawKeyValues(allocator, params);
        }
    }
}

fn savePreset(allocator: std.mem.Allocator, parsed: CallArgs, name: []const u8) !void {
    const preset_path = try presetFilePath(allocator, name, true);
    defer allocator.free(preset_path);

    const SaveStruct = struct {
        target: ?[]const u8,
        method_override: ?[]const u8,
        body: ?[]const u8,
        path_params: []const KeyValue,
        query_params: []const KeyValue,
    };

    const json_text = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(SaveStruct{
        .target = parsed.target,
        .method_override = parsed.method_override,
        .body = parsed.body,
        .path_params = parsed.path_params,
        .query_params = parsed.query_params,
    }, .{})});
    defer allocator.free(json_text);

    const file = try std.fs.createFileAbsolute(preset_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json_text);

    std.debug.print("Saved preset: {s}\n", .{name});
}

fn cloneRawKeyValues(allocator: std.mem.Allocator, values: []RawKeyValue) ![]KeyValue {
    var out: std.ArrayList(KeyValue) = .{};
    defer out.deinit(allocator);

    for (values) |kv| {
        try out.append(allocator, .{
            .key = try allocator.dupe(u8, kv.key),
            .value = try allocator.dupe(u8, kv.value),
        });
    }

    return out.toOwnedSlice(allocator);
}

fn presetFilePath(allocator: std.mem.Allocator, name: []const u8, create_dirs: bool) ![]u8 {
    const orion_dir = if (create_dirs)
        (try ensureOrionDirForState(allocator)) orelse return error.CannotCreateProjectStateDir
    else
        (try findNearestOrionDir(allocator)) orelse return error.PresetNotFound;
    defer allocator.free(orion_dir);

    const presets_dir = try std.fs.path.join(allocator, &.{ orion_dir, "presets" });
    defer allocator.free(presets_dir);

    if (create_dirs) {
        std.fs.makeDirAbsolute(presets_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(filename);

    return std.fs.path.join(allocator, &.{ presets_dir, filename });
}

fn resolveTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    base_url: ?[]const u8,
    parsed: CallArgs,
) !ResolvedTarget {
    if (!isOperationId(target) and !std.mem.startsWith(u8, target, "/") and
        !std.mem.startsWith(u8, target, "http://") and
        !std.mem.startsWith(u8, target, "https://"))
    {
        if (try resolveFuzzyOperationId(allocator, target)) |resolved_id| {
            defer allocator.free(resolved_id);
            return resolveOperationTarget(allocator, resolved_id, base_url, parsed);
        }
    }

    if (isOperationId(target)) {
        return resolveOperationTarget(allocator, target, base_url, parsed);
    }

    const method_name = parsed.method_override orelse "GET";
    const method = try parseMethod(method_name);
    const url = try resolveUrl(allocator, target, base_url, parsed.query_params);
    return .{
        .method = method,
        .method_name = try allocator.dupe(u8, method_name),
        .url = url,
    };
}

fn resolveFuzzyOperationId(allocator: std.mem.Allocator, query: []const u8) !?[]u8 {
    const spec_path = loader.resolveSpecPath(allocator) catch return null;
    defer allocator.free(spec_path);

    var operations = loader.loadOperationsFromFile(allocator, spec_path) catch return null;
    defer operations.deinit(allocator);

    var best_score: usize = 0;
    var best_id: ?[]u8 = null;
    errdefer if (best_id) |v| allocator.free(v);

    for (operations.items) |op| {
        const score = fuzzyScore(query, op.id, op.path, op.summary);
        if (score <= best_score) continue;
        if (best_id) |old| allocator.free(old);
        best_score = score;
        best_id = try allocator.dupe(u8, op.id);
    }

    if (best_score < 2) {
        if (best_id) |v| allocator.free(v);
        return null;
    }
    return best_id;
}

fn fuzzyScore(query: []const u8, id: []const u8, path: []const u8, summary: ?[]const u8) usize {
    var score: usize = 0;
    if (std.mem.eql(u8, query, id)) score += 100;
    if (std.mem.indexOf(u8, id, query) != null) score += 20;
    if (std.mem.indexOf(u8, path, query) != null) score += 10;
    if (summary) |s| {
        if (std.mem.indexOf(u8, s, query) != null) score += 5;
    }
    return score;
}

fn resolveOperationTarget(
    allocator: std.mem.Allocator,
    operation_id: []const u8,
    base_url: ?[]const u8,
    parsed: CallArgs,
) !ResolvedTarget {
    const spec_path = try loader.resolveSpecPath(allocator);
    defer allocator.free(spec_path);

    var discovered_base_url: ?[]u8 = null;
    defer if (discovered_base_url) |url| allocator.free(url);

    const effective_base_url: ?[]const u8 = if (base_url) |configured|
        configured
    else blk: {
        discovered_base_url = try loader.loadDefaultServerUrlFromFile(allocator, spec_path);
        break :blk discovered_base_url;
    };

    var operations = try loader.loadOperationsFromFile(allocator, spec_path);
    defer operations.deinit(allocator);

    for (operations.items) |op| {
        if (!std.mem.eql(u8, op.id, operation_id)) continue;

        const path = try fillPathTemplate(allocator, op.path, parsed.path_params);
        defer allocator.free(path);

        const method = try parseMethod(op.method);
        const url = try resolveUrl(allocator, path, effective_base_url, parsed.query_params);

        return .{
            .method = method,
            .method_name = try allocator.dupe(u8, op.method),
            .url = url,
        };
    }

    return error.OperationNotFound;
}

fn resolveUrl(
    allocator: std.mem.Allocator,
    raw_target: []const u8,
    base_url: ?[]const u8,
    query_params: []const KeyValue,
) ![]u8 {
    const absolute = if (std.mem.startsWith(u8, raw_target, "http://") or
        std.mem.startsWith(u8, raw_target, "https://"))
        try allocator.dupe(u8, raw_target)
    else
        try joinWithBaseUrl(allocator, base_url, raw_target);
    defer allocator.free(absolute);

    if (query_params.len == 0) {
        return allocator.dupe(u8, absolute);
    }

    return appendQueryString(allocator, absolute, query_params);
}

fn joinWithBaseUrl(
    allocator: std.mem.Allocator,
    base_url: ?[]const u8,
    raw_target: []const u8,
) ![]u8 {
    const base = base_url orelse return error.MissingBaseUrl;

    const base_has_slash = std.mem.endsWith(u8, base, "/");
    const target_has_slash = std.mem.startsWith(u8, raw_target, "/");

    if (base_has_slash and target_has_slash) {
        return try std.mem.concat(allocator, u8, &.{ base[0 .. base.len - 1], raw_target });
    }
    if (!base_has_slash and !target_has_slash) {
        return try std.mem.concat(allocator, u8, &.{ base, "/", raw_target });
    }
    return try std.mem.concat(allocator, u8, &.{ base, raw_target });
}

fn appendQueryString(
    allocator: std.mem.Allocator,
    base: []const u8,
    query_params: []const KeyValue,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, base);
    try out.append(allocator, if (std.mem.indexOfScalar(u8, base, '?') == null) '?' else '&');

    for (query_params, 0..) |kv, idx| {
        if (idx != 0) try out.append(allocator, '&');
        try out.appendSlice(allocator, kv.key);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, kv.value);
    }

    return out.toOwnedSlice(allocator);
}

fn fillPathTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    params: []const KeyValue,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '{') {
            try out.append(allocator, template[i]);
            i += 1;
            continue;
        }

        const end_rel = std.mem.indexOfScalarPos(u8, template, i, '}') orelse return error.InvalidPathTemplate;
        const key = template[i + 1 .. end_rel];
        const val = findParamValue(params, key) orelse return error.MissingPathParam;
        try out.appendSlice(allocator, val);
        i = end_rel + 1;
    }

    return out.toOwnedSlice(allocator);
}

fn findParamValue(params: []const KeyValue, key: []const u8) ?[]const u8 {
    for (params) |kv| {
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

fn parseMethod(raw: []const u8) !std.http.Method {
    if (std.ascii.eqlIgnoreCase(raw, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(raw, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(raw, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(raw, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(raw, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(raw, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(raw, "OPTIONS")) return .OPTIONS;
    if (std.ascii.eqlIgnoreCase(raw, "TRACE")) return .TRACE;
    return error.UnsupportedMethod;
}

fn parseKeyValueOwned(allocator: std.mem.Allocator, raw: []const u8) !KeyValue {
    const sep = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidKeyValue;
    if (sep == 0 or sep == raw.len - 1) return error.InvalidKeyValue;
    return .{
        .key = try allocator.dupe(u8, raw[0..sep]),
        .value = try allocator.dupe(u8, raw[sep + 1 ..]),
    };
}

fn isOperationId(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
        return false;
    }
    const sep = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    if (sep == 0 or sep == target.len - 1) return false;
    const maybe_method = target[0..sep];
    const maybe_path = target[sep + 1 ..];
    if (maybe_path.len == 0 or maybe_path[0] != '/') return false;
    _ = parseMethod(maybe_method) catch return false;
    return true;
}

fn resolveBody(allocator: std.mem.Allocator, raw_body: ?[]u8) !ResolvedBody {
    const raw = raw_body orelse return .{ .slice = null, .owned = null };

    if (raw.len > 1 and raw[0] == '@') {
        const path = raw[1..];
        const bytes = try readFile(allocator, path);
        return .{ .slice = bytes, .owned = bytes };
    }

    return .{ .slice = raw, .owned = null };
}

fn autoBodyForOperation(allocator: std.mem.Allocator, operation_id: []const u8, use_cache: bool) !?AutoBody {
    const spec_path = try loader.resolveSpecPath(allocator);
    defer allocator.free(spec_path);

    var details = (try loader.loadOperationDetailsFromFile(allocator, spec_path, operation_id)) orelse return null;
    defer details.deinit(allocator);

    if (!details.request_body_required) return null;

    if (use_cache) {
        if (try loadRememberedBody(allocator, operation_id)) |saved| {
            return .{ .body = saved, .source = .cache };
        }
    }

    if (try generateBodyFromFields(allocator, details.request_body_fields)) |generated| {
        return .{ .body = generated, .source = .generated };
    }

    const fallback = try allocator.dupe(u8, "{\"example\":\"value\"}");
    return .{ .body = fallback, .source = .fallback };
}

fn generateBodyFromFields(allocator: std.mem.Allocator, fields: []const []u8) !?[]u8 {
    if (fields.len == 0) return null;

    var rendered: std.ArrayList([]u8) = .{};
    defer {
        for (rendered.items) |line| allocator.free(line);
        rendered.deinit(allocator);
    }

    for (fields) |field| {
        const sep = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        const name = std.mem.trim(u8, field[0..sep], " \t");
        if (name.len == 0) continue;

        const rest = std.mem.trim(u8, field[sep + 1 ..], " \t");
        const required = std.mem.indexOf(u8, rest, "(required)") != null;
        if (!required) continue;

        const type_name = if (std.mem.indexOf(u8, rest, " (")) |idx| rest[0..idx] else rest;
        const value = sampleJsonValueForType(type_name);
        const pair = try std.fmt.allocPrint(allocator, "\"{s}\":{s}", .{ name, value });
        try rendered.append(allocator, pair);
    }

    if (rendered.items.len == 0) return null;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try out.append(allocator, '{');
    for (rendered.items, 0..) |pair, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, pair);
    }
    try out.append(allocator, '}');

    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

fn sampleJsonValueForType(type_name_raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, type_name_raw, " \t");
    if (std.mem.eql(u8, t, "string")) return "\"example\"";
    if (std.mem.eql(u8, t, "integer")) return "0";
    if (std.mem.eql(u8, t, "number")) return "0";
    if (std.mem.eql(u8, t, "boolean")) return "false";
    if (std.mem.startsWith(u8, t, "array<")) return "[]";
    if (std.mem.eql(u8, t, "object")) return "{}";
    if (std.mem.eql(u8, t, "allOf")) return "{}";
    if (std.mem.eql(u8, t, "anyOf")) return "{}";
    if (std.mem.eql(u8, t, "oneOf")) return "{}";
    if (std.mem.startsWith(u8, t, "$ref:")) return "{}";
    return "\"example\"";
}

fn rememberSuccessfulBody(allocator: std.mem.Allocator, operation_id: []const u8, body: []const u8) !void {
    const orion_dir = (try ensureOrionDirForState(allocator)) orelse return;
    defer allocator.free(orion_dir);

    const cache_path = try std.fs.path.join(allocator, &.{ orion_dir, "body_history.txt" });
    defer allocator.free(cache_path);

    const encoded_len = std.base64.standard.Encoder.calcSize(body.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, body);

    const file = try std.fs.createFileAbsolute(cache_path, .{ .truncate = false, .read = false });
    defer file.close();
    try file.seekFromEnd(0);
    const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ operation_id, encoded });
    defer allocator.free(line);
    try file.writeAll(line);
}

fn loadRememberedBody(allocator: std.mem.Allocator, operation_id: []const u8) !?[]u8 {
    const orion_dir = (try findNearestOrionDir(allocator)) orelse return null;
    defer allocator.free(orion_dir);

    const cache_path = try std.fs.path.join(allocator, &.{ orion_dir, "body_history.txt" });
    defer allocator.free(cache_path);

    const file = std.fs.openFileAbsolute(cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(content);

    var last_encoded: ?[]const u8 = null;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const op = line[0..tab];
        const encoded = line[tab + 1 ..];
        if (std.mem.eql(u8, op, operation_id) and encoded.len > 0) {
            last_encoded = encoded;
        }
    }

    const encoded = last_encoded orelse return null;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch {
        allocator.free(decoded);
        return null;
    };
    return decoded;
}

fn appendCallHistory(allocator: std.mem.Allocator, entry: HistoryEntryInput) !void {
    const orion_dir = (try ensureOrionDirForState(allocator)) orelse return;
    defer allocator.free(orion_dir);

    const path = try std.fs.path.join(allocator, &.{ orion_dir, "call_history.jsonl" });
    defer allocator.free(path);

    var body_b64: ?[]u8 = null;
    defer if (body_b64) |v| allocator.free(v);

    if (entry.body) |b| {
        const encoded_len = std.base64.standard.Encoder.calcSize(b.len);
        body_b64 = try allocator.alloc(u8, encoded_len);
        _ = std.base64.standard.Encoder.encode(body_b64.?, b);
    }

    const Record = struct {
        ts_ms: i64,
        target: []const u8,
        method: []const u8,
        url: []const u8,
        status: u16,
        body_source: []const u8,
        body_b64: ?[]const u8,
    };

    const line = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(Record{
        .ts_ms = std.time.milliTimestamp(),
        .target = entry.target,
        .method = entry.method,
        .url = entry.url,
        .status = entry.status,
        .body_source = entry.body_source,
        .body_b64 = body_b64,
    }, .{})});
    defer allocator.free(line);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = false, .read = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
}

fn findNearestOrionDir(allocator: std.mem.Allocator) !?[]u8 {
    var cwd = try std.process.getCwdAlloc(allocator);
    errdefer allocator.free(cwd);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ cwd, ".orion" });
        if (dirExistsAbsolute(candidate)) {
            allocator.free(cwd);
            return candidate;
        }
        allocator.free(candidate);

        const parent = std.fs.path.dirname(cwd) orelse break;
        if (std.mem.eql(u8, parent, cwd)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(cwd);
        cwd = next;
    }

    allocator.free(cwd);
    return null;
}

fn ensureOrionDirForState(allocator: std.mem.Allocator) !?[]u8 {
    if (try findNearestOrionDir(allocator)) |existing| return existing;

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const created = try std.fs.path.join(allocator, &.{ cwd, ".orion" });
    std.fs.makeDirAbsolute(created) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.AccessDenied, error.ReadOnlyFileSystem => {
            allocator.free(created);
            return null;
        },
        else => {
            allocator.free(created);
            return err;
        },
    };
    return created;
}

fn dirExistsAbsolute(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn bodySourceLabel(source: ?BodySource) []const u8 {
    const s = source orelse return "none";
    return switch (s) {
        .explicit => "explicit(--body)",
        .cache => "cache(.orion/body_history.txt)",
        .generated => "auto-generated(schema)",
        .fallback => "auto-generated(fallback)",
    };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 8 * 1024 * 1024);
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  orion call <operation-id|url-or-path> [--param key=value] [--query key=value] [--body @file.json|json] [--method METHOD]
        \\            [--use NAME] [--save NAME] [--example] [--dry-run] [--explain] [--output text|json]
        \\            [--no-auto-body] [--no-body-cache] [--show-body-source]
        \\
        \\Examples:
        \\  orion call get:/health
        \\  orion call get:/items/{{id}} --param id=123
        \\  orion call post:/auth/register --body '{{"email":"a@b.com","password":"x"}}'
        \\  orion call --use login_admin --dry-run --explain
        \\
    , .{});
}

fn printExplain(target: []const u8, resolved: ResolvedTarget, parsed: CallArgs, body_source: ?BodySource) void {
    std.debug.print("Explain:\n", .{});
    std.debug.print("  target: {s} ({s})\n", .{ target, if (isOperationId(target)) "operation-id" else "url-or-path" });
    std.debug.print("  method: {s}\n", .{resolved.method_name});
    std.debug.print("  url: {s}\n", .{resolved.url});
    std.debug.print("  params: path={d} query={d}\n", .{ parsed.path_params.len, parsed.query_params.len });
    std.debug.print("  body source: {s}\n", .{bodySourceLabel(body_source)});
    std.debug.print("  cache: {s}\n", .{if (parsed.no_body_cache) "disabled" else "enabled"});
}

fn printCallResultText(
    resolved_target: ResolvedTarget,
    body: ?[]const u8,
    status: ?u16,
    response_body: ?[]const u8,
    body_source: ?BodySource,
    dry_run: bool,
    show_body_source: bool,
) void {
    std.debug.print("Method: {s}\n", .{resolved_target.method_name});
    std.debug.print("URL: {s}\n", .{resolved_target.url});

    if (dry_run) {
        std.debug.print("Dry run: true\n", .{});
        if (body) |b| std.debug.print("Body: {s}\n", .{b});
    } else {
        std.debug.print("Status: {d}\n", .{status.?});
        std.debug.print("{s}\n", .{response_body.?});
    }

    if (show_body_source) {
        std.debug.print("Body source: {s}\n", .{bodySourceLabel(body_source)});
    }
}

fn printCallResultJson(
    resolved_target: ResolvedTarget,
    body: ?[]const u8,
    status: ?u16,
    response_body: ?[]const u8,
    body_source: ?BodySource,
    dry_run: bool,
) void {
    const Result = struct {
        method: []const u8,
        url: []const u8,
        dry_run: bool,
        status: ?u16,
        request_body: ?[]const u8,
        response_body: ?[]const u8,
        body_source: []const u8,
    };

    std.debug.print("{f}\n", .{std.json.fmt(Result{
        .method = resolved_target.method_name,
        .url = resolved_target.url,
        .dry_run = dry_run,
        .status = status,
        .request_body = body,
        .response_body = response_body,
        .body_source = bodySourceLabel(body_source),
    }, .{})});
}

fn printCallError(err: anyerror) void {
    switch (err) {
        error.MissingTarget => std.debug.print("Missing target. Pass operation-id/url-path or use --use <preset>.\n", .{}),
        error.UnexpectedPositionalArg => std.debug.print("Unexpected extra positional argument.\n", .{}),
        error.MissingBaseUrl => std.debug.print(
            "Relative path or operation-id call requires base_url (config or OpenAPI servers[0].url). Use `orion config`.\n",
            .{},
        ),
        error.OperationNotFound => std.debug.print("Operation not found in current OpenAPI spec.\n", .{}),
        error.FileNotFound => std.debug.print("OpenAPI spec file not found. Check `openapi_spec` in config.\n", .{}),
        error.AccessDenied => std.debug.print("Cannot read required file (permission denied).\n", .{}),
        error.InvalidOpenApiDocument => std.debug.print("Invalid OpenAPI document. Check that the spec is valid JSON or YAML.\n", .{}),
        error.MissingPathParam => std.debug.print("Missing required path parameter. Pass it with --param key=value.\n", .{}),
        error.InvalidKeyValue => std.debug.print("Invalid key=value format. Example: --query limit=10\n", .{}),
        error.MissingPresetName => std.debug.print("Missing preset name. Use --use <name> or --save <name>.\n", .{}),
        error.PresetNotFound => std.debug.print("Preset not found.\n", .{}),
        error.MissingOutputMode => std.debug.print("Missing output mode. Use --output text|json.\n", .{}),
        error.InvalidOutputMode => std.debug.print("Invalid output mode. Use --output text|json.\n", .{}),
        error.UnknownFlag => std.debug.print("Unknown call flag. Use `orion call` for usage.\n", .{}),
        error.MethodDoesNotSupportBody => std.debug.print("HTTP method does not support request body.\n", .{}),
        else => std.debug.print("Call failed: {s}\n", .{@errorName(err)}),
    }
}
