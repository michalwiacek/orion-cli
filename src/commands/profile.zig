const std = @import("std");
const app_config = @import("../config/config.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        printUsage();
        return;
    }

    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) {
        try runList(allocator, args[1..]);
    } else if (std.mem.eql(u8, sub, "add")) {
        try runAdd(allocator, args[1..]);
    } else if (std.mem.eql(u8, sub, "remove")) {
        try runRemove(allocator, args[1..]);
    } else {
        printUsage();
    }
}

fn runList(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var output_json = false;
    if (args.len > 0) {
        if (args.len == 2 and std.mem.eql(u8, args[0], "--output") and std.mem.eql(u8, args[1], "json")) {
            output_json = true;
        } else {
            std.debug.print("Usage: orion profile list [--output json]\n", .{});
            return;
        }
    }

    var loaded = try app_config.loadMerged(allocator);
    defer loaded.deinit(allocator);

    if (output_json) {
        std.debug.print("{f}\n", .{std.json.fmt(loaded.config.profiles, .{})});
        return;
    }

    if (loaded.config.profiles.len == 0) {
        std.debug.print("No profiles configured.\n", .{});
        return;
    }

    for (loaded.config.profiles) |entry| {
        const mark = if (loaded.config.current_profile != null and std.mem.eql(u8, loaded.config.current_profile.?, entry.name)) "*" else " ";
        std.debug.print("{s} {s}\n", .{ mark, entry.name });
    }
}

fn runAdd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: orion profile add <name> [--base-url URL] [--spec PATH]\n", .{});
        return;
    }

    const name = args[0];
    var base_url: ?[]const u8 = null;
    var spec: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--base-url")) {
            if (i + 1 >= args.len) return error.MissingBaseUrl;
            i += 1;
            base_url = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--spec")) {
            if (i + 1 >= args.len) return error.MissingSpec;
            i += 1;
            spec = args[i];
            continue;
        }
        return error.UnknownFlag;
    }

    const cfg_path = try writableConfigPath(allocator);
    defer allocator.free(cfg_path);

    var cfg = try loadOrInitConfig(allocator, cfg_path);
    defer cfg.deinit(allocator);

    if (app_config.findProfileByName(cfg.profiles, name)) |entry| {
        if (base_url) |v| {
            if (entry.profile.base_url) |old| allocator.free(old);
            entry.profile.base_url = try allocator.dupe(u8, v);
        }
        if (spec) |v| {
            if (entry.profile.openapi_spec) |old| allocator.free(old);
            entry.profile.openapi_spec = try allocator.dupe(u8, v);
        }
    } else {
        var list: std.ArrayList(app_config.ProfileEntry) = .{};
        defer list.deinit(allocator);
        try list.appendSlice(allocator, cfg.profiles);
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .profile = .{
                .base_url = if (base_url) |v| try allocator.dupe(u8, v) else null,
                .openapi_spec = if (spec) |v| try allocator.dupe(u8, v) else null,
            },
        });
        allocator.free(cfg.profiles);
        cfg.profiles = try list.toOwnedSlice(allocator);
    }

    try app_config.saveConfigFile(allocator, cfg_path, cfg);
    std.debug.print("Profile saved: {s}\n", .{name});
}

fn runRemove(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        std.debug.print("Usage: orion profile remove <name>\n", .{});
        return;
    }
    const name = args[0];

    const cfg_path = try writableConfigPath(allocator);
    defer allocator.free(cfg_path);

    var cfg = try loadOrInitConfig(allocator, cfg_path);
    defer cfg.deinit(allocator);

    var idx_to_remove: ?usize = null;
    for (cfg.profiles, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.name, name)) {
            idx_to_remove = idx;
            break;
        }
    }

    const idx = idx_to_remove orelse {
        std.debug.print("Profile not found: {s}\n", .{name});
        return;
    };

    cfg.profiles[idx].deinit(allocator);

    var list: std.ArrayList(app_config.ProfileEntry) = .{};
    defer list.deinit(allocator);
    for (cfg.profiles, 0..) |entry, i| {
        if (i == idx) continue;
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .profile = .{
                .base_url = if (entry.profile.base_url) |v| try allocator.dupe(u8, v) else null,
                .openapi_spec = if (entry.profile.openapi_spec) |v| try allocator.dupe(u8, v) else null,
            },
        });
    }

    allocator.free(cfg.profiles);
    cfg.profiles = try list.toOwnedSlice(allocator);

    if (cfg.current_profile) |cur| {
        if (std.mem.eql(u8, cur, name)) {
            allocator.free(cur);
            cfg.current_profile = null;
        }
    }

    try app_config.saveConfigFile(allocator, cfg_path, cfg);
    std.debug.print("Profile removed: {s}\n", .{name});
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

fn printUsage() void {
    std.debug.print(
        \\orion profile <command>
        \\
        \\Commands:
        \\  list [--output json]
        \\  add <name> [--base-url URL] [--spec PATH]
        \\  remove <name>
        \\
    , .{});
}
