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

    std.debug.print("Spec: {s}\n", .{spec_path});
    std.debug.print("id: {s}\n", .{details.id});
    std.debug.print("method: {s}\n", .{details.method});
    std.debug.print("path: {s}\n", .{details.path});
    std.debug.print("summary: {s}\n", .{details.summary orelse "(none)"});

    std.debug.print("parameters:\n", .{});
    if (details.parameters.len == 0) {
        std.debug.print("  (none)\n", .{});
    } else {
        for (details.parameters) |param| {
            std.debug.print("  - {s}\n", .{param});
        }
    }

    std.debug.print("requestBody:\n", .{});
    std.debug.print("  required: {s}\n", .{if (details.request_body_required) "true" else "false"});
    if (details.request_body_content_types.len == 0) {
        std.debug.print("  content: (none)\n", .{});
    } else {
        std.debug.print("  content:\n", .{});
        for (details.request_body_content_types) |ct| {
            std.debug.print("    - {s}\n", .{ct});
        }
    }
    if (details.request_body_schemas.len != 0) {
        std.debug.print("  schemas:\n", .{});
        for (details.request_body_schemas) |schema| {
            std.debug.print("    - {s}\n", .{schema});
        }
    }

    std.debug.print("responses:\n", .{});
    if (details.responses.len == 0) {
        std.debug.print("  (none)\n", .{});
    } else {
        for (details.responses) |resp| {
            std.debug.print("  - {s}\n", .{resp});
        }
    }
}
