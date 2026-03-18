const std = @import("std");

const cmd_list = @import("commands/list.zig");
const cmd_call = @import("commands/call.zig");
const cmd_curl = @import("commands/curl.zig");
const cmd_describe = @import("commands/describe.zig");
const cmd_config = @import("commands/config.zig");
const cmd_doctor = @import("commands/doctor.zig");
const cmd_history = @import("commands/history.zig");
const cmd_rerun = @import("commands/rerun.zig");
const cmd_profile = @import("commands/profile.zig");
const cmd_use = @import("commands/use.zig");
const cmd_current = @import("commands/current.zig");
const cmd_search = @import("commands/search.zig");
const cmd_example = @import("commands/example.zig");
const cmd_explain = @import("commands/explain.zig");
const cmd_cache = @import("commands/cache.zig");
const cmd_plan = @import("commands/plan.zig");
const cmd_plugin = @import("commands/plugin.zig");
const cmd_interactive = @import("commands/interactive.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try cmd_interactive.run(allocator, &.{});
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "list")) {
        try cmd_list.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "call")) {
        try cmd_call.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "curl")) {
        try cmd_curl.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "describe")) {
        try cmd_describe.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "config")) {
        try cmd_config.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "doctor")) {
        try cmd_doctor.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "history")) {
        try cmd_history.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "rerun")) {
        try cmd_rerun.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "profile")) {
        try cmd_profile.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "use")) {
        try cmd_use.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "current")) {
        try cmd_current.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "search")) {
        try cmd_search.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "example")) {
        try cmd_example.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "explain")) {
        try cmd_explain.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "cache")) {
        try cmd_cache.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "plan")) {
        try cmd_plan.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "plugin")) {
        try cmd_plugin.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "interactive")) {
        try cmd_interactive.run(allocator, args[2..]);
    } else if (isHttpAlias(command)) {
        try runHttpAlias(allocator, command, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
    }
}
fn printHelp() void {
    std.debug.print(
        \\orion <command>
        \\
        \\Commands:
        \\  list        List endpoints
        \\  describe    Describe endpoint
        \\  call        Call endpoint
        \\  curl        Generate curl command
        \\  config      Show merged config (global + project)
        \\  doctor      Validate setup and OpenAPI loading
        \\  history     Show call history
        \\  rerun       Rerun request from history by id
        \\  profile     Manage named profiles
        \\  use         Set current profile
        \\  current     Show active profile
        \\  search      Fuzzy search operations
        \\  example     Generate example payload from schema
        \\  explain     Explain operation flow
        \\  cache       Refresh/show offline cache
        \\  plan        Build operation plan from goal
        \\  plugin      Manage plugins (placeholder)
        \\  interactive Show TUI-lite operation picker
        \\  get/post/... HTTP aliases for call
        \\
    , .{});
}

fn isHttpAlias(cmd: []const u8) bool {
    return std.ascii.eqlIgnoreCase(cmd, "get") or
        std.ascii.eqlIgnoreCase(cmd, "post") or
        std.ascii.eqlIgnoreCase(cmd, "put") or
        std.ascii.eqlIgnoreCase(cmd, "patch") or
        std.ascii.eqlIgnoreCase(cmd, "delete") or
        std.ascii.eqlIgnoreCase(cmd, "head") or
        std.ascii.eqlIgnoreCase(cmd, "options") or
        std.ascii.eqlIgnoreCase(cmd, "trace");
}

fn runHttpAlias(allocator: std.mem.Allocator, method: []const u8, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: orion {s} <path-or-url> [call flags]\n", .{method});
        return;
    }

    const target = args[0];
    const method_lc = lowerHttpMethod(method);
    var forwarded: std.ArrayList([]u8) = .{};
    defer {
        for (forwarded.items) |arg| allocator.free(arg);
        forwarded.deinit(allocator);
    }

    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
        try forwarded.append(allocator, try allocator.dupe(u8, target));
        try forwarded.append(allocator, try allocator.dupe(u8, "--method"));
        try forwarded.append(allocator, try allocator.dupe(u8, method_lc));
    } else {
        const normalized = if (std.mem.startsWith(u8, target, "/"))
            try allocator.dupe(u8, target)
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{target});
        defer allocator.free(normalized);

        const operation_or_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ method_lc, normalized });
        try forwarded.append(allocator, operation_or_path);
    }

    for (args[1..]) |arg| try forwarded.append(allocator, try allocator.dupe(u8, arg));

    var forwarded_const: std.ArrayList([]const u8) = .{};
    defer forwarded_const.deinit(allocator);
    for (forwarded.items) |arg| try forwarded_const.append(allocator, arg);

    try cmd_call.run(allocator, forwarded_const.items);
}

fn lowerHttpMethod(method: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return "get";
    if (std.ascii.eqlIgnoreCase(method, "POST")) return "post";
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return "put";
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return "patch";
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return "delete";
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return "head";
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return "options";
    if (std.ascii.eqlIgnoreCase(method, "TRACE")) return "trace";
    return "get";
}
