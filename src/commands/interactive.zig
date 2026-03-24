const std = @import("std");
const loader = @import("../openapi/loader.zig");
const cmd_describe = @import("describe.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const spec_path = loader.resolveSpecPath(allocator) catch {
        std.debug.print(
            "No OpenAPI spec configured. Set `openapi_spec` in config or add `openapi.remote.yaml` in project root.\n",
            .{},
        );
        return;
    };
    defer allocator.free(spec_path);

    var ops = loader.loadOperationsFromFile(allocator, spec_path) catch |err| {
        printInteractiveError(spec_path, err);
        return;
    };
    defer ops.deinit(allocator);

    std.debug.print("Interactive mode (TUI-lite)\n", .{});
    std.debug.print("Pick operation id (pass as arg or copy from list)\n\n", .{});

    const max = @min(@as(usize, 20), ops.items.len);
    for (ops.items[0..max], 0..) |op, idx| {
        std.debug.print("{d}. {s}\t{s}\n", .{ idx + 1, op.id, op.summary orelse "" });
    }

    if (args.len >= 1) {
        try cmd_describe.run(allocator, &.{args[0]});
        return;
    }

    std.debug.print("\nNext:\n", .{});
    std.debug.print("  orion describe <operation-id>\n", .{});
    std.debug.print("  orion call <operation-id> --example --dry-run\n", .{});
}

fn printInteractiveError(spec_path: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound => std.debug.print("OpenAPI spec not found: {s}\n", .{spec_path}),
        error.AccessDenied => std.debug.print("Cannot read OpenAPI spec (permission denied): {s}\n", .{spec_path}),
        error.InvalidOpenApiDocument => {
            std.debug.print("Invalid OpenAPI document: {s}\n", .{spec_path});
            if (loader.getLastOpenApiErrorDetail()) |detail| {
                std.debug.print("Details: {s}\n", .{detail});
            }
        },
        else => std.debug.print("Interactive mode failed while reading spec ({s}): {s}\n", .{ spec_path, @errorName(err) }),
    }
}
