const std = @import("std");
const testing = std.testing;

const cmd_profile = @import("commands/profile.zig");
const cmd_use = @import("commands/use.zig");
const cmd_current = @import("commands/current.zig");
const cmd_call = @import("commands/call.zig");
const cmd_example = @import("commands/example.zig");
const cmd_search = @import("commands/search.zig");
const cmd_cache = @import("commands/cache.zig");
const cmd_list = @import("commands/list.zig");
const cmd_describe = @import("commands/describe.zig");
const cmd_explain = @import("commands/explain.zig");
const cmd_history = @import("commands/history.zig");
const cmd_rerun = @import("commands/rerun.zig");
const app_config = @import("config/config.zig");

fn enterTmpDir(tmp: *testing.TmpDir, allocator: std.mem.Allocator) ![]u8 {
    const prev = try std.process.getCwdAlloc(allocator);
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    try std.posix.chdir(path);
    return prev;
}

fn writeOpenApi(tmp: *testing.TmpDir) !void {
    const spec =
        \\openapi: 3.0.3
        \\servers:
        \\  - url: http://localhost:3333
        \\paths:
        \\  /health:
        \\    get:
        \\      summary: Health check
        \\      responses:
        \\        '200':
        \\          description: OK
        \\          content:
        \\            application/json:
        \\              schema:
        \\                type: object
        \\                properties:
        \\                  status:
        \\                    type: string
        \\                required: [status]
        \\  /auth/login:
        \\    post:
        \\      summary: Login
        \\      requestBody:
        \\        required: true
        \\        content:
        \\          application/json:
        \\            schema:
        \\              type: object
        \\              properties:
        \\                email:
        \\                  type: string
        \\                password:
        \\                  type: string
        \\              required: [email, password]
        \\      responses:
        \\        '200':
        \\          description: OK
    ;
    try tmp.dir.writeFile(.{ .sub_path = "openapi.remote.yaml", .data = spec });
}

fn writeProjectConfig(tmp: *testing.TmpDir) !void {
    try tmp.dir.makePath(".orion");
    try tmp.dir.writeFile(.{
        .sub_path = ".orion/config.json",
        .data =
        \\{
        \\  "base_url": "http://localhost:3333",
        \\  "openapi_spec": "./openapi.remote.yaml"
        \\}
        ,
    });
}

test "e2e profile add/use/current" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const prev = try enterTmpDir(&tmp, testing.allocator);
    defer {
        std.posix.chdir(prev) catch {};
        testing.allocator.free(prev);
    }

    try cmd_profile.run(testing.allocator, &.{ "add", "dev", "--base-url", "http://localhost:3333", "--spec", "./openapi.remote.yaml" });
    try cmd_use.run(testing.allocator, &.{"dev"});
    try cmd_current.run(testing.allocator, &.{ "--output", "json" });

    var loaded = try app_config.loadMerged(testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.config.current_profile != null);
    try testing.expectEqualStrings("dev", loaded.config.current_profile.?);
    try testing.expect(loaded.config.base_url != null);
    try testing.expectEqualStrings("http://localhost:3333", loaded.config.base_url.?);
}

test "e2e example and call dry-run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const prev = try enterTmpDir(&tmp, testing.allocator);
    defer {
        std.posix.chdir(prev) catch {};
        testing.allocator.free(prev);
    }

    try writeOpenApi(&tmp);
    try writeProjectConfig(&tmp);

    try cmd_example.run(testing.allocator, &.{ "post:/auth/login", "--output", "json" });
    try cmd_call.run(testing.allocator, &.{ "post:/auth/login", "--example", "--dry-run", "--show-body-source" });
}

test "e2e search and fuzzy call target" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const prev = try enterTmpDir(&tmp, testing.allocator);
    defer {
        std.posix.chdir(prev) catch {};
        testing.allocator.free(prev);
    }

    try writeOpenApi(&tmp);
    try writeProjectConfig(&tmp);

    try cmd_search.run(testing.allocator, &.{ "login", "--limit", "3" });
    try cmd_call.run(testing.allocator, &.{ "login", "--dry-run" });
}

test "e2e cache refresh and offline list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const prev = try enterTmpDir(&tmp, testing.allocator);
    defer {
        std.posix.chdir(prev) catch {};
        testing.allocator.free(prev);
    }

    try writeOpenApi(&tmp);
    try writeProjectConfig(&tmp);

    try cmd_cache.run(testing.allocator, &.{ "refresh" });
    try cmd_list.run(testing.allocator, &.{ "--offline", "--output", "json" });
}

test "e2e describe for-agent and explain" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const prev = try enterTmpDir(&tmp, testing.allocator);
    defer {
        std.posix.chdir(prev) catch {};
        testing.allocator.free(prev);
    }

    try writeOpenApi(&tmp);
    try writeProjectConfig(&tmp);

    try cmd_describe.run(testing.allocator, &.{ "get:/health", "--for-agent" });
    try cmd_explain.run(testing.allocator, &.{ "get:/health", "--output", "json" });
}

test "e2e history and rerun dry-run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const prev = try enterTmpDir(&tmp, testing.allocator);
    defer {
        std.posix.chdir(prev) catch {};
        testing.allocator.free(prev);
    }

    try writeOpenApi(&tmp);
    try writeProjectConfig(&tmp);
    try tmp.dir.makePath(".orion");

    const record = "{\"ts_ms\":1,\"target\":\"get:/health\",\"method\":\"get\",\"url\":\"http://localhost:3333/health\",\"status\":200,\"body_source\":\"none\",\"body_b64\":null}\n";
    try tmp.dir.writeFile(.{ .sub_path = ".orion/call_history.jsonl", .data = record });

    try cmd_history.run(testing.allocator, &.{ "--limit", "1", "--output", "json" });
    try cmd_rerun.run(testing.allocator, &.{ "1", "--dry-run", "--output", "json" });
}
