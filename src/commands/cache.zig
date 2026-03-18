const std = @import("std");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: orion cache refresh|show\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[0], "refresh")) {
        try refresh(allocator);
    } else if (std.mem.eql(u8, args[0], "show")) {
        try show(allocator);
    } else {
        std.debug.print("Usage: orion cache refresh|show\n", .{});
    }
}

fn refresh(allocator: std.mem.Allocator) !void {
    const spec_path = try loader.resolveSpecPath(allocator);
    defer allocator.free(spec_path);

    var ops = try loader.loadOperationsFromFile(allocator, spec_path);
    defer ops.deinit(allocator);

    const path = try cachePath(allocator, true);
    defer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    const payload = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(ops.items, .{})});
    defer allocator.free(payload);
    try file.writeAll(payload);

    std.debug.print("Cache refreshed: {s}\n", .{path});
}

fn show(allocator: std.mem.Allocator) !void {
    const path = try cachePath(allocator, false);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Cache is empty. Run: orion cache refresh\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(bytes);
    std.debug.print("{s}\n", .{bytes});
}

pub fn cachePath(allocator: std.mem.Allocator, create_dir: bool) ![]u8 {
    const orion_dir = if (create_dir)
        (try ensureOrionDir(allocator)) orelse return error.CannotCreateCache
    else
        (try findNearestOrionDir(allocator)) orelse return error.CacheNotFound;
    defer allocator.free(orion_dir);

    return std.fs.path.join(allocator, &.{ orion_dir, "spec_cache.json" });
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
