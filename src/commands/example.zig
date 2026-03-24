const std = @import("std");
const loader = @import("../openapi/loader.zig");

const OutputMode = enum { text, json };
const ExampleMode = enum { minimal, full };
const FormatMode = enum { json, yaml };

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: orion example <operation-id> [--mode minimal|full] [--format json|yaml] [--output text|json] [--for-agent]\n", .{});
        return;
    }

    var op_id: ?[]const u8 = null;
    var output: OutputMode = .text;
    var mode: ExampleMode = .minimal;
    var format: FormatMode = .json;
    var for_agent = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mode")) {
            if (i + 1 >= args.len) return error.MissingMode;
            i += 1;
            if (std.mem.eql(u8, args[i], "minimal")) mode = .minimal else if (std.mem.eql(u8, args[i], "full")) mode = .full else return error.InvalidMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) return error.MissingFormat;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) format = .json else if (std.mem.eql(u8, args[i], "yaml")) format = .yaml else return error.InvalidFormat;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutput;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) output = .json else if (std.mem.eql(u8, args[i], "text")) output = .text else return error.InvalidOutput;
            continue;
        }
        if (std.mem.eql(u8, arg, "--for-agent")) {
            for_agent = true;
            continue;
        }

        if (op_id == null) {
            op_id = arg;
            continue;
        }
        return error.UnexpectedPositionalArg;
    }

    const operation_id = op_id orelse return error.MissingOperationId;

    const spec_path = loader.resolveSpecPath(allocator) catch {
        std.debug.print(
            "No OpenAPI spec configured. Set `openapi_spec` in config or add `openapi.remote.yaml` in project root.\n",
            .{},
        );
        return;
    };
    defer allocator.free(spec_path);

    var details = (loader.loadOperationDetailsFromFile(allocator, spec_path, operation_id) catch |err| {
        printExampleError(spec_path, err);
        return;
    }) orelse {
        std.debug.print("Operation not found: {s}\n", .{operation_id});
        return;
    };
    defer details.deinit(allocator);

    const example_json = (try generateExampleFromFields(allocator, details.request_body_fields, mode)) orelse try allocator.dupe(u8, "{\"example\":\"value\"}");
    defer allocator.free(example_json);

    if (output == .json or for_agent) {
        const payload = struct {
            operation_id: []const u8,
            required: bool,
            content_types: [][]u8,
            example_json: []const u8,
            hints: []const []const u8,
        }{
            .operation_id = details.id,
            .required = details.request_body_required,
            .content_types = details.request_body_content_types,
            .example_json = example_json,
            .hints = &.{
                "Use minimal mode for required-only payload.",
                "Use full mode to include optional fields.",
            },
        };
        std.debug.print("{f}\n", .{std.json.fmt(payload, .{})});
        return;
    }

    if (format == .json) {
        std.debug.print("{s}\n", .{example_json});
    } else {
        try printYamlFromFlatJson(allocator, example_json);
    }
}

fn generateExampleFromFields(allocator: std.mem.Allocator, fields: []const []u8, mode: ExampleMode) !?[]u8 {
    if (fields.len == 0) return null;

    var rendered: std.ArrayList([]u8) = .{};
    defer {
        for (rendered.items) |line| allocator.free(line);
        rendered.deinit(allocator);
    }

    for (fields) |field| {
        const sep = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        const name = std.mem.trim(u8, field[0..sep], " \t");
        if (name.len == 0) continue;

        const rest = std.mem.trim(u8, field[sep + 1 ..], " \t");
        const required = std.mem.indexOf(u8, rest, "(required)") != null;
        if (mode == .minimal and !required) continue;

        const type_name = if (std.mem.indexOf(u8, rest, " (")) |idx| rest[0..idx] else rest;
        const value = sampleJsonValueForType(type_name);
        const pair = try std.fmt.allocPrint(allocator, "\"{s}\":{s}", .{ name, value });
        try rendered.append(allocator, pair);
    }

    if (rendered.items.len == 0) return null;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try out.append(allocator, '{');
    for (rendered.items, 0..) |pair, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, pair);
    }
    try out.append(allocator, '}');

    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

fn sampleJsonValueForType(type_name_raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, type_name_raw, " \t");
    if (std.mem.eql(u8, t, "string")) return "\"string\"";
    if (std.mem.eql(u8, t, "integer")) return "0";
    if (std.mem.eql(u8, t, "number")) return "0";
    if (std.mem.eql(u8, t, "boolean")) return "false";
    if (std.mem.startsWith(u8, t, "array<")) return "[]";
    return "{}";
}

fn printYamlFromFlatJson(allocator: std.mem.Allocator, json_obj: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_obj, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.debug.print("example: {s}\n", .{json_obj});
            return;
        },
    };

    var it = obj.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s}: ", .{entry.key_ptr.*});
        switch (entry.value_ptr.*) {
            .string => |s| std.debug.print("{s}\n", .{s}),
            .integer => |v| std.debug.print("{d}\n", .{v}),
            .float => |v| std.debug.print("{d}\n", .{v}),
            .bool => |v| std.debug.print("{s}\n", .{if (v) "true" else "false"}),
            .array => |_| std.debug.print("[]\n", .{}),
            else => std.debug.print("{{}}\n", .{}),
        }
    }
}

fn printExampleError(spec_path: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound => std.debug.print("OpenAPI spec not found: {s}\n", .{spec_path}),
        error.AccessDenied => std.debug.print("Cannot read OpenAPI spec (permission denied): {s}\n", .{spec_path}),
        error.InvalidOpenApiDocument => {
            std.debug.print("Invalid OpenAPI document: {s}\n", .{spec_path});
            if (loader.getLastOpenApiErrorDetail()) |detail| {
                std.debug.print("Details: {s}\n", .{detail});
            }
        },
        else => std.debug.print("Example generation failed while reading spec ({s}): {s}\n", .{ spec_path, @errorName(err) }),
    }
}
