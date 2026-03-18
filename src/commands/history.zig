const std = @import("std");

const OutputMode = enum {
    text,
    json,
};

const RawRecord = struct {
    ts_ms: i64,
    target: []const u8,
    method: []const u8,
    url: []const u8,
    status: u16,
    body_source: []const u8,
    body_b64: ?[]const u8 = null,
};

const Entry = struct {
    ts_ms: i64,
    target: []u8,
    method: []u8,
    url: []u8,
    status: u16,
    body_source: []u8,
    body_b64: ?[]u8,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.method);
        allocator.free(self.url);
        allocator.free(self.body_source);
        if (self.body_b64) |v| allocator.free(v);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var output: OutputMode = .text;
    var limit: usize = 20;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutputMode;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) output = .json else if (std.mem.eql(u8, args[i], "text")) output = .text else return error.InvalidOutputMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (i + 1 >= args.len) return error.MissingLimitValue;
            i += 1;
            limit = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        return error.UnknownFlag;
    }

    const history_path = try historyFilePath(allocator);
    defer allocator.free(history_path);

    const file = std.fs.openFileAbsolute(history_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (output == .json) {
                std.debug.print("[]\n", .{});
            } else {
                std.debug.print("No history yet.\n", .{});
            }
            return;
        },
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(bytes);

    var entries: std.ArrayList(Entry) = .{};
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(RawRecord, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();

        try entries.append(allocator, .{
            .ts_ms = parsed.value.ts_ms,
            .target = try allocator.dupe(u8, parsed.value.target),
            .method = try allocator.dupe(u8, parsed.value.method),
            .url = try allocator.dupe(u8, parsed.value.url),
            .status = parsed.value.status,
            .body_source = try allocator.dupe(u8, parsed.value.body_source),
            .body_b64 = if (parsed.value.body_b64) |v| try allocator.dupe(u8, v) else null,
        });
    }

    if (output == .json) {
        try printHistoryJson(allocator, entries.items, limit);
    } else {
        printHistoryText(entries.items, limit);
    }
}

fn printHistoryText(entries: []const Entry, limit: usize) void {
    if (entries.len == 0) {
        std.debug.print("No history yet.\n", .{});
        return;
    }

    var shown: usize = 0;
    var idx: usize = entries.len;
    while (idx > 0 and shown < limit) {
        idx -= 1;
        const entry = entries[idx];
        const id = shown + 1;
        std.debug.print("{d}. {d} {s} {s} ({s})\n", .{ id, entry.status, entry.method, entry.target, entry.body_source });
        shown += 1;
    }
}

fn printHistoryJson(allocator: std.mem.Allocator, entries: []const Entry, limit: usize) !void {
    const JsonEntry = struct {
        id: usize,
        ts_ms: i64,
        status: u16,
        method: []const u8,
        target: []const u8,
        url: []const u8,
        body_source: []const u8,
    };

    var out: std.ArrayList(JsonEntry) = .{};
    defer out.deinit(allocator);

    var shown: usize = 0;
    var idx: usize = entries.len;
    while (idx > 0 and shown < limit) {
        idx -= 1;
        const entry = entries[idx];
        try out.append(allocator, .{
            .id = shown + 1,
            .ts_ms = entry.ts_ms,
            .status = entry.status,
            .method = entry.method,
            .target = entry.target,
            .url = entry.url,
            .body_source = entry.body_source,
        });
        shown += 1;
    }

    std.debug.print("{f}\n", .{std.json.fmt(out.items, .{})});
}

fn historyFilePath(allocator: std.mem.Allocator) ![]u8 {
    const orion_dir = (try findNearestOrionDir(allocator)) orelse return error.HistoryNotFound;
    defer allocator.free(orion_dir);
    return std.fs.path.join(allocator, &.{ orion_dir, "call_history.jsonl" });
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
