// Contact the author: https://github.com/bogwi

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const eql = std.meta.eql;
const sEql = std.mem.eql;
const absCast = std.math.absCast;

const MapMode = enum { set, list };

/// A contiguous, growable map of key-value pairs in memory, sorted by key.
///
/// Put and get operations are expected to be nlog(n). Slice and range operations are supported.
/// Keys can be numeric or literal. Values, any type.
/// Works as either `.set` or `.list`; just pass the enum as the `mode` argument.
/// The `.list` mode allows duplicate keys.
/// Has a built-in cache for memory efficiency.
///
/// IMPORTANT:
/// (1) Numeric keys, integers or floats must fall within a range of
/// min64(for the type) < user key < max64(for the type).
/// However, the check is not enforced to avoid slowing down the `put' function.\
/// (2) Literal keys are of type `[]const u8'. The maximum key size for literals is ASCII `255`, `"ÿ"`.
pub fn SortedMap(comptime KEY: type, comptime VALUE: type, comptime mode: MapMode) type {
    const keyIsString: bool = comptime if (KEY == []const u8) true else false;

    return struct {
        const MAXSIZE = if (keyIsString) @as([]const u8, "ÿ") else if ((@typeInfo(KEY) == .Int) or (@typeInfo(KEY) == .Float)) @as(KEY, @bitCast(std.math.inf(f64))) else @compileError("THE KEYS MUST BE NUMERIC OR LITERAL");

        /// A field struct containing a key-value pair.
        ///
        /// Format is this: { KEY, VALUE }\
        /// Accessed VALUE must be tested for null.
        pub const Item = struct { key: KEY, value: VALUE };

        pub const Node = struct {
            item: Item = undefined,
            next: ?*Node = null,
            parent: ?*Node = null,
            width: usize = 0,
            prev: ?*Node = null,
        };

        const SortedMapError = error{
            EmptyList,
            StartKeyIsGreaterThanEndKey,
            StartIndexIsGreaterThanEndIndex,
            MissingKey,
            MissingStartKey,
            MissingEndKey,
            InvalidIndex,
            StepIndexIsZero,
        };

        const Self = @This();
        const Stack = std.ArrayList(*Node);
        const Cache = @import("cache.zig").Cache(Node);
        /// Fixed probability of map growth up in "express lines."
        const p: u3 = 7;

        var mutex = std.Thread.Mutex{};

        trailer: *Node = undefined,
        header: *Node = undefined,
        size: usize = 0,
        alloc: Allocator = undefined,
        /// Coroutine control helper. No usage!
        stack: Stack = undefined,
        /// Stores all the nodes and manages their lifetime.
        var cache: Cache = undefined;

        // NON-PUBLIC API, HELPER FUNCTIONS //

        pub fn cache_(self: *Self) Cache {
            _ = self;
            return cache;
        }

        fn gTE(lhs: anytype, rhs: anytype) bool {
            if (keyIsString) {
                const answer = std.mem.order(u8, lhs, rhs);
                return answer == .gt or answer == .eq;
            }
            return lhs >= rhs;
        }
        fn gT(lhs: anytype, rhs: anytype) bool {
            return if (keyIsString) std.mem.order(u8, lhs, rhs) == .gt else lhs > rhs;
        }
        /// Equality test function for string literals and numerics
        fn EQL(lhs: anytype, rhs: anytype) bool {
            return if (keyIsString) sEql(u8, lhs, rhs) else eql(lhs, rhs);
        }

        /// Creates the node
        fn makeNode(item: Item, next: ?*Node, parent: ?*Node, width: usize, prev: ?*Node) !*Node {
            var node: *Node = try cache.new();
            node.item = item;
            node.next = next;
            node.parent = parent;
            node.prev = prev;
            node.width = width;
            return node;
        }
        // Get random generator variables
        var prng: std.rand.DefaultPrng = undefined;
        var random: std.rand.Random = undefined;

        fn makeHeadAndTail(self: *Self) !void {
            self.trailer = try makeNode(
                Item{ .key = MAXSIZE, .value = undefined },
                null,
                null,
                0,
                self.header,
            );
            self.header = try makeNode(
                Item{ .key = MAXSIZE, .value = undefined },
                self.trailer,
                null,
                0,
                null,
            );
        }

        fn insertNodeWithAllocation(self: *Self, item: Item, prev: ?*Node, parent: ?*Node, width: usize) !*Node {
            _ = self;
            prev.?.next.?.prev = try makeNode(item, prev.?.next, parent, width, prev);
            prev.?.next = prev.?.next.?.prev.?;
            return prev.?.next.?;
        }

        fn addNewLayer(self: *Self) !void {
            self.header = try makeNode(
                Item{ .key = MAXSIZE, .value = undefined },
                self.trailer,
                self.header,
                0,
                null,
            );
        }

        fn initRnd() !void {
            prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.os.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            random = prng.random();
        }
        fn height(self: *Self) usize {
            var node = self.header;
            var height_: usize = 0;

            while (node.parent != null) : (height_ += 1) {
                node = node.parent.?;
            }
            return height_;
        }
        /// Used by removeSlice
        fn getLevelStackPrev(self: *Self, key: KEY) !Stack {
            self.stack.clearRetainingCapacity();
            var node = self.header;
            var foundKey: bool = false;
            assert(node.parent != null);
            while (node.parent != null) {
                node = node.parent.?;
                while (gT(key, node.next.?.item.key)) {
                    node = node.next.?;
                }
                if (EQL(key, node.next.?.item.key)) foundKey = true;
                try self.stack.append(node);
            }
            if (!foundKey) {
                self.stack.clearRetainingCapacity();
            }
            return self.stack;
        }
        /// Used by removeSlice
        fn getLevelStackFirst(self: *Self, key: KEY) !Stack {
            self.stack.clearRetainingCapacity();
            var node = self.header;
            var foundKey: bool = false;
            assert(node.parent != null);
            while (node.parent != null) {
                node = node.parent.?;
                while (EQL(key, node.item.key))
                    node = node.prev.?;

                while (gTE(key, node.next.?.item.key)) {
                    node = node.next.?;
                    if (EQL(key, node.item.key)) {
                        foundKey = true;
                        break;
                    }
                }
                try self.stack.append(node);
            }
            if (!foundKey) {
                self.stack.clearRetainingCapacity();
            }
            return self.stack;
        }
        /// Used by fetchRemove and put
        fn getLevelStack(self: *Self, key: KEY) !Stack {
            self.stack.clearRetainingCapacity();
            var node = self.header;
            assert(node.parent != null);
            while (node.parent != null) {
                node = node.parent.?;
                while (gTE(key, node.next.?.item.key)) {
                    node = node.next.?;
                }
                try self.stack.append(node);
            }
            return self.stack;
        }
        /// Used by fetchRemoveByIndex
        fn getLevelStackByIndex(self: *Self, index: u64) !Stack {
            self.stack.clearRetainingCapacity();
            var index_ = index;
            var node = self.header;
            index_ += 1;
            while (node.parent != null) {
                node = node.parent.?;
                while (!eql(node.next.?.item.key, MAXSIZE) and index_ >= node.next.?.width) {
                    index_ -= node.next.?.width;
                    node = node.next.?;
                }
                try self.stack.append(node);
            }
            return self.stack;
        }
        fn width_(self: *Self, node: *Node, key: KEY) usize {
            _ = self;
            var node__: *Node = node;
            var width: usize = 0;

            while (node__.parent != null) {
                node__ = node__.parent.?;
                while (gTE(key, node__.next.?.item.key)) {
                    width += node__.next.?.width;
                    node__ = node__.next.?;
                }
            }
            return width;
        }
        fn groundLeft(self: *Self) *Node {
            var node = self.header;
            while (node.parent != null)
                node = node.parent.?;
            return node.next.?;
        }
        fn groundRight(self: *Self) *Node {
            var key = MAXSIZE;
            var node = self.header;
            while (node.parent != null) {
                node = node.parent.?;
                while (gT(key, node.next.?.item.key)) {
                    node = node.next.?;
                }
            }
            return node;
        }
        fn removeLoop(self: *Self, key: KEY, stack: *Stack) void {
            _ = self;
            while (stack.items.len > 0) {
                var node: *Node = stack.pop();
                if (!keyIsString) {
                    if (eql(key, node.item.key)) {
                        if (node.next.?.parent != null) {
                            node.next.?.width += node.width - 1;
                        }
                        node.prev.?.next = node.next.?;
                        node.next.?.prev = node.prev.?;
                        cache.reuse(node); // reuse allocated memory
                    } else {
                        node.next.?.width -|= 1;
                    }
                } else {
                    if (sEql(u8, key, node.item.key)) {
                        if (node.next.?.parent != null) {
                            node.next.?.width += node.width - 1;
                        }
                        node.prev.?.next = node.next.?;
                        node.next.?.prev = node.prev.?;
                        cache.reuse(node); // reuse allocated memory
                    } else {
                        node.next.?.width -|= 1;
                    }
                }
            }
        }
        fn getNodePtrByIndex(self: *Self, index: i64) ?*Node {
            if (absCast(index) >= self.size) return null;
            var index_: u64 = if (index < 0) self.size - absCast(index) else absCast(index);

            var node = self.header;
            index_ += 1;
            while (node.parent != null) {
                node = node.parent.?;
                while (!eql(node.next.?.item.key, MAXSIZE) and index_ >= node.next.?.width) {
                    index_ -= node.next.?.width;
                    node = node.next.?;
                }
            }
            return node;
        }

        //////////////////// PUBLIC API //////////////////////

        /// Initiate the SortedMAP with the given allocator.
        pub fn init(alloc: Allocator) !Self {
            // Initiate random generator
            try initRnd();

            // Init the Allocator wrapper for storing nodes
            // cache.arena = std.heap.ArenaAllocator.init(alloc);
            // cache = Cache.init(alloc);
            cache = Cache.init(alloc);

            // Initiate the SortedMap's header and trailer
            // try self.makeHeadAndTail();
            // try self.addNewLayer();
            var trailer: *Node = undefined;
            var header: *Node = undefined;

            trailer = try makeNode(
                Item{ .key = MAXSIZE, .value = undefined },
                null,
                null,
                0,
                header,
            );
            header = try makeNode(
                Item{ .key = MAXSIZE, .value = undefined },
                trailer,
                null,
                0,
                null,
            );
            header = try makeNode(
                Item{ .key = MAXSIZE, .value = undefined },
                trailer,
                header,
                0,
                null,
            );

            // self.stack = Stack.init(alloc);
            // self.alloc = alloc;

            return .{ .stack = Stack.init(alloc), .alloc = alloc, .trailer = trailer, .header = header };
        }

        /// De-initialize the map.
        pub fn deinit(self: *Self) void {
            mutex.lock();
            defer mutex.unlock();

            self.stack.deinit();
            cache.deinit();
        }

        /// Clone the Skiplist, using the given allocator. The operation is O(n*log(n)).
        ///
        /// However, due to that the original list is already sorted,
        /// the cost of running this function is incomparably lower than
        /// if building a clone on entirely assorted data. The larger the map, the more effective
        /// this function is. Cloning a map with 1M entries is ~
        /// 5 times faster than building it from the ground.
        ///
        /// Requires `deinit()`.
        pub fn cloneWithAllocator(self: *Self, alloc: Allocator) !Self {
            var new: Self = .{};
            try new.init(alloc);
            var self_items = self.items();
            while (self_items.next()) |item| {
                try new.put(item.key, item.value);
            }
            return new;
        }

        /// Clone the Skiplist, using the same allocator. The operation is O(n*logn).
        ///
        /// However, due to that the original list is already sorted,
        /// the cost of running this function is incomparably lower than
        /// if building a clone on entirely assorted data. The larger the map, the more effective
        /// this function is. Cloning a map with 1M entries is ~
        /// 5 times faster than building it from the ground.
        ///
        /// Requires `deinit()`.
        pub fn clone(self: *Self) !Self {
            // var new: Self = undefined;
            var new = try SortedMap(KEY, VALUE, mode).init(self.alloc);
            var self_items = self.items();
            while (self_items.next()) |item| {
                try new.put(item.key, item.value);
            }
            return new;
        }

        /// Clear the map of all items and clear the cache.
        pub fn clearAndFree(self: *Self) !void {
            mutex.lock();
            defer mutex.unlock();

            cache.clear();
            _ = cache.arena.reset(.free_all);

            // Re-Initiate the SortedMap's header and trailer
            try self.makeHeadAndTail();
            try self.addNewLayer();

            self.size = 0;
        }

        /// Clear the map of all items but retain the cache.
        /// Useful if your map contracts and expands on new data often.
        pub fn clearRetainingCapacity(self: *Self) !void {
            mutex.lock();
            defer mutex.unlock();

            // Reuse all the list
            var node: *Node = self.header;
            cache.reuse(node);
            while (node.parent != null) {
                node = node.parent.?;
                var fringe = node;
                while (!eql(fringe.next.?.item.key, MAXSIZE)) {
                    cache.reuse(fringe);
                    fringe = fringe.next.?;
                }
            }

            // Re-Initiate the SortedMap's header and trailer
            try self.makeHeadAndTail();
            try self.addNewLayer();

            self.size = 0;
        }

        /// Put a given key-value pair into the map. In the `.set` mode,
        /// it will clobber the existing value of an item associated with the key.
        pub fn put(self: *Self, key: KEY, value_: VALUE) !void {
            mutex.lock();
            defer mutex.unlock();

            var stack = try self.getLevelStack(key);

            if (!keyIsString) {
                if (mode == .set and eql(stack.getLast().item.key, key)) {
                    assert(self.update(key, value_));
                    return;
                }
            } else {
                if (mode == .set and sEql(u8, stack.getLast().item.key, key)) {
                    assert(self.update(key, value_));
                    return;
                }
            }

            for (stack.items[0 .. stack.items.len - 1]) |node| {
                if (!eql(node.next.?.item.key, MAXSIZE) and node.parent != null) {
                    node.next.?.width += 1;
                }
            }

            var node: *Node = stack.pop();

            var item: Item = undefined;
            item = Item{ .key = key, .value = value_ };

            var par: *Node = try self.insertNodeWithAllocation(item, node, null, 1);

            while (random.intRangeAtMost(u3, 1, p) == 1) {
                if (stack.items.len > 0) {
                    node = stack.pop();
                    par = try self.insertNodeWithAllocation(
                        item,
                        node,
                        par,
                        self.width_(node, key),
                    );

                    if (!eql(node.next.?.next.?.item.key, MAXSIZE)) {
                        node.next.?.next.?.width -|= node.next.?.width;
                    }
                } else {
                    try self.addNewLayer();
                    par = try self.insertNodeWithAllocation(
                        item,
                        self.header.parent.?,
                        par,
                        self.width_(self.header.parent.?, key),
                    );
                }
            }
            self.size += 1;
        }

        /// Query the map whether it contains an entry associated with the given key
        pub fn contains(self: *Self, key: KEY) bool {
            var node = self.header;
            while (node.parent != null) {
                node = node.parent.?;
                while (gTE(key, node.next.?.item.key)) {
                    node = node.next.?;
                }
            }
            return if (!keyIsString) eql(key, node.item.key) else sEql(u8, key, node.item.key);
        }

        /// Pop the MAP last item's value or null if the map is empty.
        pub fn popOrNull(self: *Self) ?VALUE {
            if (self.size == 0) return null;
            if (self.fetchRemoveByIndex(@bitCast(self.size))) |real|
                return real.value;
            return null;
        }

        /// Pop the MAP last item's value or fail to assert that the map contains at least 1 item.
        pub fn pop(self: *Self) VALUE {
            assert(self.size > 0);
            return self.fetchRemoveByIndex(@bitCast(self.size)).?.value;
        }

        /// Pop the MAP first item's value or null if the map is empty.
        pub fn popFirstOrNull(self: *Self) ?VALUE {
            if (self.size == 0) return null;
            if (self.fetchRemoveByIndex(@as(i64, 0))) |real|
                return real.value;
            return null;
        }

        /// Pop the MAP first item's value or fail to assert that the map contains at least 1 item.
        pub fn popFirst(self: *Self) VALUE {
            assert(self.size > 0);
            return self.fetchRemoveByIndex(@as(i64, 0)).?.value;
        }

        /// Get the MAP last item's value or null if the map is empty.
        pub fn getLastOrNull(self: *Self) ?VALUE {
            if (self.size == 0) return null;
            return self.groundRight().item.value;
        }

        /// Get the MAP last item's value or fail to assert that the map contains at least 1 item.
        pub fn getLast(self: *Self) VALUE {
            assert(self.size > 0);
            return self.groundRight().item.value;
        }

        /// Get the MAP first item's value or null if the map is empty.
        pub fn getFirstOrNull(self: *Self) ?VALUE {
            if (self.size == 0) return null;
            if (self.getItemByIndex(@as(i64, 0))) |real|
                return real.value;
            return null;
        }

        /// Get the MAP first item's value or fail to assert that the map contains at least 1 item.
        pub fn getFirst(self: *Self) VALUE {
            assert(self.size > 0);
            return self.groundLeft().item.value;
        }
        ///
        ///  Remove an entry associated with the given key from the map.
        /// Returns false if the MAP does not contain such entry.
        /// If duplicates keys are present it will remove starting from the utmost right key.
        pub fn remove(self: *Self, key: KEY) bool {
            if (self.size == 0) return false;
            if (self.fetchRemove(key)) |item| {
                _ = item;
                return true;
            }
            return false;
        }

        /// Remove an entry associated with the given index from the map.
        /// Returns false if the MAP does not contain such entry.
        /// Takes negative indices akin to Python's list.
        pub fn removeByIndex(self: *Self, index: i64) bool {
            if (self.size == 0) return false;
            if (self.fetchRemoveByIndex(index)) |item| {
                _ = item;
                return true;
            }
            return false;
        }

        /// Remove an entry associated with the given index from the map and return it to the caller.
        /// Returns null if the MAP does not contain such entry.
        /// Takes negative indices akin to Python's list.
        pub fn fetchRemoveByIndex(self: *Self, index: i64) ?Item {
            mutex.lock();
            defer mutex.unlock();

            if (absCast(index) > self.size) return null;
            var index_: u64 = if (index < 0) self.size -| absCast(index) else absCast(index);

            var stack: Stack = self.getLevelStackByIndex(index_) catch unreachable;
            var item: Item = stack.getLast().*.item;
            var key = item.key;

            self.removeLoop(key, &stack);
            self.size -|= 1;
            return item;
        }

        /// Remove an entry associated with the given keys from the map and return it to the caller.
        /// Returns null if the MAP does not contain such entry.
        pub fn fetchRemove(self: *Self, key: KEY) ?Item {
            mutex.lock();
            defer mutex.unlock();

            var stack: Stack = self.getLevelStack(key) catch unreachable;
            var item: Item = stack.getLast().*.item;
            if (!keyIsString) {
                if (!eql(item.key, key)) return null;
            } else {
                if (!sEql(u8, item.key, key)) return null;
            }

            self.removeLoop(key, &stack);
            self.size -|= 1;
            return item;
        }

        /// Remove slice of entries from `start_key` to (but not including) `stop_key`.
        ///
        /// Returns an error if `start_key` > `stop_key` to indicate the issue.
        /// Returns an error if one of the keys is missing.
        pub fn removeSlice(self: *Self, start_key: KEY, stop_key: KEY) !bool {
            mutex.lock();
            defer mutex.unlock();

            if (self.size == 0) return false;
            if (gT(start_key, stop_key)) return SortedMapError.StartKeyIsGreaterThanEndKey;

            var s = try self.getLevelStackFirst(start_key);
            if (s.items.len == 0) return SortedMapError.MissingStartKey;
            s = try s.clone();
            defer s.deinit();

            var e = if (!EQL(start_key, stop_key)) try self.getLevelStackPrev(stop_key) else try self.getLevelStack(stop_key);
            if (e.items.len == 0) return SortedMapError.MissingEndKey;

            assert(s.items.len == e.items.len);

            var to_delete: u64 = 0;

            while (s.items.len > 0) {
                var s_node: *Node = s.pop();
                var e_node: *Node = e.pop();

                var node: *Node = s_node;
                if (s_node.prev != null and !EQL(s_node.item.key, MAXSIZE))
                    cache.reuse(s_node); // reuse allocated memory

                var width: u64 = node.width;

                while (!eql(node, e_node)) {
                    node = node.next.?;
                    width += node.width;
                    if (!EQL(node.item.key, MAXSIZE))
                        cache.reuse(node); // reuse allocated memory for each layer
                }
                if (node.parent == null) {
                    to_delete = width;
                    width = 0;
                } else {
                    width = node.next.?.width + width -| to_delete;
                    node.next.?.width = width;
                }

                // this ternary expression is simple and trims redundant levels
                if (s_node.prev != null) {
                    s_node.prev.?.next = e_node.next.?;
                    e_node.next.?.prev = s_node.prev.?;
                } else {
                    s_node.next = e_node.next.?;
                    e_node.next.?.prev = s_node;
                }
            }
            self.size -|= to_delete;
            return true;
        }

        /// Remove slice of entries from `start` to (but not including) `stop` indices.
        /// Indices can be negative. Behaves akin to Python's list() class.
        ///
        /// Returns InvalidIndex error if the given indices are out of the map's span.
        pub fn removeSliceByIndex(self: *Self, start: i64, stop: i64) !bool {
            mutex.lock();
            defer mutex.unlock();

            if (start >= self.size) return false;

            var start_: u64 = if (start < 0) self.size -| absCast(start) else absCast(start);
            var stop_: u64 = if (stop < 0) self.size -| absCast(stop) else absCast(stop);

            if (stop >= self.size)
                stop_ = self.size;

            stop_ -|= 1; // stop node is not deleted

            if (start_ == stop_ or start_ > stop_) return SortedMapError.InvalidIndex;

            var s = try self.getLevelStackByIndex(start_);
            s = try s.clone();
            defer s.deinit();
            var e = try self.getLevelStackByIndex(stop_);

            assert(s.items.len == e.items.len);

            while (s.items.len > 0) {
                var s_node: *Node = s.pop();
                var e_node: *Node = e.pop();

                var node: *Node = s_node;
                if (s_node.prev != null and !EQL(s_node.item.key, MAXSIZE))
                    cache.reuse(s_node); // reuse allocated memory

                var width: u64 = node.width;

                while (!eql(node, e_node)) {
                    node = node.next.?;
                    width += node.width;
                    if (!EQL(node.item.key, MAXSIZE))
                        cache.reuse(node); // reuse allocated memory
                }
                if (node.parent == null)
                    width = 0;

                if (node.parent != null) {
                    width = node.next.?.width + width -| (stop_ - start_) -| 1;
                    node.next.?.width = width;
                }

                // this ternary expression is simple and trims redundant levels
                if (s_node.prev != null) {
                    s_node.prev.?.next = e_node.next.?;
                    e_node.next.?.prev = s_node.prev.?;
                } else {
                    s_node.next = e_node.next.?;
                    e_node.next.?.prev = s_node;
                }
            }
            self.size -|= (stop_ + 1) - start_;
            return true;
        }

        /// Return `ReverseIterator`, a struct with `prev` and `reset` methods
        /// to iterate the SortedMap backward. Does not use allocation.
        pub fn itemsReversed(self: *Self) ReverseIterator {
            return ReverseIterator{ .ctx = self, .grr = self.groundRight() };
        }
        /// Use `prev` to iterate through the SortedMap backward.
        /// Use `reset` to reset the fringe back to the last item in the map.
        pub const ReverseIterator = struct {
            ctx: *Self,
            grr: *Node,

            pub fn prev(self: *ReverseIterator) ?Item {
                while (self.grr.prev != null) {
                    var node__ = self.grr;
                    self.grr = node__.prev.?;
                    return node__.item;
                }
                return null;
            }
            pub fn reset(self: *ReverseIterator) void {
                self.grr = self.ctx.groundRight();
            }
        };
        /// Return `Iterator`, a struct with `prev` and `reset` methods
        /// to iterate the SortedMap forward. Does not use allocation.
        pub fn items(self: *Self) Iterator {
            return Iterator{ .ctx = self, .gr = self.groundLeft() };
        }
        /// Use `next` to iterate through the SortedMap forward.
        /// Use `reset` to reset the fringe back to the first item in the map.
        pub const Iterator = struct {
            ctx: *Self,
            gr: *Node,

            pub fn next(self: *Iterator) ?Item {
                while (!eql(self.gr.item.key, MAXSIZE)) {
                    var node__ = self.gr;
                    self.gr = node__.next.?;
                    return node__.item;
                }
                return null;
            }
            pub fn reset(self: *Iterator) void {
                self.gr = self.ctx.groundLeft();
            }
        };

        /// Return the VALUE of an item associated with the min key,
        /// or the VALUE of the very first item in the SortedMap.
        ///
        /// asserts the map's size is > 0
        pub fn min(self: *Self) VALUE {
            assert(self.size > 0);
            return self.groundLeft().item.value;
        }

        /// Return the VALUE of an item associated with the max key,
        /// or the VALUE of the very last item in the SortedMap.
        ///
        /// asserts the map's size is > 0
        pub fn max(self: *Self) VALUE {
            assert(self.size > 0);
            return self.groundRight().item.value;
        }

        /// Return the VALUE of the median item of the SortedMap.
        ///
        /// The median of the map is calculated as in the following example:\
        /// 16 items have the median at index 8(9th item)\
        /// 15 items have the median at index 7(8th item)
        ///
        /// asserts the map's size is > 0.
        pub fn median(self: *Self) VALUE {
            assert(self.size > 0);
            const median_ = @divFloor(self.size, 2);
            return self.getByIndex(@as(i64, @bitCast(median_))).?;
        }

        /// Update the item associated with the given key with a new VALUE.
        ///
        /// Returns false if such item wasn't found, but not an error.
        pub fn update(self: *Self, key: KEY, new_value: VALUE) bool {
            while (self.getNodePtr(key)) |node| {
                node.item.value = new_value;
                return true;
            } else return false;
        }

        /// Get the VALUE of an item associated with the given key,\
        /// or return null if no such item is present in the map.
        pub fn get(self: *Self, key: KEY) ?VALUE {
            while (self.getItem(key)) |item| {
                return item.value;
            } else return null;
        }

        /// Get the Item associated with the given key,\
        /// or return null if no such item is present in the map.
        pub fn getItem(self: *Self, key: KEY) ?Item {
            while (self.getNodePtr(key)) |node| {
                return node.item;
            } else return null;
        }

        /// Get a pointer to the Item associated with the given key,\
        /// or return null if no such item is present in the map.
        fn getNodePtr(self: *Self, key: KEY) ?*Node {
            var node = self.header;
            while (node.parent != null) {
                node = node.parent.?;
                while (gTE(key, node.next.?.item.key)) {
                    node = node.next.?;
                }
            }
            if (!keyIsString) {
                if (eql(node.item.key, key)) {
                    return node;
                } else return null;
            } else {
                if (sEql(u8, node.item.key, key)) {
                    return node;
                } else return null;
            }
        }

        /// Set the defined slice from the `start` to (but not including)
        /// `stop` indices belonging to the map to the given value.
        /// Step equal to 1 means take every item in the slice.
        ///
        /// Supports negative indices akin to Python's list() class.
        pub fn setSliceToValue(self: *Self, start: i64, stop: i64, step: i64, value_: VALUE) !void {
            if (start >= stop) return SortedMapError.StartIndexIsGreaterThanEndIndex;

            var gs = try self.getSlice(start, stop, step);
            gs.setter(value_);
        }

        /// Get the SliceIterator of the defined slice from the `start` to
        /// (but not including) `stop` indices belonging to the map.
        /// Step equal to 1 means take every item in the slice.
        /// Use `next` method to run the slice. Does not use allocation.
        ///
        /// Supports negative indices akin to Python's list() class.
        pub fn getSlice(self: *Self, start: i64, stop: i64, step: i64) !SliceIterator {
            mutex.lock();
            defer mutex.unlock();

            if (start >= stop) return SortedMapError.StartIndexIsGreaterThanEndIndex;

            if (step == 0) return SortedMapError.StepIndexIsZero;

            while (self.getNodePtrByIndex(start)) |node| {
                var stop_: i64 = if (stop > self.size) @as(i64, @bitCast(self.size)) else stop;
                if (stop < -@as(i64, @bitCast(self.size)))
                    stop_ = 0;

                var sni = SliceNodeIterator{
                    .start = node,
                    .stop = if (stop_ < 0) self.size - absCast(stop_) else absCast(stop_),
                    .step = step,
                    .fringe = if (start < 0) self.size - absCast(start) else absCast(start),
                    .step2 = if (step > 0) @as(i64, 0) else step,
                };
                return SliceIterator{ .sni = sni };
            } else return SortedMapError.InvalidIndex;
        }
        /// Use `next` to run the slice from left to right
        pub const SliceIterator = struct {
            sni: SliceNodeIterator,

            pub fn next(self: *SliceIterator) ?Item {
                while (self.sni.next()) |node| {
                    return node.item;
                }
                return null;
            }
            fn setter(self: *SliceIterator, value_: VALUE) void {
                while (self.sni.next()) |node| {
                    node.item.value = value_;
                }
                return;
            }
        };
        /// Use `next` to iterate over the node's pointers in the slice
        pub const SliceNodeIterator = struct {
            start: *Node,
            stop: u64,
            step: i64,
            fringe: u64,
            step2: i64,

            pub fn next(self: *SliceNodeIterator) ?*Node {
                if (self.step > 0) {
                    while (self.fringe < self.stop) {
                        if (@mod(self.step2, self.step) == 0) {
                            self.fringe += 1;
                            self.step2 += 1;

                            var node = self.start;
                            self.start = node.next.?;
                            return node;
                        } else {
                            self.fringe += 1;
                            self.step2 += 1;
                            self.start = self.start.next.?;
                            continue;
                        }
                    }
                } else {
                    while (self.fringe > self.stop) {
                        if (@mod(self.step2, self.step) == 0) {
                            self.fringe -|= 1;
                            self.step2 -= 1;

                            var node = self.start;
                            self.start = node.prev.?;
                            return node;
                        } else {
                            self.fringe -|= 1;
                            self.step2 -= 1;
                            self.start = self.start.prev.?;
                            continue;
                        }
                    }
                }
                // std.debug.print("fringe: {}, stop: {}\n", .{ self.fringe, self.stop });
                return null;
            }
        };

        /// Update the Item associated with the given index with a new VALUE.
        ///
        /// Supports negative (reverse) indexing.
        /// Returns false if such item wasn't found, but not an error.
        pub fn updateByIndex(self: *Self, index: i64, new_value: VALUE) bool {
            while (self.getNodePtrByIndex(index)) |node| {
                node.item.value = new_value;
                return true;
            } else return false;
        }

        /// Get the VALUE of the Item  associated with the given index,\
        /// or return null if no such item is present in the map.
        ///
        /// Supports negative (reverse) indexing.
        pub fn getByIndex(self: *Self, index: i64) ?VALUE {
            while (self.getItemByIndex(index)) |item| {
                return item.value;
            } else return null;
        }

        /// Get the Item  associated with the given index,\
        /// or return null if no such item is present in the map.
        ///
        /// Supports negative (reverse) indexing.
        pub fn getItemByIndex(self: *Self, index: i64) ?Item {
            mutex.lock();
            defer mutex.unlock();

            while (self.getNodePtrByIndex(index)) |node| {
                return node.item;
            } else return null;
        }

        /// Return the index of the Item associated with the given key or
        /// return `null` if no such Item present in the map.
        ///
        /// In the case of duplicate keys, when the SortedMap works in the `.list` mode,
        /// it will return the index of the rightmost Item.
        pub fn getItemIndexByKey(self: *Self, key: KEY) ?i64 {
            var node: *Node = self.header;
            var width: usize = 0;

            while (node.parent != null) {
                node = node.parent.?;
                while (gTE(key, node.next.?.item.key)) {
                    width += node.next.?.width;
                    node = node.next.?;
                }
            }
            return if (EQL(key, node.item.key)) @bitCast(width -| 1) else null;
        }
    };
}

var allocatorT = std.testing.allocator;
const expect = std.testing.expect;

test "SortedMap: simple" {
    var sL = try SortedMap(u64, u64, .set).init(allocatorT);
    defer sL.deinit();

    var keys = std.ArrayList(u64).init(allocatorT);
    defer keys.deinit();

    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();

    var k: u64 = 0;
    while (k < 32) : (k += 1) {
        try keys.append(k);
    }

    random.shuffle(u64, keys.items);
    for (keys.items) |v| {
        try sL.put(v, v);
        try sL.put(v, v + 2);
    }

    try expect(sL.size == 32);
    var items = sL.items();
    while (items.next()) |item| {
        try expect(item.key == item.value - 2);
    }
}

test "SortedMap: basics" {
    var sL = try SortedMap(i64, i64, .list).init(allocatorT);
    defer sL.deinit();

    var keys = std.ArrayList(i64).init(allocatorT);
    defer keys.deinit();

    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();

    var k: i64 = 0;
    while (k < 16) : (k += 1) {
        try keys.append(k);
    }
    random.shuffle(i64, keys.items);
    random.shuffle(i64, keys.items);

    for (keys.items) |v| {
        try sL.put(v, v);
    }

    try expect(sL.median() == 8);

    var step: i64 = 1;
    var slice = try sL.getSlice(-12, 16, step);
    var start: i64 = 16 - 12;
    while (slice.next()) |item| : (start += 1)
        try expect(start == item.key);

    try expect(sL.update(6, 66));
    try expect(sL.updateByIndex(-1, 1551));

    try expect(sL.size == k);
    try expect(sL.trailer.width == 0);
    try expect(sL.min() == 0);
    try expect(sL.getFirst() == 0);

    try expect(sL.getItem(11).?.value == sL.get(11).?);
    try expect(sL.getItemByIndex(11).?.value == sL.getByIndex(-5).?);
    try expect(sL.getItemByIndex(-11).?.value == sL.getByIndex(5).?);

    try expect(sL.max() == 1551);
    try expect(sL.updateByIndex(-1, 15));
    try expect(sL.max() == k - 1);

    try sL.setSliceToValue(0, 5, 1, 99);

    var itemsR = sL.itemsReversed();
    start = 15;
    while (itemsR.prev()) |item| : (start -= 1) {
        if (start < 5)
            try expect(item.value == @as(i64, 99));
    }

    try expect(sL.remove(26) == false);
    try expect(sL.remove(6) == (sL.size == k - 1));
    try expect(sL.remove(0) == (sL.size == k - 2));
    try expect(!sL.contains(0));
    try expect(sL.remove(6) == false);

    try expect(sL.remove(1) == (sL.size == k - 3));
    try expect(!sL.contains(1));
    try expect(sL.remove(12) == (sL.size == k - 4));
    try expect(!sL.contains(12));

    try expect(sL.remove(3) == (sL.size == k - 5));
    try expect(sL.remove(14) == (sL.size == k - 6));
    try expect(sL.getItem(14) == null);

    try sL.put(6, 6);
    try expect(sL.contains(6));
    try sL.put(3, 3);
    try expect(sL.contains(3));
    try sL.put(14, 14);
    try expect(sL.contains(14));

    try expect(sL.removeByIndex(9) == true);

    try expect(sL.fetchRemove(9).?.key == 9);
    try expect(sL.getItemByIndex(9).?.key == sL.fetchRemoveByIndex(9).?.key);

    try expect(sL.getItemByIndex(0).?.key == sL.fetchRemoveByIndex(0).?.key);
    try expect(sL.getItemByIndex(0).?.key == sL.fetchRemoveByIndex(0).?.key);
    try expect(sL.getItemByIndex(0).?.key == sL.fetchRemoveByIndex(0).?.key);
    try expect(sL.getItemByIndex(0).?.key == sL.fetchRemoveByIndex(0).?.key);
    try expect(sL.getItemByIndex(0).?.key == sL.fetchRemoveByIndex(0).?.key);

    for (keys.items) |v| {
        try sL.put(v + 50, v + 50);
    }

    for (keys.items) |v| {
        try sL.put(v, v);
    }

    // var clone = try sL.clone();
    // defer clone.deinit();

    // for (keys.items) |v| {
    //     try clone.put(v, v);
    // }
    // var clone_size = clone.size;
    // try expect(true == try clone.removeSliceByIndex(2, 10));
    // try expect(clone.size == clone_size - 8);

    // for (keys.items) |v| {
    //     try clone.put(v - 100 * 3, v);
    // }

    // clone_size = clone.size;
    // try expect(true == try clone.removeSliceByIndex(2, 20));
    // clone_size -|= 18;
    // try expect(clone.size == clone_size);

    // try expect(true == try clone.removeSlice(8, 50));
    // try expect(true == try clone.removeSliceByIndex(-21, @bitCast(clone.size - 10)));
    // try expect(true == try clone.removeSliceByIndex(-21, -10));

    // clone_size = clone.size;
    // _ = clone.popOrNull();
    // _ = clone.pop();
    // _ = clone.pop();
    // _ = clone.popFirstOrNull();
    // _ = clone.popFirst();
    // _ = clone.popFirst();
    // _ = clone.popFirst();
    // _ = clone.popFirstOrNull();
    // _ = clone.popFirstOrNull();
    // try expect(clone.size == clone_size - 9);

    // try expect(clone.median() == @as(i64, 62));
    // try expect(clone.getFirst() == @as(i64, 62));
    // try expect(clone.getLast() == @as(i64, 62));
    // try expect(clone.size == 1);

    // for (keys.items) |v| {
    //     try clone.put(v - 100 * 3, v - 100 * 3);
    // }

    // const query: i64 = -299;
    // try expect(clone.get(query) == clone.getByIndex(clone.getItemIndexByKey(query).?));
    // try expect(clone.getItemIndexByKey(query - 100) == null);
    // try expect(clone.getItemIndexByKey(query * -1) == null);
    // try expect(clone.getItemIndexByKey(query - 1) != null);

    // try expect(clone.getFirstOrNull().? == @as(i64, -300));
    // try expect(clone.getLastOrNull().? == @as(i64, 62));
}

test "SortedMap: floats" {
    var sL = try SortedMap(f64, f64, .set).init(allocatorT);
    defer sL.deinit();

    var keys = std.ArrayList(f64).init(allocatorT);
    defer keys.deinit();

    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();

    var k: f64 = 0;
    while (k < 16) : (k += 1) {
        try keys.append(k);
    }
    random.shuffle(f64, keys.items);
    random.shuffle(f64, keys.items);

    for (keys.items) |key| {
        try sL.put(key, key + 100);
    }

    try expect(sL.getFirst() == sL.min());
    try expect(sL.getLast() == sL.max());
    try expect(sL.median() == @divFloor(k, 2) + 100);

    //  stop value > map length, rolls down to map length
    try expect(true == try sL.removeSliceByIndex(@as(i64, 8), @as(i64, 88)));
    try expect(sL.max() == @divFloor(k - 1, 2) + 100);
    try expect(sL.median() == @divFloor(k, 4) + 100);
    try expect(true == sL.remove(@as(f64, 7)));
    try expect(true != sL.remove(@as(f64, 7)));

    try expect(true == sL.remove(@as(f64, 6)));
    try expect(true == sL.remove(@as(f64, 0)));
    try expect(true == sL.remove(@as(f64, 5)));
    try expect(true == sL.remove(@as(f64, 1)));
    try expect(true == sL.remove(@as(f64, 3)));
    try expect(true == sL.remove(@as(f64, 4)));

    try expect(sL.size == 1);
    try expect((sL.median() == sL.min()) == (@as(f64, 2 + 100) == sL.max()));

    try expect(sL.removeByIndex(@as(i64, 0)));
    try expect(!sL.removeByIndex(@as(i64, 0)));
    try expect(sL.size == 0);
}

test "SortedMap: a string as a key" {
    var sL = try SortedMap([]const u8, u64, .set).init(allocatorT);
    defer sL.deinit();

    var HeLlo = "HeLlo";
    var HeLLo = "HeLLo";
    var HeLLo2 = "HeLLo";
    var hello = "hello";
    var hello2 = "hello";

    try sL.put(HeLLo, 0);
    try sL.put(HeLlo, 1);
    try sL.put(hello, 2);
    try sL.put(hello2, 3);
    try expect(sL.getFirst() == 0);
    try sL.put(HeLLo2, 4);

    try expect(sL.getFirst() == 4);

    try sL.clearAndFree();

    var message = "Zig is a general-purpose programming language and toolchain for maintaining robust, optimal and reusable software";

    var old_idx: usize = 0;
    var counter: u64 = 0;
    for (message, 0..) |char, idx| {
        if (char == 32) {
            var key = if (message[idx -| 1] == 44) message[old_idx..idx -| 1] else message[old_idx..idx];
            try sL.put(key, counter);
            old_idx = idx + 1;
            counter += 1;
        }
    }
    try sL.put(message[old_idx..], counter + 1);

    try expect(sL.get("Zig") == 0);
    try expect(sL.getItemIndexByKey("Zig") == @as(i64, 0));
    try expect(sL.contains("Zig"));
    try expect(sL.removeByIndex(0));
    try expect(!sL.contains("Zig"));
    try expect(sEql(u8, sL.getItemByIndex(0).?.key, "a"));
    try expect(sL.get("a") == 2);
    try expect(sL.getItemIndexByKey("toolchain") == @as(i64, @bitCast(sL.size - 1)));

    try expect(try sL.removeSliceByIndex(-7, 20)); // will trim the message from the right
    try expect(sL.size == 6);
    try expect(sL.max() == 5);
    try expect(sL.removeByIndex(@bitCast(sL.size - 1)));
    try expect(sL.size == 5);
    try expect(sL.remove("is"));
    try expect(sL.size == 4);

    try expect(try sL.removeSlice("and", "general-purpose"));
    try expect(sL.removeByIndex(@as(i64, 0)));
    try expect(sEql(u8, sL.getItemByIndex(0).?.key, "general-purpose"));
    try expect(sL.getByIndex(@as(i64, 0)) == 3);
    try expect(sL.size == 1);
}
