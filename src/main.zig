const std = @import("std");

const cmd_list = @import("commands/list.zig");
const cmd_call = @import("commands/call.zig");
const cmd_curl = @import("commands/curl.zig");
const cmd_describe = @import("commands/describe.zig");
const cmd_config = @import("commands/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "list")) {
        try cmd_list.run(allocator);
    } else if (std.mem.eql(u8, command, "call")) {
        try cmd_call.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "curl")) {
        try cmd_curl.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "describe")) {
        try cmd_describe.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "config")) {
        try cmd_config.run(allocator, args[2..]);
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
        \\
    , .{});
}
