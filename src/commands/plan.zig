const std = @import("std");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: orion plan <goal text> [--output text|json]\n", .{});
        return;
    }

    var output_json = false;
    var goal_parts: std.ArrayList([]const u8) = .{};
    defer goal_parts.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutput;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) output_json = true else if (std.mem.eql(u8, args[i], "text")) output_json = false else return error.InvalidOutput;
            continue;
        }
        try goal_parts.append(allocator, arg);
    }

    const goal = try std.mem.join(allocator, " ", goal_parts.items);
    defer allocator.free(goal);

    const spec_path = try loader.resolveSpecPath(allocator);
    defer allocator.free(spec_path);
    var ops = try loader.loadOperationsFromFile(allocator, spec_path);
    defer ops.deinit(allocator);

    const Candidate = struct { score: usize, id: []const u8, summary: ?[]const u8 };
    var cands: std.ArrayList(Candidate) = .{};
    defer cands.deinit(allocator);

    for (ops.items) |op| {
        var score: usize = 0;
        if (std.mem.indexOf(u8, op.id, goal) != null) score += 10;
        if (std.mem.indexOf(u8, op.path, goal) != null) score += 8;
        if (op.summary) |s| {
            if (std.mem.indexOf(u8, s, goal) != null) score += 6;
        }
        if (score > 0) {
            try cands.append(allocator, .{ .score = score, .id = op.id, .summary = op.summary });
        }
    }

    std.mem.sort(Candidate, cands.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const max = @min(@as(usize, 5), cands.items.len);
    if (output_json) {
        std.debug.print("{f}\n", .{std.json.fmt(cands.items[0..max], .{})});
        return;
    }

    std.debug.print("Goal: {s}\n", .{goal});
    if (max == 0) {
        std.debug.print("No matching operations found.\n", .{});
        return;
    }
    std.debug.print("Suggested plan:\n", .{});
    for (cands.items[0..max], 0..) |c, idx| {
        std.debug.print("{d}. Inspect: orion describe {s}\n", .{ idx + 1, c.id });
        std.debug.print("   Then call: orion call {s}\n", .{c.id});
    }
}
