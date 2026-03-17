const std = @import("std");

pub const Operation = struct {
    id: []u8,
    method: []u8,
    path: []u8,
    summary: ?[]u8 = null,

    pub fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.method);
        allocator.free(self.path);
        if (self.summary) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub const OperationList = struct {
    items: []Operation,

    pub fn deinit(self: *OperationList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};
