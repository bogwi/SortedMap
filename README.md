# SortedMap in ZIG

## Description
An advance version of [skiplist ADT](https://en.wikipedia.org/wiki/Skip_list) as proposed by W.Pugh in 1989.

The motivation was to create a map where items are stored by storing keys in non-decreasing order with put and remove times as close to a real-word hashmap as possible. As far as is known, this is the first elaborate effort to create such a complete map in ZIG. Takes integer, float and string literals as keys. Supports a wide range of operations on keys, as well as positive and negative indexing, similar to Python's list class. Querying an *nth* item or range of items, is just a call. The SortedMap has a built-in cache for memory efficiency. Works even more efficiently with hefty key-value pairs.

The main difference from the whitepaper version is the fixed probability *p* of creating a new "express lane" when building the map. The two commonly used values for *p* are 1/2 or 1/4. However, this map uses *p* = 1/7, prioritizing real-world usage scenarios *(see RH, EX, EXH test)* instead of rapid growth tests *(RH)* as benchmarks. The 1/7 value for *p* also results in a lower memory footprint than 1/4. 

The map works in two modes, `.set` and `.list`. The latter allows duplicate keys.

This is what the abstract form of the SortedMap can look like internally when storing signed integer keys in `.list` mode:

```______________________5_____6_____________________________11________________________________________________
288_________________2_5_5___6___7___________9_____________11__________________________________51_52____54___
288_287_286_285_0_0_2_5_5_6_6_7_7_7_8_8_8_9_9_10_10_10_11_11_12_12_13_13_13_14_14_15_15_15_50_51_52_53_54_55
```

This is for literal keys derived from *Zig is a general-purpose programming language and toolchain for maintaining robust, optimal and reusable software*, in `.set` mode:

```______and_____________________is____________________________________________________________________________
______and_____________________is____________________________________________________________________________
____a_and_____________________is___________________________________________________robust___________________
Zig_a_and_for_general-purpose_is_language_maintaining_optimal_programming_reusable_robust_software_toolchain
```

## API
```
init:                                void
deinit:                              void

clone                               !Self
cloneWithAllocator                  !Self

clearAndFree                        !void
clearRetainingCapacity              !void

put                                 !void
update                               bool
updateByIndex                        bool
setSliceToValue                     !void
contains                             bool

get                                ?VALUE
getByIndex                         ?VALUE
getOrNull                          ?VALUE
getFirst                            VALUE
getFirstOrNull                     ?VALUE
getItem                             ?Item
getItemByIdex                       ?Item
getSlice                   !SliceIterator

pop                                 VALUE
popOrNull                          ?VALUE
popFirst                            VALUE
popFirstOrNull                     ?VALUE

remove                               bool
removeByIndex                        bool
fetchRemove                          bool
fetchRemoveByIndex                   bool
removeSlice                         !bool
removeSliceByIndex                  !bool

items                            Iterator
itemsReversed             ReverseIterator

min                                 VALUE
max                                 VALUE
median                              VALUE


```
## Performance
The benchmark is a set of standard stress routines to measure the throughput for the given task. The machine is an Apple M1 with 32GB RAM.

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

### `u64`, unsigned 64-bit integer
```
               SortedMap u64 BENCHMARK|
               1_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |      34.05|   0.029372|
|EX           |      20.91|   0.047825|
|EXH          |      18.35|   0.054484|
|RG           |       1.57|   0.637526|
|CLONE        |       5.89|   0.127426|
|aggregate    |       5.30|   0.896633|
```

### `[8]const u8`, string literal of the length of 8 chars
```
               SortedMap STR BENCHMARK|
               1_000_000 ops:each test|

|name         |Tp Mops:sec|    Rt :sec|
 =====================================
|RH           |      28.63|   0.034930|
|EX           |      18.00|   0.055543|
|EXH          |      15.00|   0.066652|
|RG           |       0.96|   1.037945|
|CLONE        |       4.85|   0.154799|
|aggregate    |       3.52|   1.349869|
```

### bench conclusions
From the results, the performance of the SortedMap is close to that of hashmaps. Apart from the Rapid Grow test, which builds the SortedMap from the ground, doing the heaviest work, the given SortedMap is very much in league with modern map ADTs.

Think of the SortedMap as your go to ADT whenever you need to have your keys always sorted and the indexed access is a must.

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
const SortedMap = @import("skiplist.zig").SortedMap;
```

Initiate for numeric keys:
```zig
const SL = SortedMap(u64, your_value_type, .list);
var sL: SL = .{};

try sL.init(your_allocator);
defer sL.deinit();

```

Initiate for string literal keys:
```zig
const SL = SortedMap([]const u8, your_value_type, .set);
var sL: SL = .{};

try sL.init(your_allocator);
defer sL.deinit();
```













