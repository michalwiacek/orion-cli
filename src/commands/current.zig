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
            std.debug.print("Usage: orion current [--output text|json]\n", .{});
            return;
        }
    }

    var loaded = try app_config.loadMerged(allocator);
    defer loaded.deinit(allocator);

    if (output_json) {
        const payload = struct {
            current_profile: ?[]const u8,
            base_url: ?[]const u8,
            openapi_spec: ?[]const u8,
        }{
            .current_profile = loaded.config.current_profile,
            .base_url = loaded.config.base_url,
            .openapi_spec = loaded.config.openapi_spec,
        };
        std.debug.print("{f}\n", .{std.json.fmt(payload, .{})});
        return;
    }

    std.debug.print("Current profile: {s}\n", .{loaded.config.current_profile orelse "(none)"});
    std.debug.print("base_url: {s}\n", .{loaded.config.base_url orelse "(unset)"});
    std.debug.print("openapi_spec: {s}\n", .{loaded.config.openapi_spec orelse "(unset)"});
}
