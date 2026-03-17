const std = @import("std");
const http = @import("../http/client.zig");
const app_config = @import("../config/config.zig");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print(
            \\Usage:
            \\  orion call <operation-id|url-or-path> [--param key=value] [--query key=value] [--body @file.json|json] [--method METHOD]
            \\
            \\Examples:
            \\  orion call get:/health
            \\  orion call get:/api/v1/offers/{{id}} --param id=123
            \\  orion call post:/api/v1/auth/register --body '{{"email":"a@b.com","password":"x"}}'
            \\
        , .{});
        return;
    }

    const target = args[0];
    var parsed = parseCallArgs(allocator, args[1..]) catch |err| {
        printCallError(err);
        return;
    };
    defer parsed.deinit(allocator);

    var loaded_cfg = try app_config.loadMerged(allocator);
    defer loaded_cfg.deinit(allocator);

    const resolved_target = resolveTarget(allocator, target, loaded_cfg.config.base_url, parsed) catch |err| {
        printCallError(err);
        return;
    };
    defer allocator.free(resolved_target.url);
    defer allocator.free(resolved_target.method_name);

    const body = resolveBody(allocator, parsed.body) catch |err| {
        printCallError(err);
        return;
    };
    defer if (body.owned) |buf| allocator.free(buf);

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

    std.debug.print("Method: {s}\n", .{resolved_target.method_name});
    std.debug.print("URL: {s}\n", .{resolved_target.url});
    std.debug.print("Status: {d}\n", .{res.status});
    std.debug.print("{s}\n", .{res.body});
}

const CallArgs = struct {
    method_override: ?[]const u8 = null,
    body: ?[]const u8 = null,
    path_params: []KeyValue,
    query_params: []KeyValue,

    fn deinit(self: *CallArgs, allocator: std.mem.Allocator) void {
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

fn parseCallArgs(allocator: std.mem.Allocator, args: []const []const u8) !CallArgs {
    var path_params: std.ArrayList(KeyValue) = .{};
    defer path_params.deinit(allocator);

    var query_params: std.ArrayList(KeyValue) = .{};
    defer query_params.deinit(allocator);

    var method_override: ?[]const u8 = null;
    var body: ?[]const u8 = null;

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
            body = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--method")) {
            if (i + 1 >= args.len) return error.MissingMethodValue;
            i += 1;
            method_override = args[i];
            continue;
        }
        return error.UnknownFlag;
    }

    return .{
        .method_override = method_override,
        .body = body,
        .path_params = try path_params.toOwnedSlice(allocator),
        .query_params = try query_params.toOwnedSlice(allocator),
    };
}

fn resolveTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    base_url: ?[]const u8,
    parsed: CallArgs,
) !ResolvedTarget {
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

fn resolveOperationTarget(
    allocator: std.mem.Allocator,
    operation_id: []const u8,
    base_url: ?[]const u8,
    parsed: CallArgs,
) !ResolvedTarget {
    const spec_path = try loader.resolveSpecPath(allocator);
    defer allocator.free(spec_path);

    var operations = try loader.loadOperationsFromFile(allocator, spec_path);
    defer operations.deinit(allocator);

    for (operations.items) |op| {
        if (!std.mem.eql(u8, op.id, operation_id)) continue;

        const path = try fillPathTemplate(allocator, op.path, parsed.path_params);
        defer allocator.free(path);

        const method = try parseMethod(op.method);
        const url = try resolveUrl(allocator, path, base_url, parsed.query_params);

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

fn resolveBody(allocator: std.mem.Allocator, raw_body: ?[]const u8) !ResolvedBody {
    const raw = raw_body orelse return .{ .slice = null, .owned = null };

    if (raw.len > 1 and raw[0] == '@') {
        const path = raw[1..];
        const bytes = try readFile(allocator, path);
        return .{ .slice = bytes, .owned = bytes };
    }

    return .{ .slice = raw, .owned = null };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 8 * 1024 * 1024);
}

fn printCallError(err: anyerror) void {
    switch (err) {
        error.MissingBaseUrl => std.debug.print(
            "Relative path or operation-id call requires configured base_url. Use `orion config`.\n",
            .{},
        ),
        error.OperationNotFound => std.debug.print("Operation not found in current OpenAPI spec.\n", .{}),
        error.MissingPathParam => std.debug.print("Missing required path parameter. Pass it with --param key=value.\n", .{}),
        error.InvalidKeyValue => std.debug.print("Invalid key=value format. Example: --query limit=10\n", .{}),
        error.UnknownFlag => std.debug.print("Unknown call flag. Supported: --param --query --body --method\n", .{}),
        error.MethodDoesNotSupportBody => std.debug.print("HTTP method does not support request body.\n", .{}),
        else => std.debug.print("Call failed: {s}\n", .{@errorName(err)}),
    }
}
