const std = @import("std");
const SortedMap = @import("sorted_map.zig").SortedMap;
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;
const assert = std.debug.assert;
const sEql = std.mem.eql;

pub fn benchSTR(N: usize, steady_state: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("memory leak ...");
    };
    const allocatorG = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocatorA = arena.allocator();
    defer arena.deinit();

    var sL = try SortedMap([]const u8, []const u8, .set).init(allocatorG);
    defer sL.deinit();

    var keys = std.array_list.Managed([]const u8).init(allocatorA);
    defer keys.deinit();

    var prng = std.Random.DefaultPrng.init(@abs(std.time.timestamp()));
    const random = prng.random();

    const cycles_rh: usize = N / 100;
    const cycles_ex: usize = N / 100;
    const cycles_exh: usize = N / 198;

    const use_steady: bool = steady_state != 0;
    const rh_steady: usize = if (use_steady) @max(steady_state, 98) else 98;
    const ex_steady: usize = if (use_steady) @max(steady_state, 40) else 10;
    const exh_steady: usize = if (use_steady) @max(steady_state, 98) else 1;

    // Ensure we have enough unique keys for all workloads (including sliding-window
    // steady-state variants).
    const key_count: usize = @max(
        N,
        @max(
            rh_steady + cycles_rh + 128,
            @max(ex_steady + (cycles_ex * 40) + 128, exh_steady + (cycles_exh * 98) + 128),
        ),
    );

    const T = [8]u8;
    for (0..key_count) |_| {
        var key: *T = try allocatorA.create(T);
        for (0..8) |idx| {
            key[idx] = random.intRangeAtMost(u8, 33, 127);
        }
        try keys.append(key);
    }
    defer allocatorA.free(keys.items);
    random.shuffle([]const u8, keys.items);

    // Cosmetic function, number formatting
    var buffer: [16]u8 = undefined;
    const len = pretty(N, &buffer, allocatorA);

    // Print benchmark header
    try stdout.print("\n{s: >38}|", .{"SortedMap STR BENCHMARK"});
    try stdout.print("\n{s: >24} ops:each test|\n", .{buffer[0..len]});
    try stdout.print("\n|{s: <13}|{s: >11}|{s: >11}|\n", .{ "name", "Tp Mops:sec", "Rt :sec" });
    try stdout.print(" {s:=>37}\n", .{""});
    try stdout.flush();

    // ------------------ READ HEAVY -----------------//
    // ---- read 98, insert 1, remove 1, update 0 --- //

    // Initial input for the test because we start with read.
    for (keys.items[0..rh_steady]) |key| {
        try sL.put(key, key);
    }

    // Start the timer
    var time: u128 = 0;
    var timer = try std.time.Timer.start();

    var checksum_rh: u64 = 0;
    // Cycle of 100 operations each
    var remove_idx: usize = 0;
    var insert_idx: usize = rh_steady;
    for (0..cycles_rh) |_| {

        // Read the slice of 98 keys
        for (keys.items[remove_idx .. remove_idx + 98]) |key| {
            const v = sL.get(key) orelse unreachable;
            checksum_rh +%= @as(u64, v[0]);
        }

        // Insert 1 new
        const in_k = keys.items[insert_idx];
        try sL.put(in_k, in_k);

        // Remove 1
        if (!sL.remove(keys.items[remove_idx])) @panic("bench invariant failed: RH remove");
        remove_idx += 1;
        insert_idx += 1;
    }
    time = timer.read();
    std.mem.doNotOptimizeAway(checksum_rh);
    const ops_rh: usize = (N / 100) * 100;

    // Print stats //
    // Test' individual stats
    try writeStamps("RH", ops_rh, time);

    // Clear the sL
    if (sL.size != rh_steady) @panic("bench invariant failed: RH size");
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // ------------------ EXCHANGE -------------------//
    // -- read 10, insert 40, remove 40, update 10 -- //

    // Re-shuffle the keys
    random.shuffle([]const u8, keys.items);

    var checksum_ex: u64 = 0;
    if (!use_steady) {
        // Original small working-set benchmark.
        for (keys.items[0..10]) |key| {
            try sL.put(key, key);
        }

        timer = try std.time.Timer.start();

        var k: usize = 0; // helper coefficient to get the keys rotating
        for (0..N / 100) |i| {
            for (keys.items[i + k .. i + k + 10]) |key| {
                const v = sL.get(key) orelse unreachable;
                checksum_ex +%= @as(u64, v[0]);
            }
            for (keys.items[i + k + 10 .. i + k + 50]) |key| {
                try sL.put(key, key);
            }
            for (keys.items[i + k .. i + k + 40]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EX remove");
            }
            for (keys.items[i + k + 40 .. i + k + 50]) |key| {
                if (!sL.update(key, key)) @panic("bench invariant failed: EX update");
            }
            k += 39;
        }
        time = timer.read();
    } else {
        // Steady-state variant: keep a constant resident set of `ex_steady` items by
        // removing 40 from the front of a sliding window and inserting 40 at the back.
        for (keys.items[0..ex_steady]) |key| {
            try sL.put(key, key);
        }

        timer = try std.time.Timer.start();

        var resident_start: usize = 0;
        for (0..cycles_ex) |_| {
            // Read 10 (existing keys)
            for (keys.items[resident_start .. resident_start + 10]) |key| {
                const v = sL.get(key) orelse unreachable;
                checksum_ex +%= @as(u64, v[0]);
            }

            // Insert 40 new at the end of the window
            for (keys.items[resident_start + ex_steady .. resident_start + ex_steady + 40]) |key| {
                try sL.put(key, key);
            }

            // Remove 40 from the front of the window
            for (keys.items[resident_start .. resident_start + 40]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EX remove");
            }

            // Update 10 that are guaranteed to remain (the last 10 inserted)
            for (keys.items[resident_start + ex_steady + 30 .. resident_start + ex_steady + 40]) |key| {
                if (!sL.update(key, key)) @panic("bench invariant failed: EX update");
            }

            resident_start += 40;
        }
        time = timer.read();
        if (sL.size != ex_steady) @panic("bench invariant failed: EX size");
    }
    std.mem.doNotOptimizeAway(checksum_ex);
    const ops_ex: usize = (N / 100) * 100;

    // Print stats //
    // Test' individual stats
    try writeStamps("EX", ops_ex, time);

    // Clear the sL
    if (sL.size != 10 and !use_steady) @panic("bench invariant failed: EX size");
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // --------------- EXCHANGE HEAVY --------------//
    // -- read 1, insert 98, remove 98, update 1 -- //

    // Re-shuffle the keys
    random.shuffle([]const u8, keys.items);

    var checksum_exh: u64 = 0;
    if (!use_steady) {
        // Original small working-set benchmark.
        for (keys.items[0..1]) |key| {
            try sL.put(key, key);
        }

        timer = try std.time.Timer.start();

        var k: usize = 0; // helper coefficient to get the keys rotating
        for (0..N / 198) |i| {
            for (keys.items[i + k .. i + k + 1]) |key| {
                const v = sL.get(key) orelse unreachable;
                checksum_exh +%= @as(u64, v[0]);
            }
            for (keys.items[i + k + 1 .. i + k + 99]) |key| {
                try sL.put(key, key);
            }
            for (keys.items[i + k .. i + k + 98]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EXH remove");
            }
            for (keys.items[i + k + 98 .. i + k + 99]) |key| {
                if (!sL.update(key, key)) @panic("bench invariant failed: EXH update");
            }
            k += 97;
        }
        time = timer.read();
    } else {
        // Steady-state variant: keep a constant resident set of `exh_steady` items by
        // removing 98 from the front of a sliding window and inserting 98 at the back.
        for (keys.items[0..exh_steady]) |key| {
            try sL.put(key, key);
        }

        timer = try std.time.Timer.start();

        var resident_start: usize = 0;
        for (0..cycles_exh) |_| {
            const key0 = keys.items[resident_start];
            const v = sL.get(key0) orelse unreachable;
            checksum_exh +%= @as(u64, v[0]);

            for (keys.items[resident_start + exh_steady .. resident_start + exh_steady + 98]) |key| {
                try sL.put(key, key);
            }
            for (keys.items[resident_start .. resident_start + 98]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EXH remove");
            }
            // Update 1 that is guaranteed to remain (last inserted)
            const up = keys.items[resident_start + exh_steady + 97];
            if (!sL.update(up, up)) @panic("bench invariant failed: EXH update");

            resident_start += 98;
        }
        time = timer.read();
        if (sL.size != exh_steady) @panic("bench invariant failed: EXH size");
    }
    std.mem.doNotOptimizeAway(checksum_exh);
    const ops_exh: usize = (N / 198) * 198;

    // Print stats //
    // Test' individual stats
    try writeStamps("EXH", ops_exh, time);

    // Clear the sL
    if (sL.size != 1 and !use_steady) @panic("bench invariant failed: EXH size");
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
    timer = try std.time.Timer.start();

    // Cycle of 100 operations each
    var k: usize = 0; // helper coefficient to get the keys rotating
    var checksum_rg: u64 = 0;
    for (0..N / 100) |i| {

        // Read 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            const v = sL.get(key) orelse unreachable;
            checksum_rg +%= @as(u64, v[0]);
        }

        // Insert 80 new
        for (keys.items[i + k + 5 .. i + k + 85]) |key| {
            try sL.put(key, key);
        }

        // Remove 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            if (!sL.remove(key)) @panic("bench invariant failed: RG remove");
        }

        // Update 10
        for (keys.items[i + k + 5 .. i + k + 15]) |key| {
            if (!sL.update(key, key)) @panic("bench invariant failed: RG update");
        }

        k += 79;
    }
    time = timer.read();
    std.mem.doNotOptimizeAway(checksum_rg);
    const ops_rg: usize = (N / 100) * 100;

    // Print stats //
    // Test' individual stats
    try writeStamps("RG", ops_rg, time);
    arenaCacheSizeQuery(&sL.cache);

    // ---------------- CLONING -----------------//
    // ------ obtain a clone of the graph ------ //

    // Clear the time, re-start the timer
    timer = try std.time.Timer.start();

    var clone = try sL.clone();
    defer clone.deinit();

    time = timer.read();

    // Print stats //
    // Test' individual stats
    try writeStamps("CLONE", clone.size, time);

    try stdout.print("\n", .{});
    try stdout.flush();
}

pub fn benchU64(N: usize, steady_state: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("memory leak ...");
    };
    const allocatorG = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocatorA = arena.allocator();
    defer arena.deinit();

    var sL = try SortedMap(u64, u64, .set).init(allocatorG);
    defer sL.deinit();

    // try sL.ensureTotalCapacity(N);

    // Get unique keys and shuffle them
    var keys = std.array_list.Managed(u64).init(allocatorA);
    defer keys.deinit();

    var prng = std.Random.DefaultPrng.init(@abs(std.time.timestamp()));
    const random = prng.random();

    const cycles_rh: usize = N / 100;
    const cycles_ex: usize = N / 100;
    const cycles_exh: usize = N / 198;

    const use_steady: bool = steady_state != 0;
    const rh_steady: usize = if (use_steady) @max(steady_state, 98) else 98;
    const ex_steady: usize = if (use_steady) @max(steady_state, 40) else 10;
    const exh_steady: usize = if (use_steady) @max(steady_state, 98) else 1;

    // Ensure we have enough unique keys for all workloads (including sliding-window
    // steady-state variants).
    const key_count: usize = @max(
        N,
        @max(
            rh_steady + cycles_rh + 128,
            @max(ex_steady + (cycles_ex * 40) + 128, exh_steady + (cycles_exh * 98) + 128),
        ),
    );

    for (0..key_count) |key| {
        try keys.append(key);
    }
    random.shuffle(u64, keys.items);

    // Cosmetic function, number formatting
    var buffer: [16]u8 = undefined;
    const len = pretty(N, &buffer, allocatorA);

    // Print benchmark header
    try stdout.print("\n{s: >38}|", .{"SortedMap u64 BENCHMARK"});
    try stdout.print("\n{s: >24} ops:each test|\n", .{buffer[0..len]});
    try stdout.print("\n|{s: <13}|{s: >11}|{s: >11}|\n", .{ "name", "Tp Mops:sec", "Rt :sec" });
    try stdout.print(" {s:=>37}\n", .{""});
    try stdout.flush();

    // ------------------ READ HEAVY -----------------//
    // ---- read 98, insert 1, remove 1, update 0 --- //

    // Initial input for the test because we start with read.
    for (keys.items[0..rh_steady]) |key| {
        try sL.put(key, key);
    }

    // Start the timer
    var time: u128 = 0;
    var timer = try std.time.Timer.start();

    var checksum_rh: u64 = 0;
    // Cycle of 100 operations each
    var remove_idx: usize = 0;
    var insert_idx: usize = rh_steady;
    for (0..cycles_rh) |_| {

        // Read the slice of 98 keys
        for (keys.items[remove_idx .. remove_idx + 98]) |key| {
            const v = sL.get(key) orelse unreachable;
            checksum_rh +%= v;
        }

        // Insert 1 new
        const in_k = keys.items[insert_idx];
        try sL.put(in_k, in_k);

        // Remove 1
        if (!sL.remove(keys.items[remove_idx])) @panic("bench invariant failed: RH remove");
        remove_idx += 1;
        insert_idx += 1;
    }
    time = timer.read();
    std.mem.doNotOptimizeAway(checksum_rh);
    const ops_rh: usize = (N / 100) * 100;

    // Print stats //
    // Test' individual stats
    try writeStamps("RH", ops_rh, time);

    // Clear the sL
    if (sL.size != rh_steady) @panic("bench invariant failed: RH size");
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // ------------------ EXCHANGE -------------------//
    // -- read 10, insert 40, remove 40, update 10 -- //

    // Re-shuffle the keys
    random.shuffle(u64, keys.items);

    var checksum_ex: u64 = 0;
    if (!use_steady) {
        for (keys.items[0..10]) |key| {
            try sL.put(key, key);
        }
        timer = try std.time.Timer.start();

        var k: usize = 0;
        for (0..N / 100) |i| {
            for (keys.items[i + k .. i + k + 10]) |key| {
                const v = sL.get(key) orelse unreachable;
                checksum_ex +%= v;
            }
            for (keys.items[i + k + 10 .. i + k + 50]) |key| {
                try sL.put(key, key);
            }
            for (keys.items[i + k .. i + k + 40]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EX remove");
            }
            for (keys.items[i + k + 40 .. i + k + 50]) |key| {
                if (!sL.update(key, key)) @panic("bench invariant failed: EX update");
            }
            k += 39;
        }
        time = timer.read();
    } else {
        for (keys.items[0..ex_steady]) |key| {
            try sL.put(key, key);
        }
        timer = try std.time.Timer.start();

        var resident_start: usize = 0;
        for (0..cycles_ex) |_| {
            for (keys.items[resident_start .. resident_start + 10]) |key| {
                const v = sL.get(key) orelse unreachable;
                checksum_ex +%= v;
            }
            for (keys.items[resident_start + ex_steady .. resident_start + ex_steady + 40]) |key| {
                try sL.put(key, key);
            }
            for (keys.items[resident_start .. resident_start + 40]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EX remove");
            }
            for (keys.items[resident_start + ex_steady + 30 .. resident_start + ex_steady + 40]) |key| {
                if (!sL.update(key, key)) @panic("bench invariant failed: EX update");
            }
            resident_start += 40;
        }
        time = timer.read();
        if (sL.size != ex_steady) @panic("bench invariant failed: EX size");
    }
    std.mem.doNotOptimizeAway(checksum_ex);
    const ops_ex: usize = (N / 100) * 100;

    // Print stats //
    // Test' individual stats
    try writeStamps("EX", ops_ex, time);

    // Clear the sL
    if (sL.size != 10 and !use_steady) @panic("bench invariant failed: EX size");
    try sL.clearRetainingCapacity();
    arenaCacheSizeQuery(&sL.cache);

    // --------------- EXCHANGE HEAVY --------------//
    // -- read 1, insert 98, remove 98, update 1 -- //

    // Re-shuffle the keys
    random.shuffle(u64, keys.items);

    var checksum_exh: u64 = 0;
    if (!use_steady) {
        for (keys.items[0..1]) |key| {
            try sL.put(key, key);
        }
        timer = try std.time.Timer.start();

        var k: usize = 0;
        for (0..N / 198) |i| {
            for (keys.items[i + k .. i + k + 1]) |key| {
                const v = sL.get(key) orelse unreachable;
                checksum_exh +%= v;
            }
            for (keys.items[i + k + 1 .. i + k + 99]) |key| {
                try sL.put(key, key);
            }
            for (keys.items[i + k .. i + k + 98]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EXH remove");
            }
            for (keys.items[i + k + 98 .. i + k + 99]) |key| {
                if (!sL.update(key, key)) @panic("bench invariant failed: EXH update");
            }
            k += 97;
        }
        time = timer.read();
    } else {
        for (keys.items[0..exh_steady]) |key| {
            try sL.put(key, key);
        }
        timer = try std.time.Timer.start();

        var resident_start: usize = 0;
        for (0..cycles_exh) |_| {
            const key0 = keys.items[resident_start];
            const v = sL.get(key0) orelse unreachable;
            checksum_exh +%= v;

            for (keys.items[resident_start + exh_steady .. resident_start + exh_steady + 98]) |key| {
                try sL.put(key, key);
            }
            for (keys.items[resident_start .. resident_start + 98]) |key| {
                if (!sL.remove(key)) @panic("bench invariant failed: EXH remove");
            }
            const up = keys.items[resident_start + exh_steady + 97];
            if (!sL.update(up, up)) @panic("bench invariant failed: EXH update");

            resident_start += 98;
        }
        time = timer.read();
        if (sL.size != exh_steady) @panic("bench invariant failed: EXH size");
    }
    std.mem.doNotOptimizeAway(checksum_exh);
    const ops_exh: usize = (N / 198) * 198;

    // Print stats //
    // Test' individual stats
    try writeStamps("EXH", ops_exh, time);

    // Clear the sL
    if (sL.size != 1 and !use_steady) @panic("bench invariant failed: EXH size");
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
    timer = try std.time.Timer.start();

    // Cycle of 100 operations each
    var k: usize = 0; // helper coefficient to get the keys rotating
    var checksum_rg: u64 = 0;
    for (0..N / 100) |i| {

        // Read 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            const v = sL.get(key) orelse unreachable;
            checksum_rg +%= v;
        }

        // Insert 80 new
        for (keys.items[i + k + 5 .. i + k + 85]) |key| {
            try sL.put(key, key);
        }

        // Remove 5
        for (keys.items[i + k .. i + k + 5]) |key| {
            if (!sL.remove(key)) @panic("bench invariant failed: RG remove");
        }

        // Update 10
        for (keys.items[i + k + 5 .. i + k + 15]) |key| {
            if (!sL.update(key, key)) @panic("bench invariant failed: RG update");
        }

        k += 79;
    }
    time = timer.read();
    std.mem.doNotOptimizeAway(checksum_rg);
    const ops_rg: usize = (N / 100) * 100;

    // Print stats //
    // Test' individual stats
    try writeStamps("RG", ops_rg, time);
    arenaCacheSizeQuery(&sL.cache);

    // ---------------- CLONING -----------------//
    // ------ obtain a clone of the graph ------ //

    // Clear the time, re-start the timer
    timer = try std.time.Timer.start();

    var clone = try sL.clone();
    defer clone.deinit();

    time = timer.read();

    // Print stats //
    // Test' individual stats
    try writeStamps("CLONE", clone.size, time);

    try stdout.print("\n", .{});
    try stdout.flush();
}

/// Print to the screen the size of the current memory being used by the arena allocator
/// along with the cache's len.
fn arenaCacheSizeQuery(cache: anytype) void {
    std.debug.print("arena size: {}, cache len: {}\n\n", .{
        cache.arena.queryCapacity(),
        cache.len(),
    });
}

fn toSeconds(t: u128) f64 {
    return @as(f64, @floatFromInt(t)) / 1_000_000_000;
}

fn throughput(ops: usize, time: u128) f64 {
    if (ops == 0 or time == 0) return 0;
    return @as(f64, @floatFromInt(ops)) / toSeconds(time) / 1_000_000;
}

fn writeStamps(test_name: []const u8, ops: usize, time: u128) !void {
    const throughput_ = throughput(ops, time);
    const runtime = toSeconds(time);

    try stdout.print("|{s: <13}|{d: >11.2}|{d: >11.6}|\n", .{ test_name, throughput_, runtime });
    try stdout.flush();
}

fn pretty(N: usize, buffer: []u8, alloc: std.mem.Allocator) usize {
    var stack = std.array_list.Managed(u8).init(alloc);
    defer stack.deinit();

    var N_ = N;
    var counter: u8 = 0;

    while (N_ > 0) : (counter += 1) {
        const rem: u8 = @intCast(N_ % 10);
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
    \\      [-steady <N>], unsigned integer,
    \\      use a larger steady-state size for READ HEAVY (RH). RH will start with N items
    \\      (min 98) and then remove 1 / insert 1 per cycle to keep size constant.
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
    var steady_state: usize = 0;

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h")) {
            std.debug.print(HELP ++ "\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "-str")) {
            string = true;
            i += 1;
            continue;
        } else if (std.mem.eql(u8, arg, "-steady") or std.mem.eql(u8, arg, "--steady")) {
            if (i + 1 >= args.len) {
                std.debug.print(HELP ++ "\n", .{});
                return;
            }
            steady_state = try std.fmt.parseUnsigned(usize, args[i + 1], 10);
            i += 2;
            continue;
        } else {
            // Parse as integer N (allow underscores)
            var integer: bool = true;
            for (arg) |char| {
                if ((char < '0' or char > '9') and char != '_') integer = false;
            }
            if (!integer) {
                std.debug.print(HELP ++ "\n", .{});
                return;
            }
            // TODO give warning if N > 1B, y - n ?
            N = try std.fmt.parseUnsigned(usize, arg, 10);
            i += 1;
            continue;
        }
    }

    if (string) {
        try benchSTR(N, steady_state);
    } else try benchU64(N, steady_state);
}
