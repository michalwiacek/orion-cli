const std = @import("std");
const app_config = @import("../config/config.zig");

pub fn run(allocator: std.mem.Allocator, _: []const []const u8) !void {
    var loaded = try app_config.loadMerged(allocator);
    defer loaded.deinit(allocator);

    std.debug.print("Global config: {s} ({s})\n", .{
        loaded.global_path,
        if (loaded.global_exists) "found" else "missing",
    });

    if (loaded.project_path) |p| {
        std.debug.print("Project config: {s} (found)\n", .{p});
    } else {
        std.debug.print("Project config: (not found in current directory tree)\n", .{});
    }

    std.debug.print("Merged config:\n", .{});
    std.debug.print("  base_url: {s}\n", .{loaded.config.base_url orelse "(unset)"});
    std.debug.print("  openapi_spec: {s}\n", .{loaded.config.openapi_spec orelse "(unset)"});
}
