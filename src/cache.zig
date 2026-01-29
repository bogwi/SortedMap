const std = @import("std");

/// A wrapper around an allocator to hold the memory
/// of previously deleted items, but serving it when needed
/// instead of allocating new bytes.\
/// https://zig.news/xq/cool-zig-patterns-gotta-alloc-fast-23h  (c)
pub fn Cache(comptime T: type) type {
    return struct {
        const Node = struct {
            node: std.DoublyLinkedList.Node = .{},
            data: T = undefined,
        };
        const Self = @This();

        arena: std.heap.ArenaAllocator = undefined,
        free_head: ?*std.DoublyLinkedList.Node = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        }
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
        pub fn new(self: *Self) !*T {
            const obj = if (self.free_head) |node_ptr| blk: {
                self.free_head = node_ptr.next;
                if (node_ptr.next) |next| {
                    next.prev = null;
                }
                break :blk @as(*Node, @alignCast(@fieldParentPtr("node", node_ptr)));
            } else
                try self.arena.allocator().create(Node);
            return &obj.data;
        }
        pub fn reuse(self: *Self, obj: *T) void {
            const node = @as(*Node, @fieldParentPtr("data", obj));
            node.node.next = self.free_head;
            node.node.prev = null;
            if (self.free_head) |head| {
                head.prev = &node.node;
            }
            self.free_head = &node.node;
        }
        pub fn destroy(self: *Self, obj: *T) void {
            const node = @as(*Node, @fieldParentPtr("data", obj));
            self.arena.allocator().destroy(node);
        }
        pub fn clear(self: *Self) void {
            var current = self.free_head;
            while (current) |node_ptr| {
                const next = node_ptr.next;
                const node = @as(*Node, @fieldParentPtr("node", node_ptr));
                self.arena.allocator().destroy(node);
                current = next;
            }
            self.free_head = null;
        }
        pub fn len(self: *const Self) usize {
            var count: usize = 0;
            var current = self.free_head;
            while (current) |node_ptr| {
                count += 1;
                current = node_ptr.next;
            }
            return count;
        }
    };
}
