const std = @import("std");
const app_config = @import("../config/config.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        std.debug.print("Usage: orion use <profile>\n", .{});
        return;
    }

    const profile = args[0];
    const cfg_path = try writableConfigPath(allocator);
    defer allocator.free(cfg_path);

    var cfg = loadOrInitConfig(allocator, cfg_path) catch |err| {
        std.debug.print("Failed to load config: {s}\n", .{@errorName(err)});
        return;
    };
    defer cfg.deinit(allocator);

    var found = false;
    for (cfg.profiles) |entry| {
        if (std.mem.eql(u8, entry.name, profile)) {
            found = true;
            break;
        }
    }
    if (!found) {
        std.debug.print("Profile not found: {s}\n", .{profile});
        return;
    }

    if (cfg.current_profile) |old| allocator.free(old);
    cfg.current_profile = try allocator.dupe(u8, profile);

    try app_config.saveConfigFile(allocator, cfg_path, cfg);
    std.debug.print("Current profile set to: {s}\n", .{profile});
}

fn writableConfigPath(allocator: std.mem.Allocator) ![]u8 {
    if (try app_config.findProjectConfigPath(allocator)) |p| {
        return p;
    }
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".orion", "config.json" });
}

fn loadOrInitConfig(allocator: std.mem.Allocator, path: []const u8) !app_config.Config {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    file.close();
    return app_config.loadConfigFile(allocator, path);
}
