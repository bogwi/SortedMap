# SortedMap in ZIG

## Description

Sorted Map is a fast key-value table, an advance version of [skiplist ADT](https://en.wikipedia.org/wiki/Skip_list) as proposed by W.Pugh in 1989 for ordered mapping of keys to  values.

## Features 
* Keys are any numeric but smaller than `2^63-1` or literal, `[]const u8`, but smaller than `"ÿ"` ASCII 255. 
* Values are any values.
* Works in `.set` or `.list` mode. The latter allows duplicate keys.
* Forward backward iteration.
* Has `min`, `max`, `median` key query.
* Supports queries by key or index akin to Python's list class, including reverse indexing.
* Basic operations like `put`, `get`, `remove` work on a range or a slice of keys as well

## Performance
The benchmark is a set of standard stress routines to measure the throughput for the given task. The machine is an Apple M1 with 32GB RAM, optimization flag `ReleaseSafe`.

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

### `u64`, arbitrary feed
```
               SortedMap u64 BENCHMARK|
              10_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |      51.47|   0.194274|
arena size: 13804, cache len: 131

|EX           |      23.25|   0.430069|
arena size: 13804, cache len: 121

|EXH          |      20.20|   0.494928|
arena size: 13804, cache len: 135

|RG           |       0.53|  18.996072|
arena size: 595966060, cache len: 5

|CLONE        |       5.86|   1.279128|
```

### `[8]const u8`, arbitrary literal, arbitrary feed
```
               SortedMap STR BENCHMARK|
              10_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |      25.49|   0.392336|
arena size: 13564, cache len: 133

|EX           |      17.02|   0.587408|
arena size: 13564, cache len: 123

|EXH          |      14.49|   0.690115|
arena size: 13564, cache len: 137

|RG           |       0.37|  26.855707|
arena size: 894236804, cache len: 5

|CLONE        |       3.12|   2.400613|
```

## How to run the benchmark
```
zig build bench
```
by default it runs 100_000 rounds each test on `u64` type

Give it a larger number to stress the map more
```
zig build bench -- 1_000_000
```
prepend with `-str` to test on `[8]u8` literal.
```
zig build bench -- 1_000_000 -str
```

## How to use it
It is best to copy the `sorted_map.zig` and `cache.zig` into your project or make a fork and work from that.

Declare in your file:
```zig
const SortedMap = @import("sorted_map.zig").SortedMap;
```

Initiate for numeric keys:
```zig
const map = SortedMap(u64, your_value_type, .list).init(your_allocator);
defer map.deinit();

```

Initiate for string literal keys:
```zig
const map = SortedMap([]const u8, your_value_type, .set).init(your_allocator);
defer map.deinit();
```













