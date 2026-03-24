const std = @import("std");
const loader = @import("../openapi/loader.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: orion explain <operation-id> [--output text|json]\n", .{});
        return;
    }

    var output_json = false;
    var operation_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.MissingOutput;
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) output_json = true else if (std.mem.eql(u8, args[i], "text")) output_json = false else return error.InvalidOutput;
            continue;
        }
        if (operation_id == null) {
            operation_id = arg;
            continue;
        }
        return error.UnexpectedPositionalArg;
    }

    const op = operation_id orelse return error.MissingOperationId;

    const spec_path = loader.resolveSpecPath(allocator) catch {
        std.debug.print(
            "No OpenAPI spec configured. Set `openapi_spec` in config or add `openapi.remote.yaml` in project root.\n",
            .{},
        );
        return;
    };
    defer allocator.free(spec_path);

    var details = (loader.loadOperationDetailsFromFile(allocator, spec_path, op) catch |err| {
        printExplainError(spec_path, err);
        return;
    }) orelse {
        std.debug.print("Operation not found: {s}\n", .{op});
        return;
    };
    defer details.deinit(allocator);

    if (output_json) {
        const payload = struct {
            operation_id: []const u8,
            summary: ?[]const u8,
            method: []const u8,
            path: []const u8,
            request_required: bool,
            request_fields: [][]u8,
            responses: [][]u8,
            flow_hint: []const u8,
        }{
            .operation_id = details.id,
            .summary = details.summary,
            .method = details.method,
            .path = details.path,
            .request_required = details.request_body_required,
            .request_fields = details.request_body_fields,
            .responses = details.responses,
            .flow_hint = flowHint(details.method),
        };
        std.debug.print("{f}\n", .{std.json.fmt(payload, .{})});
        return;
    }

    std.debug.print("Operation: {s}\n", .{details.id});
    std.debug.print("Summary: {s}\n", .{details.summary orelse "(none)"});
    std.debug.print("Method/Path: {s} {s}\n", .{ details.method, details.path });
    std.debug.print("Flow hint: {s}\n", .{flowHint(details.method)});

    if (details.request_body_required) {
        std.debug.print("Input: request body is required\n", .{});
    } else {
        std.debug.print("Input: request body is optional\n", .{});
    }

    if (details.request_body_fields.len > 0) {
        std.debug.print("Expected fields:\n", .{});
        for (details.request_body_fields) |f| std.debug.print("  - {s}\n", .{f});
    }

    if (details.responses.len > 0) {
        std.debug.print("Responses:\n", .{});
        for (details.responses) |r| std.debug.print("  - {s}\n", .{r});
    }
}

fn flowHint(method: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(method, "get")) return "Read/query flow. Safe to repeat.";
    if (std.ascii.eqlIgnoreCase(method, "post")) return "Create/action flow. Validate payload first.";
    if (std.ascii.eqlIgnoreCase(method, "put") or std.ascii.eqlIgnoreCase(method, "patch")) return "Update flow. Consider idempotency and partial updates.";
    if (std.ascii.eqlIgnoreCase(method, "delete")) return "Delete flow. Confirm target and side effects.";
    return "Review endpoint contract before execution.";
}

fn printExplainError(spec_path: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound => std.debug.print("OpenAPI spec not found: {s}\n", .{spec_path}),
        error.AccessDenied => std.debug.print("Cannot read OpenAPI spec (permission denied): {s}\n", .{spec_path}),
        error.InvalidOpenApiDocument => {
            std.debug.print("Invalid OpenAPI document: {s}\n", .{spec_path});
            if (loader.getLastOpenApiErrorDetail()) |detail| {
                std.debug.print("Details: {s}\n", .{detail});
            }
        },
        else => std.debug.print("Explain failed while reading spec ({s}): {s}\n", .{ spec_path, @errorName(err) }),
    }
}
