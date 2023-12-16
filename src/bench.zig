const std = @import("std");
const SortedMap = @import("sorted_map.zig").SortedMap;
const stdout = std.io.getStdOut().writer();
const assert = std.debug.assert;
const sEql = std.mem.eql;

pub fn benchSTR(N: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("memory leak ...");
    };
    const allocatorG = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocatorA = arena.allocator();
    defer arena.deinit();

    const SL2 = SortedMap([]const u8, []const u8, .set);
    var sL: SL2 = .{};

    try sL.init(allocatorG);
    defer sL.deinit();

    var keys = std.ArrayList([]const u8).init(allocatorA);
    defer keys.deinit();

    var prng = std.rand.DefaultPrng.init(std.math.absCast(std.time.timestamp()));
    const random = prng.random();

    const T = [8]u8;
    for (0..N) |_| {
        var key: *T = try allocatorA.create(T);
        for (0..8) |idx| {
            key[idx] = random.intRangeAtMost(u8, 33, 127);
        }
        try keys.append(key);
    }
    random.shuffle([]const u8, keys.items);

    // Cosmetic function, number formatting
    var buffer: [16]u8 = undefined;
    var len = pretty(N, &buffer, allocatorA);

    // Print benchmark header
    try stdout.print("\n{s: >38}|", .{"SortedMap STR BENCHMARK"});
    try stdout.print("\n{s: >24} ops:each test|\n", .{buffer[0..len]});
    try stdout.print("\n|{s: <13}|{s: >11}|{s: >11}|\n", .{ "name", "Tp Mops:sec", "Rt :sec" });
    try stdout.print(" {s:=>37}\n", .{""});

    // ------------------ READ HEAVY -----------------//
    // ---- read 98, insert 1, remove 1, update 0 --- //

    // Initial input for the test because we start with read.
    for (keys.items[0..98]) |key| {
        try sL.put(key, key);
    }

    // Start the timer
    var time: u128 = 0;
    var aggregate: u128 = 0;
    var timer = try std.time.Timer.start();
    var start = timer.lap();

    // Cycle of 100 operations each
    for (0..N / 100) |i| {

        // Read the slice of 98 keys
        for (keys.items[i .. i + 98]) |key| {
            // assert(sL.get(key) == key);
            assert(sEql(u8, sL.get(key).?, key));
        }

        // Insert 1 new
        try sL.put(keys.items[i + 98], keys.items[i + 98]);

        // Remove 1
        assert(sL.remove(keys.items[i]));
    }
    var end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("RH", N, time);

    // Clear the sL
    assert(sL.size == 98);
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // ------------------ EXCHANGE -------------------//
    // -- read 10, insert 40, remove 40, update 10 -- //

    // Re-shuffle the keys
    random.shuffle([]const u8, keys.items);

    // Initial input for the test, 10 keys, because we start with read
    for (keys.items[0..10]) |key| {
        try sL.put(key, key);
    }

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    // Cycle of 100 operations each
    var k: usize = 0; // helper coefficient to get the keys rotating
    for (0..N / 100) |i| {

        // Read 10
        for (keys.items[i + k .. i + k + 10]) |key| {
            // assert(sL.get(key) == key);
            assert(sEql(u8, sL.get(key).?, key));
        }

        // Insert 40 new
        for (keys.items[i + k + 10 .. i + k + 50]) |key| {
            try sL.put(key, key);
        }

        // Remove 40
        for (keys.items[i + k .. i + k + 40]) |key| {
            assert(sL.remove(key));
        }

        // Update 10
        for (keys.items[i + k + 40 .. i + k + 50]) |key| {
            assert(sL.update(key, key));
        }

        k += 39;
    }
    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("EX", N, time);

    // Clear the sL
    assert(sL.size == 10);
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // --------------- EXCHANGE HEAVY --------------//
    // -- read 1, insert 98, remove 98, update 1 -- //

    // Re-shuffle the keys
    random.shuffle([]const u8, keys.items);

    // Initial input for the test, 10 keys, because we start with read
    for (keys.items[0..1]) |key| {
        try sL.put(key, key);
    }

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    // Cycle of 198 operations each
    k = 0; // helper coefficient to get the keys rotating
    for (0..N / 198) |i| {

        // Read 1
        for (keys.items[i + k .. i + k + 1]) |key| {
            // assert(sL.get(key) == key);
            assert(sEql(u8, sL.get(key).?, key));
        }

        // Insert 98 new
        for (keys.items[i + k + 1 .. i + k + 99]) |key| {
            try sL.put(key, key);
        }

        // Remove 98
        for (keys.items[i + k .. i + k + 98]) |key| {
            assert(sL.remove(key));
        }

        // Update 1
        for (keys.items[i + k + 98 .. i + k + 99]) |key| {
            assert(sL.update(key, key));
        }

        k += 97;
    }
    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("EXH", N, time);

    // Clear the sL
    assert(sL.size == 1);
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // ---------------- RAPID GROW -----------------//
    // -- read 5, insert 80, remove 5, update 10 -- //

    // Re-shuffle the keys
    random.shuffle([]const u8, keys.items);

    // Initial input for the test, 5 keys, because we start with read
    for (keys.items[0..5]) |key| {
        try sL.put(key, key);
    }

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    // Cycle of 100 operations each
    k = 0; // helper coefficient to get the keys rotating
    for (0..N / 100) |i| {

        // Read 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            // assert(sL.get(key) == key);
            assert(sEql(u8, sL.get(key).?, key));
        }

        // Insert 80 new
        for (keys.items[i + k + 5 .. i + k + 85]) |key| {
            try sL.put(key, key);
        }

        // Remove 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            assert(sL.remove(key));
        }

        // Update 10
        for (keys.items[i + k + 5 .. i + k + 15]) |key| {
            assert(sL.update(key, key));
        }

        k += 79;
    }
    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("RG", N, time);
    arenaCacheSizeQuery(&sL.cache);

    // ---------------- CLONING -----------------//
    // ------ obtain a clone of the graph ------ //

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    var clone = try sL.clone();
    defer clone.deinit();

    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("CLONE", clone.size, time);

    // Aggregate stats
    try writeStamps("aggregate", N * 4 + clone.size, aggregate);
    try stdout.print("\n", .{});
}

pub fn benchU64(N: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("memory leak ...");
    };
    const allocatorG = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocatorA = arena.allocator();
    defer arena.deinit();

    const SL = SortedMap(u64, u64, .set);
    var sL: SL = .{};

    try sL.init(allocatorG);
    defer sL.deinit();

    // try sL.ensureTotalCapacity(N);

    // Get unique keys and shuffle them
    var keys = std.ArrayList(u64).init(allocatorA);
    defer keys.deinit();

    var prng = std.rand.DefaultPrng.init(std.math.absCast(std.time.timestamp()));
    const random = prng.random();

    for (0..N) |key| {
        try keys.append(key);
    }
    random.shuffle(u64, keys.items);

    // Cosmetic function, number formatting
    var buffer: [16]u8 = undefined;
    var len = pretty(N, &buffer, allocatorA);

    // Print benchmark header
    try stdout.print("\n{s: >38}|", .{"SortedMap u64 BENCHMARK"});
    try stdout.print("\n{s: >24} ops:each test|\n", .{buffer[0..len]});
    try stdout.print("\n|{s: <13}|{s: >11}|{s: >11}|\n", .{ "name", "Tp Mops:sec", "Rt :sec" });
    try stdout.print(" {s:=>37}\n", .{""});

    // ------------------ READ HEAVY -----------------//
    // ---- read 98, insert 1, remove 1, update 0 --- //

    // Initial input for the test because we start with read.
    for (keys.items[0..98]) |key| {
        try sL.put(key, key);
    }

    // Start the timer
    var time: u128 = 0;
    var aggregate: u128 = 0;
    var timer = try std.time.Timer.start();
    var start = timer.lap();

    // Cycle of 100 operations each
    for (0..N / 100) |i| {

        // Read the slice of 98 keys
        for (keys.items[i .. i + 98]) |key| {
            assert(sL.get(key) == key);
        }

        // Insert 1 new
        try sL.put(keys.items[i + 98], keys.items[i + 98]);

        // Remove 1
        assert(sL.remove(keys.items[i]));
    }
    var end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("RH", N, time);

    // Clear the sL
    assert(sL.size == 98);
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // ------------------ EXCHANGE -------------------//
    // -- read 10, insert 40, remove 40, update 10 -- //

    // Re-shuffle the keys
    random.shuffle(u64, keys.items);

    // Initial input for the test, 10 keys, because we start with read
    for (keys.items[0..10]) |key| {
        try sL.put(key, key);
    }

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    // Cycle of 100 operations each
    var k: usize = 0; // helper coefficient to get the keys rotating
    for (0..N / 100) |i| {

        // Read 10
        for (keys.items[i + k .. i + k + 10]) |key| {
            assert(sL.get(key) == key);
        }

        // Insert 40 new
        for (keys.items[i + k + 10 .. i + k + 50]) |key| {
            try sL.put(key, key);
        }

        // Remove 40
        for (keys.items[i + k .. i + k + 40]) |key| {
            assert(sL.remove(key));
        }

        // Update 10
        for (keys.items[i + k + 40 .. i + k + 50]) |key| {
            assert(sL.update(key, key));
        }

        k += 39;
    }
    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("EX", N, time);

    // Clear the sL
    assert(sL.size == 10);
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // --------------- EXCHANGE HEAVY --------------//
    // -- read 1, insert 98, remove 98, update 1 -- //

    // Re-shuffle the keys
    random.shuffle(u64, keys.items);

    // Initial input for the test, 1 key, because we start with read
    for (keys.items[0..1]) |key| {
        try sL.put(key, key);
    }

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    // Cycle of 198 operations each
    k = 0; // helper coefficient to get the keys rotating
    for (0..N / 198) |i| {

        // Read 1
        for (keys.items[i + k .. i + k + 1]) |key| {
            assert(sL.get(key) == key);
        }

        // Insert 98 new
        for (keys.items[i + k + 1 .. i + k + 99]) |key| {
            try sL.put(key, key);
        }

        // Remove 98
        for (keys.items[i + k .. i + k + 98]) |key| {
            assert(sL.remove(key));
        }

        // Update 1
        for (keys.items[i + k + 98 .. i + k + 99]) |key| {
            assert(sL.update(key, key));
        }

        k += 97;
    }
    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("EXH", N, time);

    // Clear the sL
    assert(sL.size == 1);
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // ---------------- RAPID GROW -----------------//
    // -- read 5, insert 80, remove 5, update 10 -- //

    // Re-shuffle the keys
    random.shuffle(u64, keys.items);

    // Initial input for the test, 5 keys, because we start with read
    for (keys.items[0..5]) |key| {
        try sL.put(key, key);
    }

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    // Cycle of 100 operations each
    k = 0; // helper coefficient to get the keys rotating
    for (0..N / 100) |i| {

        // Read 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            assert(sL.get(key) == key);
        }

        // Insert 80 new
        for (keys.items[i + k + 5 .. i + k + 85]) |key| {
            try sL.put(key, key);
        }

        // Remove 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            assert(sL.remove(key));
        }

        // Update 10
        for (keys.items[i + k + 5 .. i + k + 15]) |key| {
            assert(sL.update(key, key));
        }

        k += 79;
    }
    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("RG", N, time);
    arenaCacheSizeQuery(&sL.cache);

    // ---------------- CLONING -----------------//
    // ------ obtain a clone of the graph ------ //

    // Clear the time, re-start the timer
    time = 0;
    timer = try std.time.Timer.start();
    start = timer.lap();

    var clone = try sL.clone();
    defer clone.deinit();

    end = timer.read();
    time += end -| start;
    aggregate += time;

    // Print stats //
    // Test' individual stats
    try writeStamps("CLONE", clone.size, time);

    // Aggregate stats
    try writeStamps("aggregate", N * 4 + clone.size, aggregate);
    try stdout.print("\n", .{});
}

/// Print to the screen the size of the current memory being used by the arena allocator
/// along with the cache's len.
fn arenaCacheSizeQuery(cache: anytype) void {
    std.debug.print("arena size: {}, cache len: {}\n\n", .{
        cache.arena.queryCapacity(),
        cache.free.len,
    });
}

fn toSeconds(t: u128) f64 {
    return @as(f64, @floatFromInt(t)) / 1_000_000_000;
}

fn throughput(N: usize, time: u128) f64 {
    return @as(f64, @floatFromInt(N)) / toSeconds(time) / 1_000_000;
}

fn writeStamps(test_name: []const u8, N: usize, time: u128) !void {
    const throughput_ = throughput(N, time);
    const runtime = toSeconds(time);

    try stdout.print("|{s: <13}|{d: >11.2}|{d: >11.6}|\n", .{ test_name, throughput_, runtime });
}

fn pretty(N: usize, buffer: []u8, alloc: std.mem.Allocator) usize {
    var stack = std.ArrayList(u8).init(alloc);
    defer stack.deinit();

    var N_ = N;
    var counter: u8 = 0;

    while (N_ > 0) : (counter += 1) {
        var rem: u8 = @intCast(N_ % 10);
        if (counter == 3) {
            stack.append(0x5F) catch unreachable;
            counter = 0;
        }
        stack.append(rem + 48) catch unreachable;
        N_ = @divFloor(N_, 10);
    }

    var j: usize = 0;
    var k: usize = stack.items.len;

    while (k > 0) : (j += 1) {
        k -= 1;
        buffer[j] = stack.items[k];
    }

    return stack.items.len;
}

const HELP =
    \\skipList benchmark HELP menu
    \\
    \\command prompt example: 
    \\      zig build bench -- [option]
    \\
    \\info:
    \\      options are optional
    \\      default test runs on 1_000 of operations
    \\      with unsigned integers as keys
    \\
    \\Options:
    \\      [u64], unsigned integer, 
    \\      the number of operations you are interested benchmark is to run
    \\
    \\      [-str], string,
    \\      benchmark string literals as keys
    \\
    \\      [-h], string,
    \\      display this menu
    \\
;

pub fn main() !void {
    // get args
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(buffer[0..]);
    const args = try std.process.argsAlloc(fixed.allocator());
    defer std.process.argsFree(fixed.allocator(), args);

    // default number of operations
    var N: usize = 100_000;
    var string: bool = false;

    var i: usize = 1;
    if (args.len > 3) {
        std.debug.print(HELP ++ "\n", .{});
        return;
    }

    while (i < args.len) : (i += 1) {
        var integer: bool = true;

        for (args[i]) |char| {
            if (char < 48 or char > 57 and char != 95) integer = false;
        }

        if (integer) {
            // TODO give warning if N > 1B, y - n ?
            N = try std.fmt.parseUnsigned(usize, args[i], 10);
            // break;
        } else if (std.mem.eql(u8, args[i], "-h")) {
            std.debug.print(HELP ++ "\n", .{});
            return;
        } else if (std.mem.eql(u8, args[i], "-str")) {
            string = true;
        } else {
            std.debug.print(HELP ++ "\n", .{});
            return;
        }
    }

    if (string) {
        try benchSTR(N);
    } else try benchU64(N);
}
