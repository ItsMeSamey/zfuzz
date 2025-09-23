# Zig Fuzz

This Zig module functions for fuzzy string matching, comparison, and flexible sorting of strings.
Works with zig `0.14.0`, `0.14.1` and `0.15.1`.

## Features

* **String Similarity Algorithms:**
    * `FrequencyDistance` (a custom similarity measure)
    * `JaroSimilarity` and `JaroWinklerSimilarity` (including a bidirectional variant)
    * `LCSPercentage` (Longest Common Subsequence as percentage of total length)
    * `LevenshteinSimilarityPercentage`
    * `LevenshteinOSASimilarityPercentage` (Optimal String Alignment percentage)
    * `DamerauLevenshteinSimilarityPercentage`
    * And the underlying distance calculation functions (`LevenshteinDistance`, `LCSLength`, etc.).
* **Explicit Memory Management:** All functions take an `allocator`.

## Installation
1. Add http.zig as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/ItsMeSamey/zig_fuzzy#main"
```

2. Add `fuzzy` module as a dependency in build.zig:

```zig
const exe = b.addExecutable(...);
...
const fuzzy = b.dependency("fuzzy", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("fuzzy", fuzzy.module("fuzzy"));
```

## Usage

### `GetSorter` Function

`GetSorter` function allows you to create a `Sorter` type configured with your chosen similarity measure and Integer / Float types.
`Sorter` Provides methods for sorting collections of strings, or finding similarity between strings etc.

**Simple Example: Sorting `[]const u8` slices**

```zig
const std = @import("std");
const fuzzy = @import("fuzzy");

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
  const allocator = gpa.allocator();

  const Sorter = fuzzy.GetSorter(
    u32, f32,
    fuzzy.heuristics.LevenshteinSimilarityPercentage,
    null // Use default sorting algorithm (pdqContext)
  );

  const target = "apple";
  var candidates = [_][]const u8{"aple", "application", "orange", "banana", "appel"};
  var candidates_slice: [][]const u8 = &candidates;

  std.debug.print("Unsorted: {s}\n", .{candidates_slice});

  // 2. Sorter.sort to sorts the whole slice in-place.
  try Sorter.sort(target, candidates_slice, allocator);
  // Whole slice is sorted in this case.
  std.debug.print("Sorted: {s}\n", .{candidates_slice});

  // 2. Or use Sorter.sortOptions. Here, we only care about elements with similarity >= 0.3.
  //  Same threshold value may result in different results for different algorithms.
  const sorted_count = try Sorter.sortOptions(target, candidates_slice, allocator, .{
    .threshold = 0.6,
    .target_len = .{
      .min = 2, // Atleast top 2 strings will be in their sorted position
      .max = candidates_slice.len // No upper bound on number of sorted positions
    },
  });
  std.debug.print("Sorted (and filtered): {s}\n", .{candidates_slice[0..sorted_count]});
}
```
**Context variants**: there are Context variants available for all the functions in sorter for data types that are not slices / arrays.

### String Representation
All functions in this module expect and return strings in ascii format and not decoding is performed.

### Wrappers
Higher order wrapper functions are also available in fuzzy.heuristics to prioritize strings that have matching prefixes / suffixes / or both.
