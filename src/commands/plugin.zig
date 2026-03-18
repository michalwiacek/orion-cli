const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        printUsage();
        return;
    }

    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) {
        try listPlugins(allocator);
    } else if (std.mem.eql(u8, sub, "install")) {
        if (args.len != 2) {
            std.debug.print("Usage: orion plugin install <name>\n", .{});
            return;
        }
        try installPlugin(allocator, args[1]);
    } else if (std.mem.eql(u8, sub, "remove")) {
        if (args.len != 2) {
            std.debug.print("Usage: orion plugin remove <name>\n", .{});
            return;
        }
        try removePlugin(allocator, args[1]);
    } else {
        printUsage();
    }
}

fn listPlugins(allocator: std.mem.Allocator) !void {
    const path = try pluginFilePath(allocator, false);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No plugins installed.\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);
    std.debug.print("{s}\n", .{bytes});
}

fn installPlugin(allocator: std.mem.Allocator, name: []const u8) !void {
    var names = try loadPluginNames(allocator);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    for (names.items) |n| {
        if (std.mem.eql(u8, n, name)) {
            std.debug.print("Plugin already installed: {s}\n", .{name});
            return;
        }
    }
    try names.append(allocator, try allocator.dupe(u8, name));

    try savePluginNames(allocator, names.items);
    std.debug.print("Plugin installed (registry placeholder): {s}\n", .{name});
}

fn removePlugin(allocator: std.mem.Allocator, name: []const u8) !void {
    var names = try loadPluginNames(allocator);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var out: std.ArrayList([]u8) = .{};
    defer out.deinit(allocator);

    var removed = false;
    for (names.items) |n| {
        if (std.mem.eql(u8, n, name)) {
            removed = true;
            allocator.free(n);
            continue;
        }
        try out.append(allocator, n);
    }

    if (!removed) {
        std.debug.print("Plugin not found: {s}\n", .{name});
        return;
    }

    try savePluginNames(allocator, out.items);
    std.debug.print("Plugin removed: {s}\n", .{name});
}

fn loadPluginNames(allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .{};

    const path = try pluginFilePath(allocator, false);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice([][]const u8, allocator, bytes, .{});
    defer parsed.deinit();

    for (parsed.value) |name| {
        try out.append(allocator, try allocator.dupe(u8, name));
    }

    return out;
}

fn savePluginNames(allocator: std.mem.Allocator, names: []const []u8) !void {
    const path = try pluginFilePath(allocator, true);
    defer allocator.free(path);

    const payload = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(names, .{})});
    defer allocator.free(payload);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);
}

fn pluginFilePath(allocator: std.mem.Allocator, create_dir: bool) ![]u8 {
    const orion_dir = if (create_dir)
        (try ensureOrionDir(allocator)) orelse return error.CannotCreatePluginDir
    else
        (try findNearestOrionDir(allocator)) orelse return error.PluginStoreMissing;
    defer allocator.free(orion_dir);

    return std.fs.path.join(allocator, &.{ orion_dir, "plugins.json" });
}

fn ensureOrionDir(allocator: std.mem.Allocator) !?[]u8 {
    if (try findNearestOrionDir(allocator)) |existing| return existing;

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const created = try std.fs.path.join(allocator, &.{ cwd, ".orion" });
    std.fs.makeDirAbsolute(created) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.AccessDenied, error.ReadOnlyFileSystem => {
            allocator.free(created);
            return null;
        },
        else => {
            allocator.free(created);
            return err;
        },
    };
    return created;
}

fn findNearestOrionDir(allocator: std.mem.Allocator) !?[]u8 {
    var cwd = try std.process.getCwdAlloc(allocator);
    errdefer allocator.free(cwd);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ cwd, ".orion" });
        if (dirExistsAbsolute(candidate)) {
            allocator.free(cwd);
            return candidate;
        }
        allocator.free(candidate);

        const parent = std.fs.path.dirname(cwd) orelse break;
        if (std.mem.eql(u8, parent, cwd)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(cwd);
        cwd = next;
    }

    allocator.free(cwd);
    return null;
}

fn dirExistsAbsolute(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn printUsage() void {
    std.debug.print(
        \\orion plugin <command>
        \\
        \\Commands:
        \\  list
        \\  install <name>
        \\  remove <name>
        \\
    , .{});
}
