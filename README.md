<div align="center">

# zfuzz

### Fast, fzf-compatible fuzzy finding in Zig

Exact fzf V2 ranking · low-latency parallel search · streaming input

[![Zig](https://img.shields.io/badge/Zig-0.16.0%2B-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-2563eb)](./LICENSE)
[![GitHub](https://img.shields.io/badge/source-GitHub-181717?logo=github)](https://github.com/ItsMeSamey/zfuzz)

</div>

`zfuzz` is an interactive fuzzy finder built around the latency you actually feel: keypress-to-result time, fast cancellation, and exact completion on large inputs.

## ✨ Highlights

- **Exact fzf V2 ranking** by default
- **Parallel lazy search** for large candidate sets
- **Fast incremental refinement** with reusable survivor frontiers
- **Streaming input** with early partial results
- **Unicode-aware** CLI matching and normalization
- Preview, reload, bindings, history, multi-select, schemes, tiebreaks, and placeholders
- Bash, Zsh, and Fish integration

## 🚀 Quick start

Requires **Zig 0.16.0+**.

```sh
git clone https://github.com/ItsMeSamey/zfuzz.git
cd zfuzz
zig build -Doptimize=ReleaseFast
find . -type f | ./zig-out/bin/zfuzz
```

Non-interactive filtering works too:

```sh
printf 'alpha\nbeta\ngamma\n' | ./zig-out/bin/zfuzz --filter=ga
# gamma
```

## 🏁 Performance

Representative guarded measurements on a **1,000,000-record** refinement corpus:

| Query | zfuzz | fzf |
| --- | ---: | ---: |
| load | **113.74 ms** | 175.48 ms |
| `a` | **11.60 ms** | 37.95 ms |
| `ab` | **6.53 ms** | 10.09 ms |
| `abc` | **5.11 ms** | 7.34 ms |
| `abcde` | **3.64 ms** | 4.29 ms |
| `abcdefgh` | 3.59 ms | **3.19 ms** |

At **120 Hz** simulated typing over 1M records, the validated build preserved **601/601 key events** with about **0.26 ms p50**, **0.47 ms p95**, and **0.54 ms p99** cancellation/handoff latency.

> Benchmarks are workload- and machine-specific. Broad and early-refinement queries are the primary optimization target.

## ⚡ Usage

```sh
zfuzz --query=src
zfuzz --exact
zfuzz --scheme=path
zfuzz --multi
zfuzz --preview='bat --color=always {}'
zfuzz --bind='ctrl-r:reload(find . -type f)'
zfuzz --history="$HOME/.cache/zfuzz-history"
```

Run `zfuzz --help` for the full CLI surface.

### Algorithms

| Option | Behavior |
| --- | --- |
| `--algo=v2` | Exact fzf V2 ranking — default |
| `--algo=v1` | fzf V1 scoring |
| `--algo=heuristic` | Conservative prefilters, then exact V2 ranking |

## 🧠 Under the hood

Large interactive searches use:

- compact append-only candidate pages;
- shard-local parallel search;
- early partial top-K publication;
- generation-aware cancellation;
- reusable frontiers for prefix refinements;
- chunk-level ASCII classification to avoid repeated rescans.

The optimized default scorer still preserves exact fzf V2 score/start/end behavior.

## 🧩 Zig library

The package also exposes a small preprocessed fuzzy-search API:

```zig
const fuzzy = @import("fuzzy");

var index = try fuzzy.init(allocator, &candidates);
defer index.deinit();

var out: [10]usize = undefined;
const matches = try index.search("fb", &out);
```

`fuzzy.init` owns the searchable representation. `index.search` writes best-first candidate indices into caller-provided storage.

## 🐚 Shell integration

The build installs `zfuzz.bash`, `zfuzz.zsh`, and `zfuzz.fish` under `share/zfuzz/`.

They can also be printed directly:

```sh
zfuzz --bash
zfuzz --zsh
zfuzz --fish
```

## 🖥️ Platform support

| Platform | Filter / piped mode | Interactive TTY |
| --- | --- | --- |
| Linux / POSIX | ✅ | ✅ |
| macOS | compile-validated | POSIX backend, compile-validated |
| Windows | ✅ | not implemented yet |

ReleaseFast cross-builds are validated for x86_64/aarch64 Linux, Windows, and macOS. Native runtime validation is currently performed on Linux.

## 🛠️ Build & test

```sh
zig build -Doptimize=ReleaseFast
zig build test
```

Debug, ReleaseSafe, and ReleaseFast test matrices are all validated.

## 📜 License

MIT. See [LICENSE](./LICENSE).
