const std = @import("std");
const app_config = @import("../config/config.zig");
const loader = @import("../openapi/loader.zig");

const OutputMode = enum {
    text,
    json,
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var output: OutputMode = .text;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutputMode;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) output = .json else if (std.mem.eql(u8, args[i], "text")) output = .text else return error.InvalidOutputMode;
            continue;
        }
        return error.UnknownFlag;
    }

    var loaded = try app_config.loadMerged(allocator);
    defer loaded.deinit(allocator);

    const spec_path = loader.resolveSpecPath(allocator) catch null;
    defer if (spec_path) |p| allocator.free(p);

    var operations_count: usize = 0;
    var spec_load_ok = false;
    if (spec_path) |p| {
        var ops = loader.loadOperationsFromFile(allocator, p) catch null;
        if (ops) |*list| {
            defer list.deinit(allocator);
            operations_count = list.items.len;
            spec_load_ok = true;
        }
    }

    const has_base_url = loaded.config.base_url != null;
    const has_project_config = loaded.project_path != null;

    if (output == .json) {
        const Json = struct {
            global_config_path: []const u8,
            global_config_found: bool,
            project_config_found: bool,
            base_url_set: bool,
            spec_path: ?[]const u8,
            spec_load_ok: bool,
            operations_count: usize,
        };

        std.debug.print("{f}\n", .{std.json.fmt(Json{
            .global_config_path = loaded.global_path,
            .global_config_found = loaded.global_exists,
            .project_config_found = has_project_config,
            .base_url_set = has_base_url,
            .spec_path = spec_path,
            .spec_load_ok = spec_load_ok,
            .operations_count = operations_count,
        }, .{})});
        return;
    }

    std.debug.print("Doctor\n", .{});
    std.debug.print("  global config: {s} ({s})\n", .{ loaded.global_path, if (loaded.global_exists) "found" else "missing" });
    std.debug.print("  project config: {s}\n", .{if (has_project_config) "found" else "missing"});
    std.debug.print("  base_url: {s}\n", .{if (has_base_url) "set" else "unset"});
    std.debug.print("  spec path: {s}\n", .{if (spec_path) |p| p else "unresolved"});
    std.debug.print("  spec parse: {s}\n", .{if (spec_load_ok) "ok" else "failed"});
    std.debug.print("  operations: {d}\n", .{operations_count});
}
