# zig_fuzzy

Small ASCII fuzzy matcher for Zig 0.16.

The public API is intentionally just `score`, `find`, and `Match`.

```zig
const std = @import("std");
const fuzzy = @import("fuzzy");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const candidates = [_][]const u8{
        "src/fuzzy_backend.zig",
        "foo_bar",
        "FooBar",
        "unrelated",
    };

    const matches = try fuzzy.find(allocator, "fb", &candidates, 3);
    defer allocator.free(matches);

    for (matches) |match| {
        std.debug.print("{s} ({d})\n", .{ match.value, match.score });
    }
}
```

`score(query, candidate)` is allocation-free and returns `null` when the query
is not an ordered subsequence. Matching is ASCII case-insensitive and rewards
word boundaries, camelCase boundaries, consecutive characters, and short gaps.

`find(allocator, query, candidates, limit)` scores each candidate once and keeps
only the best `limit` entries in a bounded heap.

## Complexity

For the fixed dual-anchor scorer (two anchors from each direction):

- `score`: `O(query.len + candidate.len)` time, `O(1)` space.
- `find`: `O(total_candidate_bytes + N log K + K log K)` time and `O(K)` space,
  where `K = limit`.

For the normal fuzzy-search case where `K` is small, `find` is effectively
linear in the amount of candidate text scanned.

## Install

```bash
zig fetch --save "git+https://github.com/ItsMeSamey/zig_fuzzy#main"
```

```zig
const fuzzy = b.dependency("fuzzy", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("fuzzy", fuzzy.module("fuzzy"));
```
