const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fuzzy_module = b.addModule("fuzzy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine", .module = engine_module }},
    });

    const exe = b.addExecutable(.{
        .name = "zfuzz",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fuzzy", .module = fuzzy_module },
                .{ .name = "engine", .module = engine_module },
            },
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);
    b.installFile("src/shell/zfuzz.bash", "share/zfuzz/zfuzz.bash");
    b.installFile("src/shell/zfuzz.zsh", "share/zfuzz/zfuzz.zsh");
    b.installFile("src/shell/zfuzz.fish", "share/zfuzz/zfuzz.fish");

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run zfuzz");
    run_step.dependOn(&run_exe.step);

    const cli_unit_tests = b.addTest(.{
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fuzzy", .module = fuzzy_module },
                .{ .name = "engine", .module = engine_module },
            },
            .link_libc = true,
        }),
    });
    const run_cli_unit_tests = b.addRunArtifact(cli_unit_tests);

    const engine_unit_tests = b.addTest(.{
        .root_module = engine_module,
    });
    const run_engine_unit_tests = b.addRunArtifact(engine_unit_tests);

    const lib_unit_tests = b.addTest(.{
        .root_module = fuzzy_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const e2e = b.addExecutable(.{
        .name = "zfuzz-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.addArtifactArg(exe);
    run_e2e.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_engine_unit_tests.step);
    test_step.dependOn(&run_cli_unit_tests.step);
    test_step.dependOn(&run_e2e.step);
}
