const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Case = struct {
    name: []const u8,
    script: []const u8,
    stdout: []const u8,
    exit_code: u8 = 0,
};

const Suite = struct {
    allocator: Allocator,
    io: Io,
    bin: []const u8,
    passed: usize = 0,

    fn run(self: *Suite, case: Case) !void {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", case.script, "zfuzz-e2e", self.bin },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(8 * 1024 * 1024),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const code: u8 = switch (result.term) {
            .exited => |value| value,
            else => 255,
        };
        if (code != case.exit_code or !std.mem.eql(u8, result.stdout, case.stdout)) {
            std.debug.print("FAIL {s}: exit {d}, expected {d}\nstdout: {any}\nexpected: {any}\nstderr: {s}\n", .{
                case.name,
                code,
                case.exit_code,
                result.stdout,
                case.stdout,
                result.stderr,
            });
            return error.EndToEndFailure;
        }
        self.passed += 1;
        std.debug.print("PASS {s}\n", .{case.name});
    }
};

fn runCases(suite: *Suite, cases: []const Case) !void {
    for (cases) |case| try suite.run(case);
}
const basic_cases = [_]Case{
    .{ .name = "version", .script = "\"$1\" --version", .stdout = "zfuzz 0.2.0\n" },
    .{ .name = "basic fuzzy filter", .script = "printf 'alpha\\nbeta\\ngamma\\n' | \"$1\" --filter=ga", .stdout = "gamma\n" },
    .{ .name = "no-sort preserves input order", .script = "printf 'zebra\\nza\\nalpha\\n' | \"$1\" --no-sort --filter=z", .stdout = "zebra\nza\n" },
    .{ .name = "exact rejects subsequence-only", .script = "printf 'axbyc\\nabc\\n' | \"$1\" --exact --filter=abc", .stdout = "abc\n" },
    .{ .name = "smart case", .script = "printf 'Alpha\\nalpha\\nALPHA\\n' | \"$1\" --no-sort --filter=Alpha", .stdout = "Alpha\n" },
    .{ .name = "forced ignore case", .script = "printf 'Alpha\\nalpha\\nALPHA\\n' | \"$1\" --no-sort --ignore-case --filter=Alpha", .stdout = "Alpha\nalpha\nALPHA\n" },
    .{ .name = "unicode normalization", .script = "printf 'Danço\\nDanco\\nother\\n' | \"$1\" --no-sort --filter=danco", .stdout = "Danço\nDanco\n" },
    .{ .name = "literal disables normalization", .script = "printf 'Danço\\nDanco\\n' | \"$1\" --no-sort --literal --filter=danco", .stdout = "Danco\n" },
    .{ .name = "extended and", .script = "printf 'foo bar\\nfoo baz\\nbar baz\\n' | \"$1\" --no-sort --filter='foo bar'", .stdout = "foo bar\n" },
    .{ .name = "extended inverse", .script = "printf 'foo\\nfoo bar\\nfoo baz\\n' | \"$1\" --no-sort --filter='foo !bar'", .stdout = "foo\nfoo baz\n" },
};
const io_cases = [_]Case{
    .{ .name = "read0 print0", .script = "printf 'one\\0two\\0three\\0' | \"$1\" --read0 --print0 --filter=tw", .stdout = "two\x00" },
    .{ .name = "ansi match preserves output", .script = "printf '\\033[31mred\\033[0m\\nblue\\n' | \"$1\" --ansi --filter=red", .stdout = "\x1b[31mred\x1b[0m\n" },
    .{ .name = "delimiter nth", .script = "printf '1:alpha:x\\n2:beta:y\\n' | \"$1\" --delimiter=: --nth=2 --filter=beta", .stdout = "2:beta:y\n" },
    .{ .name = "accept nth", .script = "printf '1:alpha:x\\n2:beta:y\\n' | \"$1\" --delimiter=: --accept-nth=1,3 --filter=beta", .stdout = "2:y\n" },
    .{ .name = "tail", .script = "printf 'one\\ntwo\\nthree\\nfour\\n' | \"$1\" --tail=2 --no-sort --filter=''", .stdout = "three\nfour\n" },
    .{ .name = "tac", .script = "printf 'one\\ntwo\\nthree\\n' | \"$1\" --tac --no-sort --filter=''", .stdout = "three\ntwo\none\n" },
    .{ .name = "print query", .script = "printf 'alpha\\nbeta\\n' | \"$1\" --print-query --filter=beta", .stdout = "beta\nbeta\n" },
    .{ .name = "disabled search", .script = "printf 'one\\ntwo\\n' | \"$1\" --disabled --no-sort --filter=nomatch", .stdout = "one\ntwo\n" },
    .{ .name = "empty input", .script = ": | \"$1\" --filter=x", .stdout = "" },
    .{ .name = "blank records", .script = "printf '\\nalpha\\n\\n' | \"$1\" --no-sort --filter=''", .stdout = "\nalpha\n\n" },
};
const config_cases = [_]Case{
    .{ .name = "exit-0 no match status", .script = "printf 'one\\n' | \"$1\" --exit-0 --filter=zzz", .stdout = "", .exit_code = 1 },
    .{ .name = "unknown option fails", .script = "printf 'one\\n' | \"$1\" --definitely-invalid", .stdout = "", .exit_code = 1 },
    .{ .name = "invalid utf8 byte survives filter", .script = "printf 'bad\\377name\\nnormal\\n' | \"$1\" --filter=bad", .stdout = "bad\xffname\n" },
    .{ .name = "long-pattern fallback", .script = "q=$(printf '%1001s' '' | tr ' ' a); printf '%s\\n' \"$q\" | \"$1\" --filter=\"$q\" | awk '{ print length }'", .stdout = "1001\n" },
    .{
        .name = "default options precedence",
        .script = "D=.zig-cache/e2e-defaults-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf '# file defaults\\n--exact\\n--filter=alpha\\n' > \"$D/opts\"; printf 'alpha\\nbeta\\ngamma\\n' | FZF_DEFAULT_OPTS_FILE=\"$D/opts\" FZF_DEFAULT_OPTS='--no-exact --filter=beta' \"$1\" --filter=gamma",
        .stdout = "gamma\n",
    },
    .{
        .name = "default options file comments",
        .script = "D=.zig-cache/e2e-comments-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf '# comment\\n--exact # trailing\\n--filter=alpha\\n' > \"$D/opts\"; printf 'alpha\\naxlpxhxa\\n' | FZF_DEFAULT_OPTS_FILE=\"$D/opts\" \"$1\"",
        .stdout = "alpha\n",
    },
};
const interactive_cases = [_]Case{
    .{ .name = "pty default up", .script = "D=.zig-cache/e2e-up-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'one\\ntwo\\nthree\\n' > \"$D/in\"; { sleep .12; printf '\\033[A\\r'; } | timeout 3s script -qefc \"stty rows 12 cols 60; $1 --no-sort < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "two\n" },
    .{ .name = "pty reverse down", .script = "D=.zig-cache/e2e-rdown-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'one\\ntwo\\nthree\\n' > \"$D/in\"; { sleep .12; printf '\\033[B\\r'; } | timeout 3s script -qefc \"stty rows 12 cols 60; $1 --reverse --no-sort < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "two\n" },
    .{ .name = "pty ctrl-k", .script = "D=.zig-cache/e2e-ctrlk-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'one\\ntwo\\nthree\\n' > \"$D/in\"; { sleep .12; printf '\\013\\r'; } | timeout 3s script -qefc \"stty rows 12 cols 60; $1 --no-sort < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "two\n" },
    .{ .name = "pty binding chain", .script = "D=.zig-cache/e2e-bind-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'one\\ntwo\\nthree\\n' > \"$D/in\"; timeout 3s script -qefc \"stty rows 12 cols 60; $1 --no-sort --bind='load:last+accept' < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "three\n" },
    .{ .name = "pty expect key", .script = "D=.zig-cache/e2e-expect-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'one\\ntwo\\n' > \"$D/in\"; { sleep .12; printf '\\030'; } | timeout 3s script -qefc \"stty rows 12 cols 60; $1 --no-sort --expect=ctrl-x < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "ctrl-x\none\n" },
};
const interactive_input_cases = [_]Case{
    .{ .name = "pty bracketed paste", .script = "D=.zig-cache/e2e-paste-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'alpha\\nbeta\\ngamma\\n' > \"$D/in\"; { sleep .12; printf '\\033[200~ga\\033[201~\\r'; } | timeout 3s script -qefc \"stty rows 12 cols 60; $1 < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "gamma\n" },
    .{ .name = "pty tiny terminal", .script = "D=.zig-cache/e2e-tiny-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'alpha\\nbeta\\ngamma\\n' > \"$D/in\"; { sleep .12; printf '\\r'; } | timeout 3s script -qefc \"stty rows 2 cols 2; $1 --query=ga < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "gamma\n" },
    .{ .name = "pty live stream", .script = "D=.zig-cache/e2e-live-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; { sleep .45; printf '\\r'; } | timeout 4s script -qefc \"stty rows 12 cols 60; (printf 'alpha\\n'; sleep .2; printf 'gamma\\n') | $1 --query=ga > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "gamma\n" },
    .{ .name = "pty query typing", .script = "D=.zig-cache/e2e-type-$$; mkdir -p \"$D\"; trap 'rm -rf \"$D\"' EXIT; printf 'alpha\\nbeta\\ngamma\\n' > \"$D/in\"; { sleep .12; printf 'ga\\r'; } | timeout 3s script -qefc \"stty rows 12 cols 60; $1 < $D/in > $D/out\" /dev/null >/dev/null 2>&1; cat \"$D/out\"", .stdout = "gamma\n" },
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return error.MissingZfuzzBinary;
    var suite = Suite{ .allocator = allocator, .io = init.io, .bin = args[1] };
    try runCases(&suite, &basic_cases);
    try runCases(&suite, &io_cases);
    try runCases(&suite, &config_cases);
    if (builtin.os.tag == .linux) {
        try runCases(&suite, &interactive_cases);
        try runCases(&suite, &interactive_input_cases);
    }
    std.debug.print("E2E: {d} cases passed\n", .{suite.passed});
}
