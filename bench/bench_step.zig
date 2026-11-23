const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    evm: *std.Build.Module,
    loop_evm: ?*std.Build.Module = null,
    native_archive: ?std.Build.LazyPath = null,
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
    hardfork: []const u8 = "OSAKA",
    gas_limit: ?u64 = null,
    directory: ?std.Build.LazyPath = null,
    repository: ?std.Build.LazyPath = null,
};

pub const Steps = struct {
    exe: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
    bench: *std.Build.Step,
    tests: *std.Build.Step,
};

/// Add `bench`, `bench-build`, and `test-bench` without modifying shared modules.
/// Copy the supplied EVM import graph into the requested optimization mode,
/// retaining native links and providing the benchmark crypto archive.
pub fn addBenchSteps(b: *std.Build, options: Options) Steps {
    const directory = options.directory orelse b.path("bench");
    const repository = options.repository orelse b.path(".");
    const archive = options.native_archive orelse nativeArchive(b, directory, repository, options.target);
    const config = b.addOptions();
    config.addOption([]const u8, "hardfork", options.hardfork);
    const capped = std.mem.eql(u8, options.hardfork, "OSAKA") or std.mem.eql(u8, options.hardfork, "AMSTERDAM");
    const gas: u64 = options.gas_limit orelse if (capped) @as(u64, 16_777_216) else 1_000_000_000;
    if (gas == 0 or (capped and gas > 16_777_216)) @panic("invalid benchmark gas budget (Osaka+ cap is 16777216)");
    config.addOption(u64, "gas_limit", gas);
    config.addOption(bool, "loop_available", options.loop_evm != null);
    config.addOption([]const u8, "fixture_directory", repository.path(b, "fixtures").getPath(b));
    const module = b.createModule(.{
        .root_source_file = directory.path(b, "main.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    var copies: std.AutoHashMap(*std.Build.Module, *std.Build.Module) = .init(b.allocator);
    defer copies.deinit();
    const evm = optimized(b, options.evm, options.optimize, archive, &copies);
    module.addImport("guillotine", evm);
    module.addImport("guillotine_loop", if (options.loop_evm) |loop| optimized(b, loop, options.optimize, archive, &copies) else evm);
    module.addImport("bench_options", config.createModule());
    const exe = b.addExecutable(.{ .name = "guillotine-bench", .root_module = module, .use_llvm = true });
    exe.linkLibC();
    if (options.target.result.os.tag == .linux) exe.linkSystemLibrary("unwind");
    const run = b.addRunArtifact(exe);
    run.setCwd(repository);
    run.has_side_effects = true;
    if (b.args) |args| run.addArgs(args);
    const bench = b.step("bench", "Run self-contained EVM benchmarks (ReleaseFast)");
    bench.dependOn(&run.step);
    const compile = b.step("bench-build", "Build the standalone EVM benchmark runner");
    compile.dependOn(&b.addInstallArtifact(exe, .{}).step);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = directory.path(b, "tests.zig"), .target = options.target, .optimize = .Debug }),
        .use_llvm = true,
    });
    const test_step = b.step("test-bench", "Check benchmark statistics, CLI, and workload construction");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    return .{ .exe = exe, .run = run, .bench = bench, .tests = test_step };
}

// Copy the import graph with memoization (Voltaire/crypto have a cycle).
// Keep include paths, native link objects and generated-file dependencies;
// change optimization without mutating modules shared with tests or SDKs.
fn optimized(b: *std.Build, source: *std.Build.Module, mode: std.builtin.OptimizeMode, archive: ?std.Build.LazyPath, copies: *std.AutoHashMap(*std.Build.Module, *std.Build.Module)) *std.Build.Module {
    if (copies.get(source)) |copy| return copy;
    const copy = b.allocator.create(std.Build.Module) catch @panic("out of memory creating benchmark module");
    copy.* = source.*;
    copy.optimize = mode;
    if (archive) |replacement| {
        copy.link_objects = source.link_objects.clone(b.allocator) catch @panic("out of memory copying benchmark links");
        for (copy.link_objects.items) |*object| {
            switch (object.*) {
                .static_path => |path| if (std.mem.endsWith(u8, path.getPath(b), "libcrypto_wrappers.a")) {
                    object.* = .{ .static_path = replacement };
                },
                else => {},
            }
        }
    }
    copy.import_table = .{};
    copy.cached_graph = .{ .modules = &.{}, .names = &.{} };
    copies.put(source, copy) catch @panic("out of memory recording benchmark module");
    var imports = source.import_table.iterator();
    while (imports.next()) |entry| copy.addImport(entry.key_ptr.*, optimized(b, entry.value_ptr.*, mode, archive, copies));
    return copy;
}

/// Own the crypto producer here so the three-line root integration does not
/// inherit Voltaire's missing-archive dependency. A caller can instead supply
/// an already-produced native_archive (including for cross compilation).
fn nativeArchive(b: *std.Build, directory: std.Build.LazyPath, repository: std.Build.LazyPath, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    if (!target.query.isNativeOs() or !target.query.isNativeAbi()) @panic("supply a target-specific native_archive for cross-compiled benchmarks");
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--locked", "--manifest-path" });
    cargo.addFileArg(directory.path(b, "native/Cargo.toml"));
    cargo.addFileInput(directory.path(b, "native/Cargo.lock"));
    for ([_][]const u8{ "lib.rs", "bn254_wrapper.rs", "keccak_wrapper.rs" }) |file|
        cargo.addFileInput(repository.path(b, b.fmt("lib/voltaire/src/crypto/{s}", .{file})));
    const archive = cargo.addPrefixedOutputDirectoryArg("--target-dir=", "crypto");
    return archive.path(b, "release/libcrypto_wrappers.a");
}
