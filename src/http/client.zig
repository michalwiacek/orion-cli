const std = @import("std");

pub const Response = struct {
    status: u16,
    body: []u8,
};

pub fn request(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    content_type: ?[]const u8,
) !Response {
    if (body != null and !method.requestHasBody()) return error.MethodDoesNotSupportBody;

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var headers: [2]std.http.Header = .{
        .{ .name = "accept-encoding", .value = "identity" },
        .{ .name = "content-type", .value = "" },
    };
    var headers_len: usize = 1;
    if (content_type) |ct| {
        headers[1].value = ct;
        headers_len = 2;
    }

    var req = try client.request(method, uri, .{
        .extra_headers = headers[0..headers_len],
    });
    defer req.deinit();

    if (body) |request_body| {
        const mutable_body = try allocator.dupe(u8, request_body);
        defer allocator.free(mutable_body);
        try req.sendBodyComplete(mutable_body);
    } else {
        if (method.requestHasBody()) {
            const empty = try allocator.alloc(u8, 0);
            defer allocator.free(empty);
            try req.sendBodyComplete(empty);
        } else {
            try req.sendBodiless();
        }
    }

    var response = try req.receiveHead(&.{});

    var reader_buf: [1024]u8 = undefined;
    var body_reader = response.reader(&reader_buf);

    const response_body = try body_reader.allocRemaining(allocator, .unlimited);

    return .{
        .status = @intFromEnum(response.head.status),
        .body = response_body,
    };
}

pub fn get(allocator: std.mem.Allocator, url: []const u8) !Response {
    return request(allocator, .GET, url, null, null);
}
