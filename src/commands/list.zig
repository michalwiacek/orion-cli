const std = @import("std");
const loader = @import("../openapi/loader.zig");
const cmd_cache = @import("cache.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var output_json = false;
    var offline = false;
    if (args.len > 0) {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--output")) {
                if (i + 1 >= args.len) {
                    std.debug.print("Usage: orion list [--output text|json] [--offline]\n", .{});
                    return;
                }
                i += 1;
                if (std.mem.eql(u8, args[i], "json")) output_json = true else if (std.mem.eql(u8, args[i], "text")) output_json = false else {
                    std.debug.print("Usage: orion list [--output text|json] [--offline]\n", .{});
                    return;
                }
                continue;
            }
            if (std.mem.eql(u8, args[i], "--offline")) {
                offline = true;
                continue;
            }
            std.debug.print("Usage: orion list [--output text|json] [--offline]\n", .{});
            return;
        }
    }

    if (offline) {
        const path = cmd_cache.cachePath(allocator, false) catch {
            std.debug.print("No offline cache. Run: orion cache refresh\n", .{});
            return;
        };
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch {
            std.debug.print("No offline cache. Run: orion cache refresh\n", .{});
            return;
        };
        defer file.close();

        const bytes = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
        defer allocator.free(bytes);

        if (output_json) {
            std.debug.print("{s}\n", .{bytes});
        } else {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
            defer parsed.deinit();
            const arr = switch (parsed.value) {
                .array => |a| a,
                else => {
                    std.debug.print("Offline cache is invalid. Refresh with: orion cache refresh\n", .{});
                    return;
                },
            };
            std.debug.print("Offline cache entries: {d}\n", .{arr.items.len});
            for (arr.items) |item| {
                const obj = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                const id = obj.get("id") orelse continue;
                const path_v = obj.get("path") orelse continue;
                const summary = obj.get("summary");
                if (summary) |s| {
                    if (s == .string and id == .string and path_v == .string) {
                        std.debug.print("{s}\t{s}\t{s}\n", .{ id.string, path_v.string, s.string });
                    }
                } else if (id == .string and path_v == .string) {
                    std.debug.print("{s}\t{s}\n", .{ id.string, path_v.string });
                }
            }
        }
        return;
    }

    const spec_path = loader.resolveSpecPath(allocator) catch {
        std.debug.print(
            "No OpenAPI spec configured. Set `openapi_spec` in config or add `openapi.remote.yaml` in project root.\n",
            .{},
        );
        return;
    };
    defer allocator.free(spec_path);

    var operations = loader.loadOperationsFromFile(allocator, spec_path) catch |err| {
        printListError(spec_path, err);
        return;
    };
    defer operations.deinit(allocator);

    if (output_json) {
        std.debug.print("{f}\n", .{std.json.fmt(operations.items, .{})});
        return;
    }

    std.debug.print("Spec: {s}\n", .{spec_path});
    std.debug.print("Operations: {d}\n", .{operations.items.len});
    for (operations.items) |op| {
        if (op.summary) |summary| {
            std.debug.print("{s}\t{s}\t{s}\t{s}\n", .{ op.id, op.method, op.path, summary });
        } else {
            std.debug.print("{s}\t{s}\t{s}\n", .{ op.id, op.method, op.path });
        }
    }
}

fn printListError(spec_path: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound => std.debug.print("OpenAPI spec not found: {s}\n", .{spec_path}),
        error.AccessDenied => std.debug.print("Cannot read OpenAPI spec (permission denied): {s}\n", .{spec_path}),
        error.InvalidOpenApiDocument => std.debug.print("Invalid OpenAPI document: {s}\n", .{spec_path}),
        else => std.debug.print("Failed to load OpenAPI spec ({s}): {s}\n", .{ spec_path, @errorName(err) }),
    }
}
