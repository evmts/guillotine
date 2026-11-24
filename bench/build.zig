//! Standalone entry point, invoked from the repository root:
//! zig build --build-file bench/build.zig bench -- --filter ADD
const std = @import("std");
const steps = @import("bench_step.zig");
const suites = @import("suites_build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Runner optimization (default ReleaseFast)") orelse .ReleaseFast;
    if (!target.query.isNative()) @panic("standalone benchmarks require a native target");
    const hardfork = b.option([]const u8, "bench-hardfork", "Benchmark fork (default OSAKA)") orelse "OSAKA";
    const root = b.dependency("guillotine", .{ .target = target, .optimize = optimize });
    const voltaire = root.builder.dependency("voltaire", .{ .target = target, .optimize = optimize });
    const flags = b.addOptions();
    flags.addOption(bool, "enable_tracing", false);
    flags.addOption(bool, "disable_tailcall_dispatch", false);
    flags.addOption(bool, "disable_gas_checks", false);
    flags.addOption(bool, "enable_fusion", true);
    flags.addOption([]const u8, "hardfork", "OSAKA");
    const flags_mod = flags.createModule();
    const evm = b.createModule(.{
        .root_source_file = root.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm.addImport("build_options", flags_mod);
    const limits = root.module("evm_limits");
    evm.addImport("evm_limits", limits);
    evm.addImport("voltaire", voltaire.module("voltaire"));
    evm.addImport("crypto", voltaire.module("crypto"));
    evm.addImport("precompiles", voltaire.module("precompiles"));
    const provider = b.createModule(.{ .root_source_file = root.path("src/provider/root.zig"), .target = target, .optimize = optimize });
    provider.addImport("voltaire", voltaire.module("voltaire"));
    evm.addImport("provider", provider);
    const archive = steps.nativeArchive(b, b.path("."), root.path("."), target);
    _ = steps.addBenchSteps(b, .{
        .target = target,
        .evm = evm,
        .native_archive = archive,
        .directory = b.path("."),
        .repository = root.path("."),
        .optimize = optimize,
        .hardfork = hardfork,
        .gas_limit = b.option(u64, "bench-gas-limit", "Execution gas budget (Osaka+ <= 16777216)"),
    });
    var copies: std.AutoHashMap(*std.Build.Module, *std.Build.Module) = .init(b.allocator);
    defer copies.deinit();
    const opt_evm = steps.optimized(b, evm, optimize, archive, &copies);
    const opt_voltaire = steps.optimized(b, voltaire.module("voltaire"), optimize, archive, &copies);
    const opt_crypto = steps.optimized(b, voltaire.module("crypto"), optimize, archive, &copies);
    const opt_precompiles = steps.optimized(b, voltaire.module("precompiles"), optimize, archive, &copies);
    suites.addSuiteSteps(b, .{
        .limits = limits,
        .target = target,
        .optimize = optimize,
        .directory = b.path("."),
        .repository = root.path("."),
        .evm = opt_evm,
        .voltaire = opt_voltaire,
        .crypto = opt_crypto,
        .precompiles = opt_precompiles,
        .build_options = flags_mod,
        .native_archive = archive,
    });
}
