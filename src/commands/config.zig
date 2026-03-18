const std = @import("std");
const app_config = @import("../config/config.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var output_json = false;
    if (args.len > 0) {
        if (args.len == 2 and std.mem.eql(u8, args[0], "--output") and std.mem.eql(u8, args[1], "json")) {
            output_json = true;
        } else if (args.len == 2 and std.mem.eql(u8, args[0], "--output") and std.mem.eql(u8, args[1], "text")) {
            output_json = false;
        } else {
            std.debug.print("Usage: orion config [--output text|json]\n", .{});
            return;
        }
    }

    var loaded = try app_config.loadMerged(allocator);
    defer loaded.deinit(allocator);

    if (output_json) {
        const payload = struct {
            global_path: []const u8,
            global_exists: bool,
            project_path: ?[]const u8,
            base_url: ?[]const u8,
            openapi_spec: ?[]const u8,
            current_profile: ?[]const u8,
            profiles: []app_config.ProfileEntry,
        }{
            .global_path = loaded.global_path,
            .global_exists = loaded.global_exists,
            .project_path = loaded.project_path,
            .base_url = loaded.config.base_url,
            .openapi_spec = loaded.config.openapi_spec,
            .current_profile = loaded.config.current_profile,
            .profiles = loaded.config.profiles,
        };
        std.debug.print("{f}\n", .{std.json.fmt(payload, .{})});
        return;
    }

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
    std.debug.print("  current_profile: {s}\n", .{loaded.config.current_profile orelse "(none)"});
    std.debug.print("  profiles: {d}\n", .{loaded.config.profiles.len});
}
