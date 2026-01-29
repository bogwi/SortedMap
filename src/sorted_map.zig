// MIT (c) https://github.com/bogwi //

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const eql = std.meta.eql;
const sEql = std.mem.eql;

const MapMode = enum { set, list };

/// A contiguous, growable map of key-value pairs in memory, sorted by key.
///
/// Keys can be numeric or literal. Values, any type.
/// When keys are string literals, it sorts lexicographically.
/// Slice and range operations are supported.
/// Works as either `.set` or `.list`; just pass the enum as the `mode` argument.
/// The `.list` mode allows duplicate keys.
///
/// IMPORTANT: Takes any numeric key except the maximum possible value for the given type.
/// Takes any literal key of type `[]const u8` and of any length,
///  but lexicographically smaller than `"ÿ"` ASCII 255.
///
pub fn SortedMap(comptime KEY: type, comptime VALUE: type, comptime mode: MapMode) type {
    const keyIsString: bool = comptime if (KEY == []const u8) true else false;

    return struct {
        const MAXSIZE = if (keyIsString)
            @as([]const u8, "ÿ")
        else blk: {
            const info = @typeInfo(KEY);
            break :blk switch (info) {
                .int => std.math.maxInt(KEY),
                .float => std.math.inf(KEY),
                else => @compileError("THE KEYS MUST BE NUMERIC OR LITERAL"),
            };
        };

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
            InvalidStopIndex,
            StepIndexIsZero,
        };

        const Self = @This();
        const Stack = std.array_list.Managed(*Node);
        const Cache = @import("cache.zig").Cache(Node);
        /// Fixed probability of map growth up in "express lines."
        const p: u3 = 7;

        trailer: *Node = undefined,
        header: *Node = undefined,
        size: usize = 0,
        alloc: Allocator = undefined,
        /// Coroutine control helper stack. No usage!
        stack: Stack = undefined,
        /// Stores all the nodes and manages their lifetime.
        cache: Cache = undefined,
        /// Instance-level PRNG for thread-safe random number generation
        prng: std.Random.DefaultPrng = undefined,
        /// Per-instance rwlock for thread-safe operations
        rwlock: std.Thread.RwLock = .{},

        // NON-PUBLIC API, HELPER FUNCTIONS //

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
        fn makeNode(cache: *Cache, item: Item, next: ?*Node, parent: ?*Node, width: usize, prev: ?*Node) !*Node {
            var node: *Node = try cache.new();
            node.item = item;
            node.next = next;
            node.parent = parent;
            node.prev = prev;
            node.width = width;
            return node;
        }

        fn makeHeadAndTail(self: *Self) !void {
            self.trailer = try makeNode(
                &self.cache,
                Item{ .key = MAXSIZE, .value = undefined },
                null,
                null,
                0,
                self.header,
            );
            self.header = try makeNode(
                &self.cache,
                Item{ .key = MAXSIZE, .value = undefined },
                self.trailer,
                null,
                0,
                null,
            );
        }

        fn insertNodeWithAllocation(self: *Self, item: Item, prev: ?*Node, parent: ?*Node, width: usize) !*Node {
            prev.?.next.?.prev = try makeNode(&self.cache, item, prev.?.next, parent, width, prev);
            prev.?.next = prev.?.next.?.prev.?;
            return prev.?.next.?;
        }

        fn addNewLayer(self: *Self) !void {
            self.header = try makeNode(
                &self.cache,
                Item{ .key = MAXSIZE, .value = undefined },
                self.trailer,
                self.header,
                0,
                null,
            );
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
            var node = self.header;
            while (node.parent != null) {
                node = node.parent.?;
                while (gT(MAXSIZE, node.next.?.item.key)) {
                    node = node.next.?;
                }
            }
            return node;
        }
        fn removeLoop(self: *Self, key: KEY, stack: *Stack) void {
            while (stack.items.len > 0) {
                var node: *Node = stack.pop() orelse unreachable;
                if (!keyIsString) {
                    if (eql(key, node.item.key)) {
                        if (node.next.?.parent != null) {
                            node.next.?.width += node.width - 1;
                        }
                        node.prev.?.next = node.next.?;
                        node.next.?.prev = node.prev.?;
                        self.cache.reuse(node); // reuse allocated memory
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
                        self.cache.reuse(node); // reuse allocated memory
                    } else {
                        node.next.?.width -|= 1;
                    }
                }
            }
        }

        //////////////////// PUBLIC API //////////////////////

        /// Initiate the SortedMAP with the given allocator.
        pub fn init(alloc: Allocator) !Self {
            // Initiate Cache
            var cache = Cache.init(alloc);

            // Initiate header and trailer
            var trailer: *Node = undefined;
            var header: *Node = undefined;

            trailer = try makeNode(
                &cache,
                Item{ .key = MAXSIZE, .value = undefined },
                null,
                null,
                0,
                header,
            );
            header = try makeNode(
                &cache,
                Item{ .key = MAXSIZE, .value = undefined },
                trailer,
                null,
                0,
                null,
            );
            header = try makeNode(
                &cache,
                Item{ .key = MAXSIZE, .value = undefined },
                trailer,
                header,
                0,
                null,
            );

            // Initiate random generator
            const prng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.posix.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });

            return .{
                .stack = Stack.init(alloc),
                .alloc = alloc,
                .trailer = trailer,
                .header = header,
                .cache = cache,
                .prng = prng,
            };
        }

        /// De-initialize the map.
        pub fn deinit(self: *Self) void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            self.stack.deinit();
            self.cache.deinit();
        }

        /// Clone the Skiplist, using the given allocator. The operation is O(n).
        ///
        /// This function performs a structural clone by directly copying the skip list
        /// structure without re-inserting items. This is much faster than rebuilding
        /// via put() operations.
        ///
        /// Requires `deinit()`.
        pub fn cloneWithAllocator(self: *Self, alloc: Allocator) !Self {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            if (self.size == 0) {
                return try init(alloc);
            }

            // Optimized clone: collect items and rebuild structure
            // Since items are already sorted, we can insert them efficiently
            var items_list = std.ArrayListUnmanaged(Item){};
            defer items_list.deinit(alloc);
            try items_list.ensureTotalCapacity(alloc, self.size);

            // Collect all items from bottom level (already sorted) - O(n)
            var self_items = self.items();
            defer self_items.deinit();
            while (self_items.next()) |item| {
                try items_list.append(alloc, item);
            }

            // Create new map
            var new: Self = try init(alloc);

            // Bulk insert sorted items - this is faster than random inserts
            // because the skip list maintenance is more efficient for sorted data
            for (items_list.items) |item| {
                // Avoid touching rwlock during construction; `new` is not shared yet.
                try new.putAssumedLocked(item.key, item.value);
            }

            return new;
        }

        /// Clone the Skiplist, using the same allocator. The operation is O(n).
        ///
        /// This function performs an optimized clone by collecting items first,
        /// then rebuilding the structure. Since items are already sorted, this
        /// is much faster than individual put() operations.
        ///
        /// Requires `deinit()`.
        pub fn clone(self: *Self) !Self {
            return self.cloneWithAllocator(self.alloc);
        }

        /// Clear the map of all items and clear the cache.
        pub fn clearAndFree(self: *Self) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            self.cache.clear();
            _ = self.cache.arena.reset(.free_all);

            // Re-Initiate the SortedMap's header and trailer
            try self.makeHeadAndTail();
            try self.addNewLayer();

            self.size = 0;
        }

        /// Clear the map of all items but retain the cache.
        /// Useful if your map contracts and expands on new data often.
        pub fn clearRetainingCapacity(self: *Self) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            // Reuse all the list
            var node: *Node = self.header;
            self.cache.reuse(node);
            while (node.parent != null) {
                node = node.parent.?;
                var fringe = node;
                while (!eql(fringe.next.?.item.key, MAXSIZE)) {
                    self.cache.reuse(fringe);
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
            self.rwlock.lock();
            defer self.rwlock.unlock();
            try self.putAssumedLocked(key, value_);
        }

        /// Same logic as `put()`, but assumes the caller is already synchronized
        /// (e.g. `put()` holds `rwlock`, or the map is still being constructed
        /// and not shared with other threads).
        fn putAssumedLocked(self: *Self, key: KEY, value_: VALUE) !void {
            var stack = try self.getLevelStack(key);

            if (!keyIsString) {
                if (mode == .set and eql(stack.getLast().item.key, key)) {
                    assert(self.updateAssumedLocked(key, value_));
                    return;
                }
            } else {
                if (mode == .set and sEql(u8, stack.getLast().item.key, key)) {
                    assert(self.updateAssumedLocked(key, value_));
                    return;
                }
            }

            for (stack.items[0 .. stack.items.len - 1]) |node| {
                if (!eql(node.next.?.item.key, MAXSIZE) and node.parent != null) {
                    node.next.?.width += 1;
                }
            }

            var node: *Node = stack.pop() orelse unreachable;

            var item: Item = undefined;
            item = Item{ .key = key, .value = value_ };

            var par: *Node = try self.insertNodeWithAllocation(item, node, null, 1);

            while (self.prng.random().intRangeAtMost(u3, 1, p) == 1) {
                if (stack.items.len > 0) {
                    node = stack.pop() orelse unreachable;
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
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

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
            return self.fetchRemoveByIndex(@bitCast(self.size - 1)).?.value;
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
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            if (self.size == 0) return null;
            return self.groundRight().item.value;
        }

        /// Get the MAP last item's value or fail to assert that the map contains at least 1 item.
        pub fn getLast(self: *Self) VALUE {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

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
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            assert(self.size > 0);
            return self.groundLeft().item.value;
        }

        /// Check if the map contains at least 1 item.
        /// Puts a shared lock. Is called only by functions that need to check the size before some of their logic has own locking.
        fn checkSizeLocked(self: *Self) bool {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            return self.size > 0;
        }
        ///
        ///  Remove an entry associated with the given key from the map.
        /// Returns false if the MAP does not contain such entry.
        /// If duplicates keys are present it will remove starting from the utmost right key.
        pub fn remove(self: *Self, key: KEY) bool {
            if (!self.checkSizeLocked()) return false;
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
            if (!self.checkSizeLocked()) return false;
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
            self.rwlock.lock();
            defer self.rwlock.unlock();

            if (@abs(index) >= self.size) return null;
            const index_: u64 = if (index < 0) self.size -| @abs(index) else @abs(index);

            var stack: Stack = self.getLevelStackByIndex(index_) catch unreachable;
            const item: Item = stack.getLast().*.item;
            const key = item.key;

            self.removeLoop(key, &stack);
            self.size -|= 1;
            return item;
        }

        /// Remove an entry associated with the given keys from the map and return it to the caller.
        /// Returns null if the MAP does not contain such entry.
        pub fn fetchRemove(self: *Self, key: KEY) ?Item {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            var stack: Stack = self.getLevelStack(key) catch unreachable;
            const item: Item = stack.getLast().*.item;
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
        pub fn removeSliceByKey(self: *Self, start_key: KEY, stop_key: KEY) !bool {
            self.rwlock.lock();
            defer self.rwlock.unlock();

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
                var s_node: *Node = s.pop() orelse unreachable;
                var e_node: *Node = e.pop() orelse unreachable;

                var node: *Node = s_node;
                if (s_node.prev != null and !EQL(s_node.item.key, MAXSIZE))
                    self.cache.reuse(s_node); // reuse allocated memory

                var width: u64 = node.width;

                while (!eql(node, e_node)) {
                    node = node.next.?;
                    width += node.width;
                    if (!EQL(node.item.key, MAXSIZE))
                        self.cache.reuse(node); // reuse allocated memory for each layer
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
            self.rwlock.lock();
            defer self.rwlock.unlock();

            if (start >= self.size) return false;

            const start_: u64 = if (start < 0) self.size -| @abs(start) else @abs(start);
            var stop_: u64 = if (stop < 0) self.size -| @abs(stop) else @abs(stop);

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
                var s_node: *Node = s.pop() orelse unreachable;
                var e_node: *Node = e.pop() orelse unreachable;

                var node: *Node = s_node;
                if (s_node.prev != null and !EQL(s_node.item.key, MAXSIZE))
                    self.cache.reuse(s_node); // reuse allocated memory

                var width: u64 = node.width;

                while (!eql(node, e_node)) {
                    node = node.next.?;
                    width += node.width;
                    if (!EQL(node.item.key, MAXSIZE))
                        self.cache.reuse(node); // reuse allocated memory
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

        /// Return `Iterator` struct to run the SortedMap backward
        /// starting from the right most node. This function is a mere convenience to
        /// `iterByKey()` which lets you specify the starting key, and then go
        /// forward or backward as you need.
        pub fn itemsReversed(self: *Self) LockedIterator {
            self.rwlock.lockShared();
            const node: *Node = self.groundRight();
            return LockedIterator{
                .ctx = self,
                .it = Iterator{ .ctx = self, .gr = node, .rst = node },
            };
        }
        /// Return RAII shared-lock iterator. `Iterator` struct to run the SortedMap forward
        /// starting from the left most node. This function is a mere convenience to
        /// `iterByKey()` which lets you specify the starting key, and then go
        /// forward or backward as you need.
        /// Requires `deinit()` on the returned iterator.
        pub fn items(self: *Self) LockedIterator {
            self.rwlock.lockShared();
            const node: *Node = self.groundLeft();
            return LockedIterator{
                .ctx = self,
                .it = Iterator{ .ctx = self, .gr = node, .rst = node },
            };
        }
        /// Use `next` to iterate through the SortedMap forward.
        /// Use `prev` to iterate through the SortedMap backward.
        /// Use `reset` to reset the fringe back to the starting point.
        pub const Iterator = struct {
            ctx: *Self,
            gr: *Node,
            rst: *Node,

            pub fn next(self: *Iterator) ?Item {
                while (!eql(self.gr.item.key, MAXSIZE)) {
                    const node = self.gr;
                    self.gr = self.gr.next.?;
                    return node.item;
                }
                self.gr = self.ctx.groundRight();
                return null;
            }
            pub fn prev(self: *Iterator) ?Item {
                while (self.gr.prev != null) {
                    const node = self.gr;
                    self.gr = node.prev.?;
                    return node.item;
                }
                // one step fow so we can use next() right away
                self.gr = self.gr.next.?;
                return null;
            }
            pub fn reset(self: *Iterator) void {
                self.gr = self.rst;
            }
        };

        /// A thread-safe iterator that holds `rwlock.lockShared()` for its lifetime.
        /// Call `deinit()` when you’re done iterating.
        ///
        /// IMPORTANT: Do not call map methods that also lock `rwlock` (shared or exclusive)
        /// from the same thread while this iterator is alive, or you may deadlock.
        pub const LockedIterator = struct {
            ctx: *Self,
            it: Iterator,

            pub fn next(self: *LockedIterator) ?Item {
                return self.it.next();
            }
            pub fn prev(self: *LockedIterator) ?Item {
                return self.it.prev();
            }
            pub fn reset(self: *LockedIterator) void {
                self.it.reset();
            }
            pub fn deinit(self: *LockedIterator) void {
                self.ctx.rwlock.unlockShared();
            }
        };
        /// Return `Iterator` struct  to run the SortedMap forward:`next()` or
        /// backward:`prev()` depending on the start_key. Once exhausted,
        /// you can run it in the opposite direction. If you want to start over, call `reset()`.
        /// Reversing the iteration in the process, before it hits the either end of the map,
        /// *has naturally a lag in one node.*
        pub fn iterByKey(self: *Self, start_key: KEY) !LockedIterator {
            self.rwlock.lockShared();
            errdefer self.rwlock.unlockShared();

            if (self.getNodePtr(start_key)) |node| {
                return LockedIterator{
                    .ctx = self,
                    .it = Iterator{ .ctx = self, .gr = node, .rst = node },
                };
            }
            return SortedMapError.MissingStartKey;
        }

        /// Return `Iterator` struct  to run the SortedMap forward:`next()` or
        /// backward:`prev()` depending on the `start_idx`. Once exhausted,
        /// you can run it in the opposite direction. If you want to start over, call `reset()`.
        /// Reversing the iteration in the process, before it hits the either end of the map,
        /// *has naturally a lag in one node.*
        pub fn iterByIndex(self: *Self, start_idx: i64) !LockedIterator {
            self.rwlock.lockShared();
            errdefer self.rwlock.unlockShared();

            if (self.getNodePtrByIndex(start_idx)) |node| {
                return LockedIterator{
                    .ctx = self,
                    .it = Iterator{ .ctx = self, .gr = node, .rst = node },
                };
            }
            return SortedMapError.MissingStartKey;
        }

        /// Return the VALUE of an item associated with the min key,
        /// or the VALUE of the very first item in the SortedMap.
        ///
        /// asserts the map's size is > 0
        pub fn min(self: *Self) VALUE {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            assert(self.size > 0);
            return self.groundLeft().item.value;
        }

        /// Return the VALUE of an item associated with the max key,
        /// or the VALUE of the very last item in the SortedMap.
        ///
        /// asserts the map's size is > 0
        pub fn max(self: *Self) VALUE {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

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
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            assert(self.size > 0);
            const median_ = @divFloor(self.size, 2);
            return self.getByIndex(@as(i64, @bitCast(median_))).?;
        }

        /// Update the item associated with the given key with a new VALUE.
        ///
        /// Returns false if such item wasn't found, but not an error.
        pub fn update(self: *Self, key: KEY, new_value: VALUE) bool {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            while (self.getNodePtr(key)) |node| {
                node.item.value = new_value;
                return true;
            } else return false;
        }
        /// Privat function logically equivalent to update, but assumes the rwlock is already locked. Called from `pub fn put()` to avoid locking the rwlock twice.
        fn updateAssumedLocked(self: *Self, key: KEY, new_value: VALUE) bool {
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
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            while (self.getNodePtr(key)) |node| {
                return node.item;
            } else return null;
        }

        /// Get a pointer to the Node associated with the given key,\
        /// or return null if no such item is present in the map.
        /// Not thread-safe. The **caller** should hold `lockShared()` externally.
        pub fn getNodePtr(self: *Self, key: KEY) ?*Node {
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
        /// `stop` node belonging to the map to the given value.
        /// Step equal to 1 means take every item in the slice.
        ///
        /// Supports negative indices akin to Python's list() class.
        pub fn setSliceByKey(self: *Self, start_key: KEY, stop_key: KEY, step: i64, value: VALUE) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            if (step == 0) return SortedMapError.StepIndexIsZero;

            var gs = try self.getSliceByKeyAssumedLocked(start_key, stop_key, step);
            gs.setter(value);
        }

        /// Get the `SliceIterator` of the defined slice from the `start` to
        /// (but not including) `stop` node belonging to the map.
        /// Step equal to 1 means take every item in the slice.
        /// Use `next()` method to run the slice. Does not use allocation.
        ///
        /// Supports negative indices akin to Python's list() class.
        /// **TODO:** at the moment `SliceIterator` has no `reset()`. If you need to run the same slice
        /// multiple times, call the function so, obtaining the slice is cheap.
        pub fn getSliceByKey(self: *Self, start_key: KEY, stop_key: KEY, step: i64) !LockedSliceIterator {
            self.rwlock.lockShared();
            errdefer self.rwlock.unlockShared();

            const it = try self.getSliceByKeyAssumedLocked(start_key, stop_key, step);
            return LockedSliceIterator{ .ctx = self, .it = it };
        }

        /// Same logic as `getSliceByKey()`, but assumes caller already holds a suitable lock.
        fn getSliceByKeyAssumedLocked(self: *Self, start_key: KEY, stop_key: KEY, step: i64) !SliceIterator {
            if (step == 0) return SortedMapError.StepIndexIsZero;

            while (self.getNodePtr(start_key)) |start_k| {
                while (self.getNodePtr(stop_key)) |stop_k| {
                    const sni = SliceNodeIterator{
                        .start = start_k,
                        .end = stop_k,
                        .step = step,
                    };
                    return SliceIterator{ .sni = sni };
                }
                return SortedMapError.MissingEndKey;
            }
            return SortedMapError.MissingStartKey;
        }
        /// Get a pointer to the Node associated with the given index,\
        /// or return null if the given index is out of the map's size.
        /// Not thread-safe. The **caller** should hold `lockShared()` externally.
        pub fn getNodePtrByIndex(self: *Self, index: i64) ?*Node {
            if (@abs(index) >= self.size) return null;
            var index_: u64 = if (index < 0) self.size - @abs(index) else @abs(index);

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

        /// Set the defined slice from the `start` to (but not including)
        /// `stop` indices belonging to the map to the given value.
        /// Step equal to 1 means take every item in the slice.
        ///
        /// Supports negative indices akin to Python's list() class.
        pub fn setSliceByIndex(self: *Self, start: i64, stop: i64, step: i64, value_: VALUE) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            if (step == 0) return SortedMapError.StepIndexIsZero;

            const size_: i64 = @bitCast(self.size);
            const stop_: i64 = if (stop < 0) size_ + stop else stop;
            if (start >= stop_) return SortedMapError.StartIndexIsGreaterThanEndIndex;

            var gs = try self.getSliceByIndexAssumedLocked(start, stop_, step);
            gs.setter(value_);
        }

        /// Get the `SliceIterator` of the defined slice from the `start` to
        /// (but not including) `stop` indices belonging to the map.
        /// Step equal to 1 means take every item in the slice.
        /// Use `next()` method to run the slice. Does not use allocation.
        ///
        /// Supports negative indices akin to Python's list() class.
        /// **TODO:** at the moment `SliceIterator` has no `reset()`. If you need to run the same slice
        /// multiple times, call the function so, obtaining the slice is cheap.
        pub fn getSliceByIndex(self: *Self, start: i64, stop: i64, step: i64) !LockedSliceIterator {
            self.rwlock.lockShared();
            errdefer self.rwlock.unlockShared();

            const it = try self.getSliceByIndexAssumedLocked(start, stop, step);
            return LockedSliceIterator{ .ctx = self, .it = it };
        }

        /// Same logic as `getSliceByIndex()`, but assumes caller already holds a suitable lock.
        fn getSliceByIndexAssumedLocked(self: *Self, start: i64, stop: i64, step: i64) !SliceIterator {
            if (stop < -@as(i64, @bitCast(self.size)) or stop > self.size)
                return SortedMapError.InvalidStopIndex;
            if (stop < 0)
                if (start >= self.size - @abs(stop)) return SortedMapError.StartIndexIsGreaterThanEndIndex;

            if (step == 0) return SortedMapError.StepIndexIsZero;

            while (self.getNodePtrByIndex(start)) |node| {
                const sni = SliceNodeIterator{
                    .start = node,
                    .stop = if (stop < 0) self.size - @abs(stop) else @abs(stop),
                    .step = step,
                    .fringe = if (start < 0) self.size - @abs(start) else @abs(start),
                    .step2 = if (step > 0) @as(i64, 0) else step,
                };
                return SliceIterator{ .sni = sni };
            } else return SortedMapError.InvalidIndex;
        }
        /// Use `next` to run the slice from left to right
        pub const SliceIterator = struct {
            sni: SliceNodeIterator,

            pub fn next(self: *SliceIterator) ?Item {
                if (self.sni.stop != 0) {
                    while (self.sni.next()) |node| {
                        return node.item;
                    }
                } else {
                    while (self.sni.next2()) |node| {
                        return node.item;
                    }
                }
                return null;
            }
            fn setter(self: *SliceIterator, value: VALUE) void {
                if (self.sni.stop != 0) {
                    while (self.sni.next()) |node| {
                        node.item.value = value;
                    }
                } else {
                    while (self.sni.next2()) |node| {
                        node.item.value = value;
                    }
                }
                return;
            }
        };

        /// Thread-safe slice iterator: holds `rwlock.lockShared()` for its lifetime.
        /// Call `deinit()` when finished iterating.
        ///
        /// IMPORTANT: Do not call other map methods that lock `rwlock` while this iterator
        /// is alive on the same thread (may deadlock).
        pub const LockedSliceIterator = struct {
            ctx: *Self,
            it: SliceIterator,

            pub fn next(self: *LockedSliceIterator) ?Item {
                return self.it.next();
            }
            pub fn deinit(self: *LockedSliceIterator) void {
                self.ctx.rwlock.unlockShared();
            }
        };
        /// Use `next` to iterate over the node's pointers in the slice
        pub const SliceNodeIterator = struct {
            start: *Node,
            end: *Node = undefined,
            stop: u64 = 0,
            step: i64,
            fringe: u64 = 0,
            step2: i64 = 0,
            edge: i64 = 0,

            pub fn next2(self: *SliceNodeIterator) ?*Node {
                while (!eql(self.start, self.end)) {
                    if (@mod(self.edge, self.step) == 0) {
                        self.edge += 1;
                        const node = self.start;
                        self.start = node.next.?;
                        return node;
                    } else {
                        self.edge += 1;
                        self.start = self.start.next.?;
                        continue;
                    }
                }
                return null;
            }

            pub fn next(self: *SliceNodeIterator) ?*Node {
                if (self.step > 0) {
                    while (self.fringe < self.stop) {
                        if (@mod(self.step2, self.step) == 0) {
                            self.fringe += 1;
                            self.step2 += 1;

                            const node = self.start;
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

                            const node = self.start;
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
                return null;
            }
        };

        /// Update the Item associated with the given index with a new VALUE.
        ///
        /// Supports negative (reverse) indexing.
        /// Returns false if such item wasn't found, but not an error.
        pub fn updateByIndex(self: *Self, index: i64, new_value: VALUE) bool {
            self.rwlock.lock();
            defer self.rwlock.unlock();

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
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

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
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

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

test "SortedMap: simple, iterator" {
    var map = try SortedMap(u128, u128, .set).init(allocatorT);
    defer map.deinit();

    var keys = std.array_list.Managed(u128).init(allocatorT);
    defer keys.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var k: u128 = 0;
    while (k < 32) : (k += 1) {
        try keys.append(k);
    }

    random.shuffle(u128, keys.items);
    for (keys.items) |v| {
        try map.put(v, v);
        try map.put(v, v + 2);
    }

    try expect(map.size == 32);
    var counter: usize = 0;
    {
        var items = try map.iterByKey(map.getItemByIndex(0).?.key);
        defer items.deinit();
        while (items.next()) |item| : (counter += 1) {
            try expect(item.key == item.value - 2);
        }
        try expect(counter == 32);
        items.reset();
        counter = 0;
        while (items.next()) |item| : (counter += 1) {
            try expect(item.key == item.value - 2);
        }
        try expect(counter == 32);
    }

    try map.setSliceByIndex(0, 32, 1, 444);
    try expect(map.size == 32);
    {
        // Recreate iterator after mutation (iterator holds shared lock now).
        var items = map.items();
        defer items.deinit();
        while (items.next()) |item| {
            try expect(item.value == 444);
        }
        // Because the previous iteration has been exhausted, now iter can go backward.
        while (items.prev()) |item| {
            try expect(item.value == 444);
        }
    }

    try map.setSliceByIndex(0, 32 / 2, 1, 333);
    try map.setSliceByIndex(32 / 2, 32, 1, 555);

    // get new iter from the second half
    {
        var items = try map.iterByIndex(@as(i64, 16));
        defer items.deinit();
        while (items.next()) |item| {
            try expect(item.value == 555);
        }
        // reset to the starting point
        items.reset();
        try expect(items.prev().?.value == 555); // this value is idx 16, so still 555!
        // move backward, iterating over the first half of the map
        while (items.prev()) |item| {
            try expect(item.value == 333);
        }

        // PLEASE UNDERSTAND REVERSING THE ITERATOR IN THE PROCESS
        items.reset(); // reset back to the starting key, 16

        // Calling prev() or next() before the iteration hits the right or the left end of the map,
        // know that the lag of one node occurs.
        // Iterator gives you the current node and only then
        // switches either to the prev node or to the next if such node exist!
        try expect(items.prev().?.key == 16); // 16, the starting key
        try expect(items.prev().?.key == 15); // 15 <-
        try expect(items.prev().?.key == 14); // 14 <-
        try expect(items.next().?.key == 13); // 13 <- lagging
        try expect(items.next().?.key == 14); // 14 ->
        try expect(items.next().?.key == 15); // 15 ->
        try expect(items.prev().?.key == 16); // 16 -> lagging
        try expect(items.prev().?.key == 15); // 15 <-
        try expect(items.prev().?.key == 14); // 14 <-
    }
    // ...

    // getSliceByKey and setSliceByKey
    {
        var slice = try map.getSliceByKey(1, 14, 3);
        defer slice.deinit();
        while (slice.next()) |item| {
            try expect(item.value == 333);
        }
    }
    try map.setSliceByKey(1, 14, 3, 888);
    {
        var slice = try map.getSliceByKey(1, 14, 3); // get the new instance of the same slice
        defer slice.deinit();
        while (slice.next()) |item| {
            try expect(item.value == 888);
        }
    }
}

test "SortedMap: basics" {
    var map = try SortedMap(i64, i64, .list).init(allocatorT);
    defer map.deinit();

    var keys = std.array_list.Managed(i64).init(allocatorT);
    defer keys.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var k: i64 = 0;
    while (k < 16) : (k += 1) {
        try keys.append(k);
    }
    random.shuffle(i64, keys.items);
    random.shuffle(i64, keys.items);

    for (keys.items) |v| {
        try map.put(v, v);
    }

    try expect(map.median() == 8);

    const step: i64 = 1;
    var start: i64 = 16 - 12;
    {
        var slice = try map.getSliceByIndex(-12, 16, step);
        defer slice.deinit();
        while (slice.next()) |item| : (start += 1)
            try expect(start == item.key);
    }

    try expect(map.update(6, 66));
    try expect(map.updateByIndex(-1, 1551));

    try expect(map.size == k);
    try expect(map.trailer.width == 0);
    try expect(map.min() == 0);
    try expect(map.getFirst() == 0);

    try expect(map.getItem(11).?.value == map.get(11).?);
    try expect(map.getItemByIndex(11).?.value == map.getByIndex(-5).?);
    try expect(map.getItemByIndex(-11).?.value == map.getByIndex(5).?);

    try expect(map.max() == 1551);
    try expect(map.updateByIndex(-1, 15));
    try expect(map.max() == k - 1);

    try map.setSliceByIndex(0, 5, 1, 99);

    {
        var itemsR = map.itemsReversed();
        defer itemsR.deinit();
        start = 15;
        while (itemsR.prev()) |item| : (start -= 1) {
            if (start < 5)
                try expect(item.value == @as(i64, 99));
        }
    }

    try expect(map.remove(26) == false);
    try expect(map.remove(6) == (map.size == k - 1));
    try expect(map.remove(0) == (map.size == k - 2));
    try expect(!map.contains(0));
    try expect(map.remove(6) == false);

    try expect(map.remove(1) == (map.size == k - 3));
    try expect(!map.contains(1));
    try expect(map.remove(12) == (map.size == k - 4));
    try expect(!map.contains(12));

    try expect(map.remove(3) == (map.size == k - 5));
    try expect(map.remove(14) == (map.size == k - 6));
    try expect(map.getItem(14) == null);

    try map.put(6, 6);
    try expect(map.contains(6));
    try map.put(3, 3);
    try expect(map.contains(3));
    try map.put(14, 14);
    try expect(map.contains(14));

    try expect(map.removeByIndex(9) == true);

    try expect(map.fetchRemove(9).?.key == 9);
    try expect(map.getItemByIndex(9).?.key == map.fetchRemoveByIndex(9).?.key);

    try expect(map.getItemByIndex(0).?.key == map.fetchRemoveByIndex(0).?.key);
    try expect(map.getItemByIndex(0).?.key == map.fetchRemoveByIndex(0).?.key);
    try expect(map.getItemByIndex(0).?.key == map.fetchRemoveByIndex(0).?.key);
    try expect(map.getItemByIndex(0).?.key == map.fetchRemoveByIndex(0).?.key);
    try expect(map.getItemByIndex(0).?.key == map.fetchRemoveByIndex(0).?.key);

    for (keys.items) |v| {
        try map.put(v + 50, v + 50);
    }

    for (keys.items) |v| {
        try map.put(v, v);
    }

    var clone = try map.clone();
    defer clone.deinit();

    for (keys.items) |v| {
        try clone.put(v, v);
    }
    var clone_size = clone.size;
    try expect(true == try clone.removeSliceByIndex(2, 10));
    try expect(clone.size == clone_size - 8);

    for (keys.items) |v| {
        try clone.put(v - 100 * 3, v);
    }

    clone_size = clone.size;
    try expect(true == try clone.removeSliceByIndex(2, 20));
    clone_size -|= 18;
    try expect(clone.size == clone_size);

    try expect(true == try clone.removeSliceByKey(8, 50));
    try expect(true == try clone.removeSliceByIndex(-21, @bitCast(clone.size - 10)));
    try expect(true == try clone.removeSliceByIndex(-21, -10));

    clone_size = clone.size;
    _ = clone.popOrNull();
    _ = clone.pop();
    _ = clone.pop();
    _ = clone.popFirstOrNull();
    _ = clone.popFirst();
    _ = clone.popFirst();
    _ = clone.popFirst();
    _ = clone.popFirstOrNull();
    _ = clone.popFirstOrNull();
    _ = clone.popFirstOrNull();
    try expect(clone.size == clone_size - 9);

    try expect(clone.median() == @as(i64, 63));
    try expect(clone.getFirst() == @as(i64, 63));
    try expect(clone.getLast() == @as(i64, 63));
    try expect(clone.size == 1);

    for (keys.items) |v| {
        try clone.put(v - 100 * 3, v - 100 * 3);
    }

    const query: i64 = -299;
    try expect(clone.get(query) == clone.getByIndex(clone.getItemIndexByKey(query).?));
    try expect(clone.getItemIndexByKey(query - 100) == null);
    try expect(clone.getItemIndexByKey(query * -1) == null);
    try expect(clone.getItemIndexByKey(query - 1) != null);

    try expect(clone.getFirstOrNull().? == @as(i64, -300));
    try expect(clone.getLastOrNull().? == @as(i64, 63));

    try clone.put(std.math.maxInt(i64) - 1, std.math.maxInt(i64));
    try expect(clone.max() == std.math.maxInt(i64));
}

test "SortedMap: floats" {
    var map = try SortedMap(f128, f128, .set).init(allocatorT);
    defer map.deinit();

    var keys = std.array_list.Managed(f128).init(allocatorT);
    defer keys.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var k: f128 = 0;
    while (k < 16) : (k += 1) {
        try keys.append(k);
    }
    random.shuffle(f128, keys.items);
    random.shuffle(f128, keys.items);

    for (keys.items) |key| {
        try map.put(key, key + 100);
    }

    try expect(map.getFirst() == map.min());
    try expect(map.getLast() == map.max());
    try expect(map.median() == @divFloor(k, 2) + 100);

    //  stop value > map length, rolls down to map length
    try expect(true == try map.removeSliceByIndex(@as(i64, 8), @as(i64, 88)));
    try expect(map.max() == @divFloor(k - 1, 2) + 100);
    try expect(map.median() == @divFloor(k, 4) + 100);
    try expect(true == map.remove(@as(f128, 7)));
    try expect(true != map.remove(@as(f128, 7)));

    try expect(true == map.remove(@as(f128, 6)));
    try expect(true == map.remove(@as(f128, 0)));
    try expect(true == map.remove(@as(f128, 5)));
    try expect(true == map.remove(@as(f128, 1)));
    try expect(true == map.remove(@as(f128, 3)));
    try expect(true == map.remove(@as(f128, 4)));

    try expect(map.size == 1);
    try expect((map.median() == map.min()) == (@as(f128, 2 + 100) == map.max()));

    try expect(map.removeByIndex(@as(i64, 0)));
    try expect(!map.removeByIndex(@as(i64, 0)));
    try expect(map.size == 0);
}

test "SortedMap: a string literal as a key" {
    var map = try SortedMap([]const u8, u64, .set).init(allocatorT);
    defer map.deinit();

    const HeLlo = "HeLlo";
    const HeLLo = "HeLLo";
    const HeLLo2 = "HeLLo";
    const hello = "hello";
    const hello2 = "hello";

    try map.put(HeLLo, 0);
    try map.put(HeLlo, 1);
    try map.put(hello, 2);
    try map.put(hello2, 3);
    try expect(map.getFirst() == 0);
    try map.put(HeLLo2, 4);

    try expect(map.getFirst() == 4);

    try map.clearAndFree();

    var message = "Zig is a general-purpose programming language and toolchain for maintaining robust, optimal and reusable software";

    var old_idx: usize = 0;
    var counter: u64 = 0;
    for (message, 0..) |char, idx| {
        if (char == 32) {
            const key = if (message[idx -| 1] == 44) message[old_idx..idx -| 1] else message[old_idx..idx];
            try map.put(key, counter);
            old_idx = idx + 1;
            counter += 1;
        }
    }
    try map.put(message[old_idx..], counter + 1);

    try expect(map.get("Zig") == 0);
    try expect(map.getItemIndexByKey("Zig") == @as(i64, 0));
    try expect(map.contains("Zig"));
    try expect(map.removeByIndex(0));
    try expect(!map.contains("Zig"));
    try expect(sEql(u8, map.getItemByIndex(0).?.key, "a"));
    try expect(map.get("a") == 2);
    try expect(map.getItemIndexByKey("toolchain") == @as(i64, @bitCast(map.size - 1)));

    try expect(try map.removeSliceByIndex(-7, 20)); // will trim the message from the right
    try expect(map.size == 6);
    try expect(map.max() == 5);
    try expect(map.removeByIndex(@bitCast(map.size - 1)));
    try expect(map.size == 5);
    try expect(map.remove("is"));
    try expect(map.size == 4);

    try expect(try map.removeSliceByKey("and", "general-purpose"));
    try expect(map.removeByIndex(@as(i64, 0)));
    try expect(sEql(u8, map.getItemByIndex(0).?.key, "general-purpose"));
    try expect(map.getByIndex(@as(i64, 0)) == 3);
    try expect(map.size == 1);
}

test "SortedMap: split-remove" {
    var map = try SortedMap(usize, usize, .set).init(allocatorT);
    defer map.deinit();

    for (0..16) |i| {
        try map.put(i, i);
    }

    for (8..16) |i| {
        try expect(map.getByIndex(8).? == i % 16);
        try expect(map.removeByIndex(8));
    }
    try expect(map.size == 8);

    for (4..8) |i| {
        try expect(map.getByIndex(4).? == i % 8);
        try expect(map.removeByIndex(4));
    }
    try expect(map.size == 4);

    for (2..4) |i| {
        try expect(map.getByIndex(2).? == i % 4);
        try expect(map.removeByIndex(2));
    }
    try expect(map.size == 2);

    for (1..2) |i| {
        try expect(map.getByIndex(1).? == i % 2);
        try expect(map.removeByIndex(1));
    }
    try expect(map.size == 1);

    try expect(map.getByIndex(0) == 0);
    try expect(map.removeByIndex(0));
    try expect(!map.removeByIndex(0));
    try expect(map.size == 0);
}

// The following two tests were adapted from here
// https://github.com/oven-sh/bun/blob/main/src/StaticHashMap.zig#L623
test "Sorted Map: test compare functions on [32]u8 keys" {
    const prefix = [_]u8{'0'} ** 8 ++ [_]u8{'1'} ** 23;
    const a = prefix ++ [_]u8{0};
    const b = prefix ++ [_]u8{1};

    try expect(SortedMap([]const u8, void, .set).EQL(&a, &a));
    try expect(SortedMap([]const u8, void, .set).EQL(&b, &b));
    try expect(SortedMap([]const u8, void, .set).gT(&b, &a));
    try expect(!SortedMap([]const u8, void, .set).gT(&a, &b));

    try expect(SortedMap([]const u8, void, .set).gT(&[_]u8{'o'} ++ [_]u8{'0'} ** 31, &[_]u8{'i'} ++ [_]u8{'0'} ** 31));
    try expect(SortedMap([]const u8, void, .set).gT(&[_]u8{ 'h', 'o' } ++ [_]u8{'0'} ** 30, &[_]u8{ 'h', 'i' } ++ [_]u8{'0'} ** 30));
}

test "SortedMap: put, get, remove [32]u8 keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocatorA = arena.allocator();
    defer arena.deinit();

    for (0..128) |seed| {
        var keys = std.array_list.Managed([]const u8).init(allocatorA);
        try keys.ensureTotalCapacity(512);
        defer keys.deinit();
        const T = [32]u8;

        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        for (0..512) |_| {
            var key: *T = try allocatorA.create(T);
            for (0..32) |idx| {
                key[idx] = random.intRangeAtMost(u8, 33, 127);
            }
            try keys.append(key);
        }
        random.shuffle([]const u8, keys.items);

        var map = try SortedMap([]const u8, usize, .list).init(allocatorT);
        defer map.deinit();

        for (keys.items, 0..) |key, i| try map.put(key, i);

        try expect(keys.items.len == map.size);

        {
            var itemsIT = map.items();
            defer itemsIT.deinit();
            var key_ = itemsIT.next().?.key;

            while (itemsIT.next()) |item| {
                try expect(std.mem.order(u8, key_, item.key).compare(.lte));
                key_ = item.key;
            }
        }

        for (keys.items, 0..) |key, i| try expect(i == map.get(key).?);
        for (keys.items) |key| try expect(map.remove(key));
    }
}

test "SortedMap: empty map API behavior" {
    var map = try SortedMap(u32, u32, .set).init(allocatorT);
    defer map.deinit();

    try expect(map.size == 0);
    try expect(!map.contains(0));
    try expect(map.get(0) == null);
    try expect(map.getItem(0) == null);
    try expect(map.getByIndex(0) == null);
    try expect(map.getItemByIndex(0) == null);
    try expect(map.getNodePtr(0) == null);
    try expect(map.getNodePtrByIndex(0) == null);

    try expect(map.getFirstOrNull() == null);
    try expect(map.getLastOrNull() == null);
    try expect(map.popOrNull() == null);
    try expect(map.popFirstOrNull() == null);

    try expect(!map.remove(0));
    try expect(!map.removeByIndex(0));
    try expect(map.fetchRemove(0) == null);
    try expect(map.fetchRemoveByIndex(0) == null);

    try expect((try map.removeSliceByKey(0, 1)) == false);
    try expect((try map.removeSliceByIndex(0, 1)) == false);
}

test "SortedMap: set mode clobbers on put()" {
    var map = try SortedMap(u32, u32, .set).init(allocatorT);
    defer map.deinit();

    try map.put(2, 10);
    try expect(map.size == 1);
    try expect(map.get(2).? == 10);

    try map.put(2, 11);
    try expect(map.size == 1);
    try expect(map.get(2).? == 11);

    try expect(map.getItemIndexByKey(2).? == 0);
    try expect(map.update(2, 12));
    try expect(map.get(2).? == 12);
}

test "SortedMap: list mode duplicates are ordered and remove() removes rightmost" {
    var map = try SortedMap(u32, u32, .list).init(allocatorT);
    defer map.deinit();

    try map.put(1, 1);
    try map.put(5, 100);
    try map.put(5, 200);
    try map.put(5, 300);
    try map.put(9, 9);

    try expect(map.size == 5);
    try expect(map.get(5).? == 300);
    try expect(map.getItemIndexByKey(5).? == 3);

    {
        var it = map.items();
        defer it.deinit();
        var seen_dupes: usize = 0;
        const expected_dupe_values = [_]u32{ 100, 200, 300 };
        while (it.next()) |item| {
            if (item.key == 5) {
                try expect(seen_dupes < expected_dupe_values.len);
                try expect(item.value == expected_dupe_values[seen_dupes]);
                seen_dupes += 1;
            }
        }
        try expect(seen_dupes == expected_dupe_values.len);
    }

    const r3 = map.fetchRemove(5).?;
    try expect(r3.key == 5 and r3.value == 300);
    try expect(map.size == 4);
    try expect(map.get(5).? == 200);
    try expect(map.getItemIndexByKey(5).? == 2);

    const r2 = map.fetchRemove(5).?;
    try expect(r2.key == 5 and r2.value == 200);
    try expect(map.size == 3);
    try expect(map.get(5).? == 100);
    try expect(map.getItemIndexByKey(5).? == 1);

    try expect(map.remove(5));
    try expect(map.size == 2);
    try expect(!map.contains(5));
    try expect(map.get(5) == null);
    try expect(map.getItemIndexByKey(5) == null);
    try expect(!map.remove(5));
}

test "SortedMap: removeSliceByKey error paths and basic behavior" {
    var map = try SortedMap(u32, u32, .set).init(allocatorT);
    defer map.deinit();

    for (0..6) |k| try map.put(@intCast(k), @intCast(k));

    try std.testing.expectError(error.StartKeyIsGreaterThanEndKey, map.removeSliceByKey(4, 2));
    try std.testing.expectError(error.MissingStartKey, map.removeSliceByKey(99, 100));
    try std.testing.expectError(error.MissingEndKey, map.removeSliceByKey(2, 99));

    // Remove [1,4): removes keys 1,2,3
    try expect(try map.removeSliceByKey(1, 4));
    try expect(map.size == 3);
    try expect(map.contains(0));
    try expect(!map.contains(1));
    try expect(!map.contains(2));
    try expect(!map.contains(3));
    try expect(map.contains(4));
    try expect(map.contains(5));
}

test "SortedMap: slice argument validation (step/stop)" {
    var map = try SortedMap(u32, u32, .set).init(allocatorT);
    defer map.deinit();

    for (0..10) |k| try map.put(@intCast(k), @intCast(k));

    try std.testing.expectError(error.StepIndexIsZero, map.getSliceByIndex(0, 5, 0));
    try std.testing.expectError(error.StepIndexIsZero, map.setSliceByIndex(0, 5, 0, 123));
    try std.testing.expectError(error.StepIndexIsZero, map.getSliceByKey(0, 5, 0));
    try std.testing.expectError(error.StepIndexIsZero, map.setSliceByKey(0, 5, 0, 123));

    try std.testing.expectError(error.InvalidStopIndex, map.getSliceByIndex(0, 999, 1));
    try std.testing.expectError(error.InvalidStopIndex, map.getSliceByIndex(0, -999, 1));

    var slice = try map.getSliceByIndex(8, 10, 2);
    defer slice.deinit();
    var count: usize = 0;
    while (slice.next()) |item| : (count += 1) {
        // should only hit index 8 (key 8)
        try expect(item.key == 8);
    }
    try expect(count == 1);
}

test "SortedMap: clearRetainingCapacity resets size and allows reuse" {
    var map = try SortedMap(u32, u32, .set).init(allocatorT);
    defer map.deinit();

    for (0..20) |k| try map.put(@intCast(k), @intCast(k + 1000));
    try expect(map.size == 20);
    try expect(map.getFirst() == 1000);

    try map.clearRetainingCapacity();
    try expect(map.size == 0);
    try expect(map.getFirstOrNull() == null);
    try expect(map.getLastOrNull() == null);
    try expect(!map.contains(0));

    for (0..5) |k| try map.put(@intCast(k * 10), @intCast(k));
    try expect(map.size == 5);
    try expect(map.get(0).? == 0);
    try expect(map.get(40).? == 4);
}

test "SortedMap: cloneWithAllocator produces independent map" {
    var map = try SortedMap(u32, u32, .set).init(allocatorT);
    defer map.deinit();

    for (0..12) |k| try map.put(@intCast(k), @intCast(k + 1));
    try expect(map.size == 12);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var clone = try map.cloneWithAllocator(arena.allocator());
    defer clone.deinit();

    try expect(clone.size == map.size);
    try expect(clone.get(0).? == 1);
    try expect(clone.get(11).? == 12);

    // Mutate clone only
    try expect(clone.update(0, 999));
    try expect(clone.remove(5));
    try clone.put(100, 101);

    try expect(map.get(0).? == 1);
    try expect(map.contains(5));
    try expect(!map.contains(100));

    // Mutate original only
    try expect(map.update(11, 777));
    try expect(map.remove(3));

    try expect(clone.get(11).? == 12);
    try expect(clone.contains(3));
}

test "SortedMap: iterators on string keys (order, reset, reversed)" {
    var map = try SortedMap([]const u8, u32, .set).init(allocatorT);
    defer map.deinit();

    // Insert out of order; iteration must be lexicographic.
    try map.put("delta", 4);
    try map.put("alpha", 1);
    try map.put("charlie", 3);
    try map.put("bravo", 2);

    const expected_keys = [_][]const u8{ "alpha", "bravo", "charlie", "delta" };
    const expected_vals = [_]u32{ 1, 2, 3, 4 };

    {
        var it = map.items();
        defer it.deinit();
        var idx: usize = 0;
        while (it.next()) |item| : (idx += 1) {
            try expect(idx < expected_keys.len);
            try expect(sEql(u8, item.key, expected_keys[idx]));
            try expect(item.value == expected_vals[idx]);
        }
        try expect(idx == expected_keys.len);

        it.reset();
        idx = 0;
        while (it.next()) |item| : (idx += 1) {
            try expect(sEql(u8, item.key, expected_keys[idx]));
            try expect(item.value == expected_vals[idx]);
        }
        try expect(idx == expected_keys.len);
    }

    // Reverse iterator: prev() should enumerate from the rightmost key down.
    {
        var rit = map.itemsReversed();
        defer rit.deinit();
        const expected_keys_rev = [_][]const u8{ "delta", "charlie", "bravo", "alpha" };
        const expected_vals_rev = [_]u32{ 4, 3, 2, 1 };
        var idx: usize = 0;
        while (rit.prev()) |item| : (idx += 1) {
            try expect(idx < expected_keys_rev.len);
            try expect(sEql(u8, item.key, expected_keys_rev[idx]));
            try expect(item.value == expected_vals_rev[idx]);
        }
        try expect(idx == expected_keys_rev.len);

        // After reverse exhaustion, next() should go forward from the left edge.
        idx = 0;
        while (rit.next()) |item| : (idx += 1) {
            try expect(sEql(u8, item.key, expected_keys[idx]));
            try expect(item.value == expected_vals[idx]);
        }
        try expect(idx == expected_keys.len);
    }
}

test "SortedMap: iterByKey on string keys (direction switch + missing key)" {
    var map = try SortedMap([]const u8, u32, .set).init(allocatorT);
    defer map.deinit();

    try map.put("a", 0);
    try map.put("b", 1);
    try map.put("c", 2);
    try map.put("d", 3);
    try map.put("e", 4);
    try map.put("f", 5);

    try std.testing.expectError(error.MissingStartKey, map.iterByKey("nope"));

    var it = try map.iterByKey("d");
    defer it.deinit();

    // Walk left a bit, then reverse direction mid-stream to exercise the documented "lag".
    try expect(sEql(u8, it.prev().?.key, "d"));
    try expect(sEql(u8, it.prev().?.key, "c"));
    try expect(sEql(u8, it.prev().?.key, "b"));

    // Reverse before hitting the edge: next() lags by one node (returns "a" first).
    try expect(sEql(u8, it.next().?.key, "a"));
    try expect(sEql(u8, it.next().?.key, "b"));
    try expect(sEql(u8, it.next().?.key, "c"));

    // And reversing again also lags (returns "d" first).
    try expect(sEql(u8, it.prev().?.key, "d"));
    try expect(sEql(u8, it.prev().?.key, "c"));
}

test "SortedMap: iterByIndex on string keys (start point + reset)" {
    var map = try SortedMap([]const u8, u32, .set).init(allocatorT);
    defer map.deinit();

    // Keys will sort as: a, b, c, d, e
    try map.put("d", 4);
    try map.put("b", 2);
    try map.put("e", 5);
    try map.put("a", 1);
    try map.put("c", 3);

    // Start at index 2 -> key "c"
    {
        var it = try map.iterByIndex(2);
        defer it.deinit();
        try expect(sEql(u8, it.next().?.key, "c"));
        try expect(sEql(u8, it.next().?.key, "d"));
        try expect(sEql(u8, it.next().?.key, "e"));
        try expect(it.next() == null);

        it.reset();
        try expect(sEql(u8, it.next().?.key, "c"));
    }

    // Negative start index: -1 is the last item ("e")
    var it2 = try map.iterByIndex(-1);
    defer it2.deinit();
    try expect(sEql(u8, it2.next().?.key, "e"));
}

test "SortedMap: list-mode string duplicates + iterByKey starts at rightmost duplicate" {
    var map = try SortedMap([]const u8, u32, .list).init(allocatorT);
    defer map.deinit();

    try map.put("a", 10);
    try map.put("x", 1);
    try map.put("x", 2);
    try map.put("x", 3);
    try map.put("z", 99);

    try expect(map.get("x").? == 3);
    try expect(map.getItemIndexByKey("x").? == 3);

    var it = try map.iterByKey("x");
    defer it.deinit();
    // Should start at the rightmost "x" (value 3), then proceed to "z".
    const first = it.next().?;
    try expect(sEql(u8, first.key, "x"));
    try expect(first.value == 3);
    try expect(sEql(u8, it.next().?.key, "z"));
}

test "SortedMap: thread-safety: items/get/contains concurrent with structural inserts (.set)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("leak");
    }
    const alloc = gpa.allocator();

    const Map = SortedMap(u64, u64, .set);
    var map = try Map.init(alloc);
    defer map.deinit();

    const AtomicBool = std.atomic.Value(bool);
    const AtomicU32 = std.atomic.Value(u32);

    var start = AtomicBool.init(false);
    var failures = AtomicU32.init(0);
    var finished = AtomicU32.init(0);

    const writer_threads: usize = 4;
    const reader_threads: usize = 4;
    const keys_per_writer: usize = 2000;
    const total_keys: usize = writer_threads * keys_per_writer;
    const stable_keys: usize = 256;
    const stable_base: u64 = 1_000_000_000;

    // Pre-fill a stable key range that writers never touch; readers probe only this range
    // so get()/contains() are comparable without TOCTOU races.
    for (0..stable_keys) |i| {
        const k: u64 = stable_base + @as(u64, @intCast(i));
        try map.put(k, k);
    }

    const Ctx = struct {
        map: *Map,
        start: *AtomicBool,
        failures: *AtomicU32,
        finished: *AtomicU32,
        total_keys: usize,
        stable_base: u64,
        stable_keys: usize,
    };
    var ctx: Ctx = .{
        .map = &map,
        .start = &start,
        .failures = &failures,
        .finished = &finished,
        .total_keys = total_keys,
        .stable_base = stable_base,
        .stable_keys = stable_keys,
    };

    const writer = struct {
        fn run(c: *Ctx, tid: usize) void {
            while (!c.start.load(.acquire)) std.Thread.yield() catch {};

            const base: u64 = @as(u64, tid) * @as(u64, keys_per_writer);
            var i: usize = 0;
            while (i < keys_per_writer) : (i += 1) {
                const k: u64 = base + @as(u64, @intCast(i));
                c.map.put(k, k) catch {
                    _ = c.failures.fetchAdd(1, .monotonic);
                    break;
                };
            }
            _ = c.finished.fetchAdd(1, .release);
        }
    };

    const reader = struct {
        fn run(c: *Ctx, tid: usize) void {
            _ = tid;
            while (!c.start.load(.acquire)) std.Thread.yield() catch {};

            // Readers run while writers are inserting new keys (structural mutation).
            var round: usize = 0;
            while (round < 80) : (round += 1) {
                // Iterator must always terminate and stay sorted.
                {
                    var it = c.map.items();
                    defer it.deinit();
                    var prev_key: u64 = 0;
                    var has_prev = false;
                    var steps: usize = 0;
                    while (it.next()) |item| {
                        if (has_prev and item.key < prev_key) {
                            _ = c.failures.fetchAdd(1, .monotonic);
                            break;
                        }
                        prev_key = item.key;
                        has_prev = true;
                        steps += 1;
                        if (steps > c.total_keys + 8) {
                            // Should never loop/overrun beyond the maximum possible keys.
                            _ = c.failures.fetchAdd(1, .monotonic);
                            break;
                        }
                    }
                }

                // Probe a key and require that get/contains are internally consistent.
                const probe: u64 = c.stable_base + @as(u64, @intCast(round % c.stable_keys));
                const v = c.map.get(probe);
                const has = c.map.contains(probe);
                if ((v != null) != has) {
                    _ = c.failures.fetchAdd(1, .monotonic);
                }

                std.Thread.yield() catch {};
            }

            _ = c.finished.fetchAdd(1, .release);
        }
    };

    var threads: [writer_threads + reader_threads]std.Thread = undefined;
    for (0..writer_threads) |tid| {
        threads[tid] = try std.Thread.spawn(.{}, writer.run, .{ &ctx, tid });
    }
    for (0..reader_threads) |tid| {
        threads[writer_threads + tid] = try std.Thread.spawn(.{}, reader.run, .{ &ctx, tid });
    }

    start.store(true, .release);

    const expected_done: u32 = writer_threads + reader_threads;
    const deadline: i64 = std.time.milliTimestamp() + 1500;
    while (finished.load(.acquire) != expected_done) {
        if (std.time.milliTimestamp() > deadline) @panic("thread-safety test hung (deadlock or infinite loop)");
        std.Thread.yield() catch {};
    }
    for (threads) |t| t.join();

    try expect(failures.load(.acquire) == 0);
    try expect(map.size == total_keys + stable_keys);
    for (0..total_keys) |k| {
        try expect(map.get(@intCast(k)).? == @as(u64, @intCast(k)));
    }
    for (0..stable_keys) |i| {
        const k: u64 = stable_base + @as(u64, @intCast(i));
        try expect(map.get(k).? == k);
        try expect(map.contains(k));
    }
}

test "SortedMap: thread-safety: items/get/contains concurrent with remove+reinsert (.set)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("leak");
    }
    const alloc = gpa.allocator();

    const Map = SortedMap(u64, u64, .set);
    var map = try Map.init(alloc);
    defer map.deinit();

    const churn_keys: usize = 2048;
    const stable_keys: usize = 256;
    const stable_base: u64 = 1_000_000_000;

    // Pre-fill churn range (will be removed/reinserted)
    for (0..churn_keys) |k| try map.put(@intCast(k), @intCast(k));
    // Pre-fill stable range (never touched by writers)
    for (0..stable_keys) |i| {
        const k: u64 = stable_base + @as(u64, @intCast(i));
        try map.put(k, k);
    }
    try expect(map.size == churn_keys + stable_keys);

    const AtomicBool = std.atomic.Value(bool);
    const AtomicU32 = std.atomic.Value(u32);
    var start = AtomicBool.init(false);
    var failures = AtomicU32.init(0);
    var finished = AtomicU32.init(0);

    const writer_threads: usize = 2;
    const reader_threads: usize = 2;

    const Ctx = struct {
        map: *Map,
        start: *AtomicBool,
        failures: *AtomicU32,
        finished: *AtomicU32,
        stable_base: u64,
        stable_keys: usize,
    };
    var ctx: Ctx = .{
        .map = &map,
        .start = &start,
        .failures = &failures,
        .finished = &finished,
        .stable_base = stable_base,
        .stable_keys = stable_keys,
    };

    const writer = struct {
        fn run(c: *Ctx, tid: usize) void {
            while (!c.start.load(.acquire)) std.Thread.yield() catch {};

            // Drive structural churn: remove then reinsert keys repeatedly.
            var x: u64 = (@as(u64, tid) *% 0x9E3779B97F4A7C15) +% 1;
            var i: usize = 0;
            while (i < 30_000) : (i += 1) {
                x = (x *% 6364136223846793005) +% 1442695040888963407;
                const k: u64 = @intCast(@as(usize, @intCast(x)) % churn_keys);

                _ = c.map.fetchRemove(k);
                c.map.put(k, k) catch {
                    _ = c.failures.fetchAdd(1, .monotonic);
                    break;
                };
            }
            _ = c.finished.fetchAdd(1, .release);
        }
    };

    const reader = struct {
        fn run(c: *Ctx, tid: usize) void {
            _ = tid;
            while (!c.start.load(.acquire)) std.Thread.yield() catch {};

            var round: usize = 0;
            while (round < 120) : (round += 1) {
                // Iterator must always terminate and stay sorted while removals/inserts happen.
                {
                    var it = c.map.items();
                    defer it.deinit();
                    var prev_key: u64 = 0;
                    var has_prev = false;
                    var steps: usize = 0;
                    while (it.next()) |item| {
                        if (has_prev and item.key < prev_key) {
                            _ = c.failures.fetchAdd(1, .monotonic);
                            break;
                        }
                        prev_key = item.key;
                        has_prev = true;
                        steps += 1;
                        if (steps > (churn_keys + stable_keys) + 16) {
                            _ = c.failures.fetchAdd(1, .monotonic);
                            break;
                        }
                    }
                }

                // Consistency check between get/contains.
                const probe: u64 = c.stable_base + @as(u64, @intCast(round % c.stable_keys));
                const v = c.map.get(probe);
                const has = c.map.contains(probe);
                if ((v != null) != has) {
                    _ = c.failures.fetchAdd(1, .monotonic);
                }
                std.Thread.yield() catch {};
            }

            _ = c.finished.fetchAdd(1, .release);
        }
    };

    var threads: [writer_threads + reader_threads]std.Thread = undefined;
    for (0..writer_threads) |tid| {
        threads[tid] = try std.Thread.spawn(.{}, writer.run, .{ &ctx, tid });
    }
    for (0..reader_threads) |tid| {
        threads[writer_threads + tid] = try std.Thread.spawn(.{}, reader.run, .{ &ctx, tid });
    }

    start.store(true, .release);

    const expected_done: u32 = writer_threads + reader_threads;
    const deadline: i64 = std.time.milliTimestamp() + 1500;
    while (finished.load(.acquire) != expected_done) {
        if (std.time.milliTimestamp() > deadline) @panic("thread-safety test hung (deadlock or infinite loop)");
        std.Thread.yield() catch {};
    }
    for (threads) |t| t.join();

    try expect(failures.load(.acquire) == 0);
    try expect(map.size == churn_keys + stable_keys);
    for (0..churn_keys) |k| {
        try expect(map.get(@intCast(k)).? == @as(u64, @intCast(k)));
        try expect(map.contains(@intCast(k)));
    }
    for (0..stable_keys) |i| {
        const k: u64 = stable_base + @as(u64, @intCast(i));
        try expect(map.get(k).? == k);
        try expect(map.contains(k));
    }
}

test "SortedMap: thread-safety: bug-revealing readers vs structural mutations + snapshot invariant" {
    // This test is intentionally adversarial ("break this"): it runs readers that
    // obtain iterators/pointers while writers concurrently mutate the structure.
    // It periodically takes a consistent snapshot under ONE shared lock and asserts:
    // - iteration terminates (no cycles)
    // - keys are non-decreasing
    // - bottom-level node count matches `size`
    //
    // If the public read APIs are truly safe under concurrent mutation, this should pass.
    // If not, it should fail/crash/hang (guarded by an internal deadline).

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("leak");
    }
    const alloc = gpa.allocator();

    const Map = SortedMap(u64, u64, .set);
    var map = try Map.init(alloc);
    defer map.deinit();

    const AtomicBool = std.atomic.Value(bool);
    const AtomicU32 = std.atomic.Value(u32);

    var start = AtomicBool.init(false);
    var stop = AtomicBool.init(false);
    var failures = AtomicU32.init(0);
    var writers_done = AtomicU32.init(0);
    var readers_done = AtomicU32.init(0);

    const stable_base: u64 = 1_000_000_000;
    const stable_keys: usize = 128;
    for (0..stable_keys) |i| {
        const k: u64 = stable_base + @as(u64, @intCast(i));
        try map.put(k, k);
    }

    const writer_threads: usize = 4;
    const reader_threads: usize = 4;
    const ops_per_writer: usize = 20_000;

    const Ctx = struct {
        map: *Map,
        start: *AtomicBool,
        stop: *AtomicBool,
        failures: *AtomicU32,
        writers_done: *AtomicU32,
        readers_done: *AtomicU32,
    };
    var ctx: Ctx = .{
        .map = &map,
        .start = &start,
        .stop = &stop,
        .failures = &failures,
        .writers_done = &writers_done,
        .readers_done = &readers_done,
    };

    const snapshot = struct {
        fn check(c: *Ctx) void {
            c.map.rwlock.lockShared();
            defer c.map.rwlock.unlockShared();

            const size_snapshot: usize = c.map.size;

            // Descend to bottom-level header.
            var node: *Map.Node = c.map.header;
            while (node.parent != null) node = node.parent.?;

            var cur: *Map.Node = node.next.?;
            var count: usize = 0;
            var prev_key: u64 = 0;
            var has_prev = false;

            // Absolute guard against cycles even if size is corrupted.
            const hard_cap: usize = size_snapshot + 64;
            while (!eql(cur.item.key, Map.MAXSIZE)) {
                count += 1;
                if (count > hard_cap) {
                    _ = c.failures.fetchAdd(1, .monotonic);
                    return;
                }
                if (has_prev and cur.item.key < prev_key) {
                    _ = c.failures.fetchAdd(1, .monotonic);
                    return;
                }
                prev_key = cur.item.key;
                has_prev = true;
                cur = cur.next.?;
            }

            if (count != size_snapshot) {
                _ = c.failures.fetchAdd(1, .monotonic);
                return;
            }
        }
    };

    const writer = struct {
        fn run(c: *Ctx, tid: usize) void {
            while (!c.start.load(.acquire)) std.Thread.yield() catch {};

            // Insert keys close to (but below) the stable range, to maximize interference
            // with readers that start iterating near stable_base.
            const base: u64 = (stable_base - 1) - (@as(u64, tid) * 10_000_000);

            var i: usize = 0;
            while (i < ops_per_writer and !c.stop.load(.acquire)) : (i += 1) {
                const key: u64 = base - @as(u64, @intCast(i));

                // Structural insert (new node, widths, maybe new layer).
                c.map.put(key, key) catch {
                    _ = c.failures.fetchAdd(1, .monotonic);
                    break;
                };

                // Structural delete of a known key (churn).
                if ((i & 0x3f) == 0) {
                    _ = c.map.fetchRemove(key);
                }

                // Structural slice deletes (exercise both variants).
                if (i > 64 and (i & 0x1ff) == 0) {
                    // Both keys are expected to exist often (contiguous inserts),
                    // but concurrent churn may still make this fail; ignore expected errors.
                    const start_key: u64 = base - @as(u64, @intCast(i));
                    const stop_key: u64 = start_key + 20;
                    _ = c.map.removeSliceByKey(start_key, stop_key) catch {};
                }
                // Avoid deleting the stable key range early in the run: only do index-based
                // slice removals after enough non-stable keys exist below `stable_base`.
                if (i > 256 and (i & 0x3ff) == 0) {
                    _ = c.map.removeSliceByIndex(0, 10) catch {};
                }
            }

            _ = c.writers_done.fetchAdd(1, .release);
        }
    };

    const reader = struct {
        fn run(c: *Ctx, tid: usize) void {
            while (!c.start.load(.acquire)) std.Thread.yield() catch {};

            var round: usize = 0;
            while (!c.stop.load(.acquire)) : (round += 1) {
                // 1) items(): now holds lockShared for its lifetime, so keep it short and deinit.
                {
                    var it = c.map.items();
                    defer it.deinit();
                    var prev_key: u64 = 0;
                    var has_prev = false;
                    var steps: usize = 0;
                    while (steps < 256) : (steps += 1) {
                        const item = it.next() orelse break;
                        if (has_prev and item.key < prev_key) {
                            _ = c.failures.fetchAdd(1, .monotonic);
                            break;
                        }
                        prev_key = item.key;
                        has_prev = true;
                    }
                }

                // 2) iterByKey(): also holds lockShared; scope it and deinit before any other locking.
                {
                    const start_key: u64 = stable_base + @as(u64, @intCast(tid % stable_keys));
                    var it2 = c.map.iterByKey(start_key) catch {
                        // stable keys should exist; treat as a failure if missing
                        _ = c.failures.fetchAdd(1, .monotonic);
                        continue;
                    };
                    defer it2.deinit();

                    var j: usize = 0;
                    var last: u64 = 0;
                    var has_last = false;
                    while (j < 32) : (j += 1) {
                        const next_item = it2.next() orelse break;
                        if (has_last and next_item.key < last) {
                            _ = c.failures.fetchAdd(1, .monotonic);
                            break;
                        }
                        last = next_item.key;
                        has_last = true;
                    }
                }

                // 3) getNodePtr() is documented as requiring external lockShared().
                c.map.rwlock.lockShared();
                const ptr = c.map.getNodePtr(stable_base);
                if (ptr == null or ptr.?.item.key != stable_base) {
                    _ = c.failures.fetchAdd(1, .monotonic);
                }
                c.map.rwlock.unlockShared();

                // Avoid starving writers completely.
                if ((round & 0x3f) == 0) std.Thread.yield() catch {};
            }

            _ = c.readers_done.fetchAdd(1, .release);
        }
    };

    var threads: [writer_threads + reader_threads]std.Thread = undefined;
    for (0..writer_threads) |tid| {
        threads[tid] = try std.Thread.spawn(.{}, writer.run, .{ &ctx, tid });
    }
    for (0..reader_threads) |tid| {
        threads[writer_threads + tid] = try std.Thread.spawn(.{}, reader.run, .{ &ctx, tid });
    }

    start.store(true, .release);

    const deadline: i64 = std.time.milliTimestamp() + 1500;
    var snapshots_taken: usize = 0;
    while (writers_done.load(.acquire) != writer_threads) {
        if (std.time.milliTimestamp() > deadline) @panic("bug-revealing test hung while writers running");
        if (snapshots_taken < 32) {
            snapshot.check(&ctx);
            snapshots_taken += 1;
        }
        std.Thread.yield() catch {};
    }

    stop.store(true, .release);

    const deadline2: i64 = std.time.milliTimestamp() + 1500;
    while (readers_done.load(.acquire) != reader_threads) {
        if (std.time.milliTimestamp() > deadline2) @panic("bug-revealing test hung while stopping readers");
        std.Thread.yield() catch {};
    }

    for (threads) |t| t.join();

    // Final snapshot under shared lock to catch persistent corruption.
    snapshot.check(&ctx);

    try expect(failures.load(.acquire) == 0);
}
