# SortedMap in Zig

## Description

Sorted Map is a fast key-value table, an advance version of [skiplist ADT](https://en.wikipedia.org/wiki/Skip_list) as proposed by W.Pugh in 1989 for ordered mapping of keys to  values.

## Features 
* Takes any numeric key except the maximum possible value for the given type. 
* Takes any literal key of type `[]const u8` and of any length, but lexicographically smaller than `"ÿ"` ASCII 255. 
* Values are arbitrary values.
* Works in `.set` or `.list` mode. The latter allows duplicate keys.
* Has forward and backward iteration.
* Thread-safe public API (per-instance `std.Thread.RwLock`).
* RAII-style locked iterators/slices (hold a shared lock until `deinit()`).
* Has `min`, `max`, `median` key query.
* Supports queries by key or index, similar to Python's list class, including reverse indexing.
* Basic operations like `get`, `remove` work on a range as well.
* Updating the values by giving the `start_idx` - `stop_idx` range is O(1) each update. Yes, the whole map can be updated in O(n).
* Updating the values by giving the `start_key` - `stop_key` range is O(1) each update.

## Performance
The benchmark is a set of standard stress routines to measure throughput for a few operation mixes. The machine is an Apple M4 Pro (12‑core), optimization flag `ReleaseFast`.

There are five tests in total, all of which are run on the random data with intermediate shuffling during the test stages:

**READ HEAVY**\
[read 98, insert 1,  remove 1,  update 0 ]\
Models caching of data in places such as web servers and disk page caches.

**EXCHANGE**\
[read 10, insert 40, remove 40, update 10]\
Replicates a scenario where the map is used to exchange data.

**EXCHANGE HEAVY**\
[read 1, insert 98, remove 98, update 1]\
This test is an inverse of *RH* test. Hard for any map.

**RAPID GROW**\
[read 5,  insert 80, remove 5,  update 10]\
A scenario where the map is used to collect large amounts of data in a short burst.

**CLONE**\
Clone the Map. That is, rebuild the map anew yet from the sorted data.

Notes:
- For `RH` / `EX` / `EXH`, the `-steady <N>` flag switches these from a small, hot working-set benchmark (default) to a **constant-size "resident set"** benchmark. The default numbers are not "toy" results: many real uses of a sorted map operate at small sizes where everything fits in cache. Each cycle removes from the front of a sliding window and inserts at the back, keeping the map size ~constant.
- `EXH` runs cycles of 198 operations, so when the requested `N` isn't divisible by 198, the benchmark rounds down to `floor(N/198)*198` for that test's throughput calculation.

### `u64`, arbitrary feed (default / hot working set)
```
               SortedMap u64 BENCHMARK|
               1_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |      59.71|   0.016747|
arena size: 13804, cache len: 127

|EX           |      31.58|   0.031670|
arena size: 13804, cache len: 119

|EXH          |      27.53|   0.036321|
arena size: 13804, cache len: 131

|RG           |       1.33|   0.749447|
arena size: 78068140, cache len: 5

|CLONE        |       5.95|   0.126067|
```

### `u64`, arbitrary feed (`-steady 100_000` / large resident set)
```
               SortedMap u64 BENCHMARK|
               1_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |      12.59|   0.079411|
arena size: 9984748, cache len: 116621

|EX           |       3.95|   0.253051|
arena size: 9984748, cache len: 116946

|EXH          |       3.75|   0.266472|
arena size: 9984748, cache len: 117008

|RG           |       1.36|   0.737792|
arena size: 78068140, cache len: 5

|CLONE        |       5.90|   0.127064|
```

### `[8]const u8`, arbitrary literal, arbitrary feed (default / hot working set)
```
               SortedMap STR BENCHMARK|
               1_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |      36.06|   0.027734|
arena size: 13564, cache len: 134

|EX           |      20.52|   0.048726|
arena size: 13564, cache len: 126

|EXH          |      17.33|   0.057692|
arena size: 13564, cache len: 133

|RG           |       0.78|   1.285388|
arena size: 78068284, cache len: 5

|CLONE        |       4.47|   0.167763|
```

### `[8]const u8`, arbitrary literal, arbitrary feed (`-steady 100_000` / large resident set)
```
               SortedMap STR BENCHMARK|
               1_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |       3.40|   0.293788|
arena size: 9984684, cache len: 116841

|EX           |       1.98|   0.504200|
arena size: 9984684, cache len: 116982

|EXH          |       1.76|   0.567660|
arena size: 9984684, cache len: 117089

|RG           |       0.82|   1.216110|
arena size: 78068284, cache len: 5

|CLONE        |       4.68|   0.160204|
```

## How to run the benchmark
```
zig build bench
```
By default it runs 100_000 rounds each test on the `u64` type.

Give it a larger number to stress the map more.
```
zig build bench -- 1_000_000
```
Add `-steady <N>` to run `RH`/`EX`/`EXH` against a large constant-size resident set (more realistic for cache/exchange scenarios):
```
zig build bench -- 1_000_000 -steady 100_000
```
Prepend with `-str` to test on the arbitrary `[8]u8` word (can be combined with `-steady`):
```
zig build bench -- 1_000_000 -str
```
```
zig build bench -- 1_000_000 -str -steady 100_000
```

## How to use it
Copy `sorted_map.zig` and `cache.zig` into your project, or make a fork and work from there. Or you can import it as a dependency.

Declare in your file:
```zig
const SortedMap = @import("sorted_map.zig").SortedMap;
```

Initiate for numeric keys:
```zig
var map = try SortedMap(u64, your_value_type, .list).init(your_allocator);
defer map.deinit();

```

Initiate for string literal keys:
```zig
var map = try SortedMap([]const u8, your_value_type, .set).init(your_allocator);
defer map.deinit();
```

### Thread-safety and locked iterators

`SortedMap` uses a per-instance `std.Thread.RwLock` internally, so most public APIs are safe to call concurrently on the same map instance.

- **Write APIs** take an exclusive lock (e.g. `put`, `remove*`, `update*`, `setSlice*`, `clear*`, `deinit`).
- **Read APIs** take a shared lock (e.g. `get*`, `contains`, `min/max/median`).

Some low-level pointer-returning APIs are **not** thread-safe and require holding `lockShared()` externally (e.g. `getNodePtr`, `getNodePtrByIndex`):

```zig
map.rwlock.lockShared();
defer map.rwlock.unlockShared();

if (map.getNodePtr(some_key)) |node| {
    _ = node; // safe to read while lockShared is held
}
```

Iteration is thread-safe via **locked iterators** that hold `rwlock.lockShared()` for their lifetime. Always release the lock with `defer it.deinit();`:

```zig
var it = map.items();
defer it.deinit();
while (it.next()) |item| {
    _ = item;
}
```

The following APIs return locked iterators and **require `deinit()`**:

- `items()` / `itemsReversed()`
- `iterByKey()` / `iterByIndex()`
- `getSliceByKey()` / `getSliceByIndex()`

**Deadlock caveat**: while a locked iterator is alive on a thread, don't call other map methods that also lock `rwlock` (shared or exclusive) from the same thread.


## zig version
```
0.15.2
```













