const std = @import("std");

/// A wrapper around an allocator to hold the memory
/// of previously deleted items, but serving it when needed
/// instead of allocating new bytes.\
/// https://zig.news/xq/cool-zig-patterns-gotta-alloc-fast-23h  (c)
pub fn Cache(comptime T: type) type {
    return struct {
        const List = std.DoublyLinkedList(T);
        const Self = @This();

        arena: std.heap.ArenaAllocator = undefined,
        free: List = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        }
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
        pub fn new(self: *Self) !*T {
            const obj = if (self.free.popFirst()) |item|
                item
            else
                try self.arena.allocator().create(List.Node);
            return &obj.data;
        }
        pub fn reuse(self: *Self, obj: *T) void {
            const node = @fieldParentPtr(List.Node, "data", obj);
            self.free.append(node);
        }
        pub fn destroy(self: *Self, obj: *T) void {
            const node = @fieldParentPtr(List.Node, "data", obj);
            self.arena.allocator().destroy(node);
        }
        pub fn clear(self: *Self) void {
            while (self.free.len > 0) {
                self.destroy(&self.free.pop().?.data);
            }
        }
    };
}
