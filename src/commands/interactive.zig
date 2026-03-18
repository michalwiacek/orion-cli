const std = @import("std");
const loader = @import("../openapi/loader.zig");
const cmd_describe = @import("describe.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const spec_path = try loader.resolveSpecPath(allocator);
    defer allocator.free(spec_path);

    var ops = try loader.loadOperationsFromFile(allocator, spec_path);
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
