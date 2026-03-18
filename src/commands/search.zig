const std = @import("std");
const loader = @import("../openapi/loader.zig");

const OutputMode = enum { text, json };

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: orion search <query> [--limit N] [--output text|json]\n", .{});
        return;
    }

    var output: OutputMode = .text;
    var limit: usize = 20;
    var query: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--limit")) {
            if (i + 1 >= args.len) return error.MissingLimitValue;
            i += 1;
            limit = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutputMode;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) output = .json else if (std.mem.eql(u8, args[i], "text")) output = .text else return error.InvalidOutputMode;
            continue;
        }
        if (query == null) {
            query = arg;
            continue;
        }
        return error.UnexpectedPositionalArg;
    }

    const q = query orelse return error.MissingQuery;

    const spec_path = try loader.resolveSpecPath(allocator);
    defer allocator.free(spec_path);

    var ops = try loader.loadOperationsFromFile(allocator, spec_path);
    defer ops.deinit(allocator);

    const Result = struct {
        score: usize,
        id: []const u8,
        method: []const u8,
        path: []const u8,
        summary: ?[]const u8,
    };

    var results: std.ArrayList(Result) = .{};
    defer results.deinit(allocator);

    for (ops.items) |op| {
        const score = fuzzyScore(q, op.id, op.path, op.summary);
        if (score == 0) continue;
        try results.append(allocator, .{
            .score = score,
            .id = op.id,
            .method = op.method,
            .path = op.path,
            .summary = op.summary,
        });
    }

    std.mem.sort(Result, results.items, {}, struct {
        fn lessThan(_: void, a: Result, b: Result) bool {
            return a.score > b.score;
        }
    }.lessThan);

    if (output == .json) {
        const max = @min(limit, results.items.len);
        std.debug.print("{f}\n", .{std.json.fmt(results.items[0..max], .{})});
        return;
    }

    if (results.items.len == 0) {
        std.debug.print("No matches.\n", .{});
        return;
    }

    const max = @min(limit, results.items.len);
    for (results.items[0..max]) |r| {
        std.debug.print("{d}\t{s}\t{s}\t{s}\n", .{ r.score, r.id, r.path, r.summary orelse "" });
    }
}

fn fuzzyScore(query: []const u8, id: []const u8, path: []const u8, summary: ?[]const u8) usize {
    var score: usize = 0;
    if (std.mem.eql(u8, query, id)) score += 100;
    if (std.mem.indexOf(u8, id, query) != null) score += 20;
    if (std.mem.indexOf(u8, path, query) != null) score += 10;
    if (summary) |s| {
        if (std.mem.indexOf(u8, s, query) != null) score += 5;
    }
    return score;
}
