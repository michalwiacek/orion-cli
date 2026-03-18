const std = @import("std");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
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

    const wanted = args[0];
    var details = (try loader.loadOperationDetailsFromFile(allocator, spec_path, wanted)) orelse {
        std.debug.print("Operation not found: {s}\n", .{wanted});
        std.debug.print("Use `orion list` to inspect available ids.\n", .{});
        return;
    };
    defer details.deinit(allocator);

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
