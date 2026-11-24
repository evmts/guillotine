const std = @import("std");

// Supplemental MODEXP test and benchmark targets used by CI and the Smithers
// test-modexp/bench targets. They predate the root build's own test-modexp and
// bench steps and cover only lib/voltaire/src/crypto/modexp.zig. All commands
// still run from the repository root.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const voltaire = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "lib/voltaire/src/primitives/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    const modexp = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "lib/voltaire/src/crypto/modexp.zig" },
        .target = target,
        .optimize = optimize,
    });
    modexp.addImport("voltaire", voltaire);
    const tests = b.addTest(.{ .root_module = modexp, .use_llvm = true });
    const run = b.addRunArtifact(tests);
    const step = b.step("test-modexp", "Run repository MODEXP arithmetic and EIP-198 gas tests");
    step.dependOn(&run.step);

    const bench = b.addExecutable(.{
        .name = "guillotine-modexp-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    bench.root_module.addImport("modexp", modexp);
    b.installArtifact(bench);
    const timing = b.step("bench", "Measure repository MODEXP throughput");
    timing.dependOn(&b.addRunArtifact(bench).step);
}
