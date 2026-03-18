const std = @import("std");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var output_json = false;
    var for_agent = false;
    var operation_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) {
                std.debug.print("Usage: orion describe <operation-id> [--output text|json]\n", .{});
                return;
            }
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) {
                output_json = true;
            } else if (std.mem.eql(u8, args[i], "text")) {
                output_json = false;
            } else {
                std.debug.print("Invalid output mode. Use --output text|json\n", .{});
                return;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--for-agent")) {
            for_agent = true;
            output_json = true;
            continue;
        }
        if (operation_id == null) {
            operation_id = arg;
            continue;
        }
        std.debug.print("Usage: orion describe <operation-id> [--output text|json]\n", .{});
        return;
    }

    if (operation_id == null) {
        std.debug.print("Usage: orion describe <operation-id>\n", .{});
        std.debug.print("Example: orion describe get:/health\n", .{});
        return;
    }

    const spec_path = loader.resolveSpecPath(allocator) catch {
        std.debug.print(
            "No OpenAPI spec configured. Set `openapi_spec` in config or add `openapi.remote.yaml` in project root.\n",
            .{},
        );
        return;
    };
    defer allocator.free(spec_path);

    const wanted = operation_id.?;
    var details = (loader.loadOperationDetailsFromFile(allocator, spec_path, wanted) catch |err| {
        printDescribeError(spec_path, err);
        return;
    }) orelse {
        std.debug.print("Operation not found: {s}\n", .{wanted});
        if (trySuggestOperationId(allocator, spec_path, wanted)) |hint| {
            defer allocator.free(hint);
            std.debug.print("Did you mean: {s}\n", .{hint});
        }
        std.debug.print("Use `orion list` to inspect available ids.\n", .{});
        return;
    };
    defer details.deinit(allocator);

    if (output_json) {
        if (for_agent) {
            const payload = struct {
                operation: loader.OperationDetails,
                hints: []const []const u8,
            }{
                .operation = details,
                .hints = &.{
                    "Use request_body_fields to construct payloads.",
                    "Prefer operation id over raw URL for reproducibility.",
                },
            };
            std.debug.print("{f}\n", .{std.json.fmt(payload, .{})});
        } else {
            std.debug.print("{f}\n", .{std.json.fmt(details, .{})});
        }
        return;
    }

    std.debug.print("Operation  {s}\n", .{details.id});
    if (details.summary) |summary| {
        std.debug.print("Summary    {s}\n", .{summary});
    }
    std.debug.print("Method     {s}\n", .{details.method});
    std.debug.print("Path       {s}\n", .{details.path});

    std.debug.print("\nHeaders\n", .{});
    printHeaders(details);

    std.debug.print("\nParameters\n", .{});
    if (details.parameters.len == 0) {
        std.debug.print("  (none)\n", .{});
    } else {
        printParameterGroup(details.parameters, "path");
        printParameterGroup(details.parameters, "query");
        printParameterGroup(details.parameters, "header");
        printParameterGroup(details.parameters, "cookie");
    }

    std.debug.print("\nRequest body\n", .{});
    printRequestBody(details);

    std.debug.print("\nResponses\n", .{});
    if (details.responses.len == 0) {
        std.debug.print("  (none)\n", .{});
    } else {
        for (details.responses) |resp| {
            std.debug.print("  {s}\n", .{resp});
        }
    }
}

fn trySuggestOperationId(allocator: std.mem.Allocator, spec_path: []const u8, wanted: []const u8) ?[]u8 {
    var operations = loader.loadOperationsFromFile(allocator, spec_path) catch return null;
    defer operations.deinit(allocator);

    var best_score: usize = 0;
    var best: ?[]u8 = null;
    errdefer if (best) |v| allocator.free(v);

    for (operations.items) |op| {
        var score: usize = 0;
        if (std.mem.indexOf(u8, op.id, wanted) != null) score += 20;
        if (std.mem.indexOf(u8, op.path, wanted) != null) score += 10;
        if (score > best_score) {
            if (best) |old| allocator.free(old);
            best_score = score;
            best = allocator.dupe(u8, op.id) catch null;
        }
    }

    if (best_score == 0) {
        if (best) |v| allocator.free(v);
        return null;
    }
    return best;
}

fn printParameterGroup(parameters: []const []u8, location: []const u8) void {
    var label_buf: [32]u8 = undefined;
    const location_marker = std.fmt.bufPrint(&label_buf, "[{s}]", .{location}) catch return;

    var found = false;
    for (parameters) |param| {
        if (!std.mem.containsAtLeast(u8, param, 1, location_marker)) continue;
        if (!found) {
            found = true;
            std.debug.print("  {s}:\n", .{location});
        }
        std.debug.print("    - {s}\n", .{param});
    }

    if (!found) {
        std.debug.print("  {s}: (none)\n", .{location});
    }
}

fn printHeaders(details: loader.OperationDetails) void {
    var printed = false;
    for (details.request_body_content_types) |ct| {
        printed = true;
        std.debug.print("  Content-Type: {s}\n", .{ct});
    }

    var label_buf: [32]u8 = undefined;
    const location_marker = std.fmt.bufPrint(&label_buf, "[{s}]", .{"header"}) catch return;
    for (details.parameters) |param| {
        if (!std.mem.containsAtLeast(u8, param, 1, location_marker)) continue;
        printed = true;
        std.debug.print("  {s}\n", .{param});
    }

    if (!printed) {
        std.debug.print("  (none)\n", .{});
    }
}

fn printRequestBody(details: loader.OperationDetails) void {
    const has_body =
        details.request_body_required or
        details.request_body_content_types.len > 0 or
        details.request_body_schemas.len > 0 or
        details.request_body_fields.len > 0;

    if (!has_body) {
        std.debug.print("  (none)\n", .{});
        return;
    }

    if (details.request_body_fields.len > 0) {
        for (details.request_body_fields) |field| {
            std.debug.print("  {s}\n", .{field});
        }
    } else {
        std.debug.print("  (shape unavailable)\n", .{});
    }

    if (details.request_body_schemas.len > 0) {
        std.debug.print("  schema:\n", .{});
        for (details.request_body_schemas) |schema| {
            std.debug.print("    - {s}\n", .{schema});
        }
    }
}

fn printDescribeError(spec_path: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound => std.debug.print("OpenAPI spec not found: {s}\n", .{spec_path}),
        error.AccessDenied => std.debug.print("Cannot read OpenAPI spec (permission denied): {s}\n", .{spec_path}),
        error.InvalidOpenApiDocument => std.debug.print("Invalid OpenAPI document: {s}\n", .{spec_path}),
        else => std.debug.print("Failed to describe operation from spec ({s}): {s}\n", .{ spec_path, @errorName(err) }),
    }
}
