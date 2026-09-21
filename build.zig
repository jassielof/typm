const std = @import("std");

const fangz_build = @import("fangz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fangz = b.dependency(
        "fangz",
        .{ .target = target, .optimize = optimize },
    ).module("fangz");

    const toml = b.dependency(
        "toml",
        .{ .target = target, .optimize = optimize },
    ).module("toml");

    const fugaz = b.dependency(
        "fugaz",
        .{ .target = target, .optimize = optimize },
    ).module("fugaz");

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fangz", .module = fangz },
            .{ .name = "toml", .module = toml },
            .{ .name = "fugaz", .module = fugaz },
        },
    });

    const exe = b.addExecutable(.{
        .name = "typm",
        .root_module = cli_mod,
    });

    fangz_build.injectMetadata(
        b,
        exe,
        fangz,
    );

    b.installArtifact(exe);

    const cli_step = b.step("cli", "Run the CLI");

    const run_cli = b.addRunArtifact(exe);
    cli_step.dependOn(&run_cli.step);

    run_cli.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cli.addArgs(args);
    }

    const tests_step = b.step("test", "Run the test suite");

    const unit_tests = b.addTest(.{
        .root_module = cli_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    tests_step.dependOn(&run_unit_tests.step);
}
