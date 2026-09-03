# zig_fuzzy

Fast preprocessed fuzzy search for Zig 0.16.

The public workflow is deliberately small:

```zig
const std = @import("std");
const fuzzy = @import("fuzzy");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const candidates = [_][]const u8{
        "src/fuzzy_backend.zig",
        "src/frame_buffer.zig",
        "README.md",
        "unrelated",
    };

    var index = try fuzzy.init(allocator, &candidates);
    defer index.deinit();

    var out: [10]usize = undefined;
    for (try index.search("fb", &out)) |i| {
        std.debug.print("{s}\n", .{candidates[i]});
    }
}
```

That is the API: preprocess the candidate array once with `fuzzy.init`, then call
`index.search(query, output_buffer)`. Query preprocessing is automatic on every
search; there is no unprepared search path.

`fuzzy.init` copies the searchable representation, so the input strings do not
need to remain alive afterward. Search returns indices in the original input
ordering, sorted best-first. The caller chooses top-K by the size of the output
buffer and owns that storage.

## Search pipeline

Candidate preprocessing builds folded bytes, fzf-compatible boundary bonuses,
a transposed 64-class/two-count signature, and a compact safe score ceiling.
A search then uses this cascade:

1. **Signature filter** — bitset intersections discard candidates that cannot
   contain the query characters/counts. On the benchmark corpus this removes
   about 68% before touching candidate text.
2. **Exact forward subsequence scan** — rejects candidates with the wrong order
   and simultaneously records the first feasible position for each query byte.
3. **Score-ceiling filter** — once top-K has a cutoff, a safe precomputed upper
   bound rejects candidates that cannot possibly beat it. This avoids most V2
   dynamic-programming calls without changing results.
4. **fzf V2 score** — exact V2 scoring runs only for candidates still capable of
   entering top-K.

When the next query is a prefix extension of the previous one, the index also
reuses the previous exact subsequence-survivor bitset and scores the previous
top-K first to establish a strong cutoff early. Backspace or an unrelated query
resets that cache automatically.

The public `Index.search` core remains bytewise ASCII case-insensitive. The
`zfuzz` command-line frontend additionally follows fzf's Unicode simple-case
and Latin/fullwidth normalization behavior when a query or candidate contains
non-ASCII text; `--literal` disables that normalization. This Unicode frontend
path does not add any public library API or change the ordinary ASCII indexed
search path.

The frontend also supports fzf-style command placeholders for preview,
execute, reload, and transform actions. This includes current (`{}`), selected
(`{+}`), matched (`{*}`), field/range (`{1}`, `{2..}`, `{+1}`), ordinal
(`{n}`), query (`{q}`, `{q:2..}`), raw (`r`), whitespace-preserving (`s`), and
temporary-file (`f`) forms. Prefix a valid placeholder with a backslash (for
example `\{}`) to keep it literal. Dynamic `change-nth`/`transform-nth` and
`change-with-nth`/`transform-with-nth` actions follow fzf's pipe-cycling,
default-restoration, first-line transform, and `FZF_NTH`/`FZF_WITH_NTH`
environment semantics; background transform variants are supported as well.

## Complexity

Let `N` be the number of candidates, `B` the bytes actually scanned after
filtering, `Q` the query length, and `D` the number of candidates that survive
the score ceiling and need V2.

- index construction: `O(total candidate bytes)`
- signature filter: `O(U * N / 64)`, where `U <= 64` is the number of query
  signature classes
- forward subsequence work: `O(B)`
- V2 work: `O(D * Q * average surviving candidate length)`
- top-K maintenance: `O(D log K)`

The important point is that V2 is no longer paid for every candidate.

## Install

Requires Zig 0.16.0 or newer.
