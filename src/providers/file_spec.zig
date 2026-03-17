const std = @import("std");

pub fn load(path: []const u8) !void {
    std.debug.print("Loading OpenAPI file: {s}\n", .{path});
}
