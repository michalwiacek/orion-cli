const std = @import("std");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const spec_path = loader.resolveSpecPath(allocator) catch {
        std.debug.print(
            "No OpenAPI spec configured. Set `openapi_spec` in config or add `openapi.remote.yaml` in project root.\n",
            .{},
        );
        return;
    };
    defer allocator.free(spec_path);

    var operations = try loader.loadOperationsFromFile(allocator, spec_path);
    defer operations.deinit(allocator);

    std.debug.print("Spec: {s}\n", .{spec_path});
    std.debug.print("Operations: {d}\n", .{operations.items.len});
    for (operations.items) |op| {
        if (op.summary) |summary| {
            std.debug.print("{s}\t{s}\t{s}\t{s}\n", .{ op.id, op.method, op.path, summary });
        } else {
            std.debug.print("{s}\t{s}\t{s}\n", .{ op.id, op.method, op.path });
        }
    }
}
