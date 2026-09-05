# zfuzz

**A fast, fzf-compatible fuzzy finder written in Zig.**

`zfuzz` is built for low-latency interactive search over large candidate sets. It keeps fzf-style query semantics and exact V2 ranking while using a parallel, append-friendly search backend designed to return useful results immediately as input and queries change.

- Exact fzf V2 scoring and ranking for the default algorithm
- Fast incremental refinement with reusable query frontiers
- Parallel lazy search for large interactive inputs
- Unicode-aware CLI matching and normalization
- Extended fzf-style query grammar, schemes, tiebreaks, placeholders, bindings, preview, reload, history, and multi-select
- Streaming input with responsive partial results
- Bash, Zsh, and Fish integration
- Reusable Zig fuzzy-search library in the same package

## Quick start

Requires **Zig 0.16.0+**.

```sh
git clone https://github.com/ItsMeSamey/zfuzz.git
cd zfuzz
zig build -Doptimize=ReleaseFast
./zig-out/bin/zfuzz
```

Pipe candidates into it just like a fuzzy finder:

```sh
find . -type f | ./zig-out/bin/zfuzz
```

Or use filter mode non-interactively:

```sh
printf 'alpha\nbeta\ngamma\n' | ./zig-out/bin/zfuzz --filter=ga
# gamma
```

## Why zfuzz?

The interactive path is optimized around the latency users actually feel: keypress handling, first useful results, cancellation, and exact completion.

For large inputs, `zfuzz` stores candidates in compact append-only pages, searches shards in parallel, publishes bounded partial top-K results early, and preserves useful completed work across refinements. Prefix refinements reuse prior survivor frontiers instead of blindly rescanning the same search space.

The default scorer preserves exact fzf V2 score/start/end behavior. Specialized short-query kernels skip irrelevant work while retaining exact ranking semantics.

## Performance

Representative guarded measurements on the development machine, using a 1,000,000-record refinement corpus:

| Query | zfuzz | fzf |
| --- | ---: | ---: |
| load | **113.74 ms** | 175.48 ms |
| `a` | **11.60 ms** | 37.95 ms |
| `ab` | **6.53 ms** | 10.09 ms |
| `abc` | **5.11 ms** | 7.34 ms |
| `abcd` | **4.30 ms** | 5.64 ms |
| `abcde` | **3.64 ms** | 4.29 ms |
| `abcdef` | 3.90 ms | **3.81 ms** |
| `abcdefg` | 3.87 ms | **3.12 ms** |
| `abcdefgh` | 3.59 ms | **3.19 ms** |

These are workload- and machine-specific numbers, not a claim that every query is faster. The broad and early-refinement cases are the primary optimization target because they dominate interactive latency.

At 120 Hz simulated typing on a 1M-record corpus, the validated build preserved **601/601 key events**, with cancellation/handoff latency of roughly **0.26 ms p50**, **0.47 ms p95**, and **0.54 ms p99**.

## fzf-style matching

The CLI exposes three fuzzy algorithms:

```text
--algo=v2         exact fzf V2 ranking (default)
--algo=v1         fzf V1 scoring
--algo=heuristic  conservative prefilters + exact V2 ranking
```

Common options include:

```sh
zfuzz --query=src
zfuzz --exact
zfuzz --scheme=path
zfuzz --tiebreak=length,index
zfuzz --multi
zfuzz --preview='bat --color=always {}'
zfuzz --bind='ctrl-r:reload(find . -type f)'
zfuzz --history="$HOME/.cache/zfuzz-history"
```

Run `zfuzz --help` for the full CLI surface.

## Streaming and interactive search

`zfuzz` does not require all input to exist before becoming useful. On supported POSIX terminals it can consume a live pipe, update results while records are still arriving, and wake the UI immediately when background search work produces new results.

The large-input backend uses:

1. compact page-based record storage;
2. shard-local search state and top-K selection;
3. reusable query frontiers for refinements;
4. early partial-result publication;
5. exact global top-K merging;
6. generation-aware cancellation so stale work does not overwrite newer queries.

ASCII input is classified once per source chunk so repeated refinements can avoid rescanning every record just to rediscover that it is ASCII. Mixed Unicode input automatically stays on the Unicode-aware path.

## Shell integration

The build installs shell integration files under `share/zfuzz/`:

```text
share/zfuzz/zfuzz.bash
share/zfuzz/zfuzz.zsh
share/zfuzz/zfuzz.fish
```

They can also be printed directly:

```sh
zfuzz --bash
zfuzz --zsh
zfuzz --fish
```

## Zig library

The package also exposes a small preprocessed fuzzy-search API:

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

`fuzzy.init` preprocesses and owns the searchable representation. `index.search` writes best-first candidate indices into caller-provided storage.

## Build and test

```sh
zig build -Doptimize=ReleaseFast
zig build test
```

The release-ready tree is tested in Debug, ReleaseSafe, and ReleaseFast modes and includes PTY end-to-end coverage for interactive navigation, live streaming, bracketed paste, lazy search, redraw behavior, previews, and Unicode transitions.

Cross-builds are validated for:

- x86_64 Linux musl
- aarch64 Linux musl
- x86_64 Windows GNU
- aarch64 Windows GNU
- x86_64 macOS
- aarch64 macOS

Interactive TTY mode is currently POSIX-oriented. Windows builds support piped/filter workflows; native Windows interactive terminal support is not yet implemented.

## License

MIT © ItsMeSamey
