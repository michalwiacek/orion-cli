const std = @import("std");
const http = @import("../http/client.zig");

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

const Record = struct {
    method: []u8,
    url: []u8,
    target: []u8,
    body_b64: ?[]u8,

    fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        allocator.free(self.target);
        if (self.body_b64) |b| allocator.free(b);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: orion rerun <history-id> [--dry-run] [--output text|json]\n", .{});
        return;
    }

    var dry_run = false;
    var output: OutputMode = .text;
    var id_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutputMode;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) output = .json else if (std.mem.eql(u8, args[i], "text")) output = .text else return error.InvalidOutputMode;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownFlag;
        if (id_str != null) return error.UnexpectedPositionalArg;
        id_str = arg;
    }

    const wanted_id = id_str orelse return error.MissingHistoryId;
    const wanted = try std.fmt.parseInt(usize, wanted_id, 10);
    if (wanted == 0) return error.InvalidHistoryId;

    var record = (try loadHistoryRecordById(allocator, wanted)) orelse {
        std.debug.print("History id not found: {s}\n", .{wanted_id});
        return;
    };
    defer record.deinit(allocator);

    const method = try parseMethod(record.method);

    var body: ?[]u8 = null;
    defer if (body) |b| allocator.free(b);
    if (record.body_b64) |encoded| {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch 0;
        if (decoded_len > 0) {
            body = try allocator.alloc(u8, decoded_len);
            std.base64.standard.Decoder.decode(body.?, encoded) catch {
                allocator.free(body.?);
                body = null;
            };
        }
    }

    if (dry_run) {
        if (output == .json) {
            const Dry = struct {
                dry_run: bool,
                method: []const u8,
                url: []const u8,
                target: []const u8,
                body: ?[]const u8,
            };
            std.debug.print("{f}\n", .{std.json.fmt(Dry{
                .dry_run = true,
                .method = record.method,
                .url = record.url,
                .target = record.target,
                .body = body,
            }, .{})});
        } else {
            std.debug.print("Dry run: true\n", .{});
            std.debug.print("Method: {s}\n", .{record.method});
            std.debug.print("URL: {s}\n", .{record.url});
            if (body) |b| std.debug.print("Body: {s}\n", .{b});
        }
        return;
    }

    const content_type: ?[]const u8 = if (body != null) "application/json" else null;
    const res = try http.request(allocator, method, record.url, if (body) |b| b else null, content_type);
    defer allocator.free(res.body);

    if (output == .json) {
        const Out = struct {
            rerun_id: usize,
            method: []const u8,
            url: []const u8,
            status: u16,
            body: []const u8,
        };
        std.debug.print("{f}\n", .{std.json.fmt(Out{
            .rerun_id = wanted,
            .method = record.method,
            .url = record.url,
            .status = res.status,
            .body = res.body,
        }, .{})});
    } else {
        std.debug.print("Method: {s}\n", .{record.method});
        std.debug.print("URL: {s}\n", .{record.url});
        std.debug.print("Status: {d}\n", .{res.status});
        std.debug.print("{s}\n", .{res.body});
    }
}

fn loadHistoryRecordById(allocator: std.mem.Allocator, wanted: usize) !?Record {
    const history_path = try historyFilePath(allocator);
    defer allocator.free(history_path);

    const file = std.fs.openFileAbsolute(history_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(bytes);

    var rows: std.ArrayList(RawRecord) = .{};
    defer rows.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(RawRecord, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        try rows.append(allocator, parsed.value);
    }

    if (rows.items.len == 0 or wanted > rows.items.len) return null;

    const idx_from_end = wanted - 1;
    const row = rows.items[rows.items.len - 1 - idx_from_end];

    return .{
        .method = try allocator.dupe(u8, row.method),
        .url = try allocator.dupe(u8, row.url),
        .target = try allocator.dupe(u8, row.target),
        .body_b64 = if (row.body_b64) |v| try allocator.dupe(u8, v) else null,
    };
}

fn parseMethod(raw: []const u8) !std.http.Method {
    if (std.ascii.eqlIgnoreCase(raw, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(raw, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(raw, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(raw, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(raw, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(raw, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(raw, "OPTIONS")) return .OPTIONS;
    if (std.ascii.eqlIgnoreCase(raw, "TRACE")) return .TRACE;
    return error.UnsupportedMethod;
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
