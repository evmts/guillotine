const std = @import("std");

pub fn createEvmRunner(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    c_kzg_lib: *std.Build.Step.Compile,
    blst_lib: *std.Build.Step.Compile,
    bn254_lib: ?*std.Build.Step.Compile,
    clap_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "evm-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });

    exe.root_module.addImport("evm", evm_mod);
    exe.root_module.addImport("voltaire", primitives_mod);
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    exe.linkLibrary(c_kzg_lib);
    exe.linkLibrary(blst_lib);
    exe.linkLibC();

    if (bn254_lib) |bn254| {
        exe.linkLibrary(bn254);
        exe.addIncludePath(b.path("lib/ark"));
    }

    b.installArtifact(exe);
    return exe;
}

pub fn createDebugRunner(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
) ?*std.Build.Step.Compile {
    // Check if debug runner exists
    std.fs.cwd().access("bench/evms/zig/src/debug.zig", .{}) catch return null;

    const exe = b.addExecutable(.{
        .name = "debug-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/debug.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });

    exe.root_module.addImport("evm", evm_mod);
    exe.root_module.addImport("voltaire", primitives_mod);

    b.installArtifact(exe);
    return exe;
}

pub fn createCrashDebugger(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
) ?*std.Build.Step.Compile {
    // Check if crash debugger exists
    std.fs.cwd().access("bench/evms/zig/src/crash_debugger.zig", .{}) catch return null;

    const exe = b.addExecutable(.{
        .name = "crash-debugger",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/crash_debugger.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });

    exe.root_module.addImport("evm", evm_mod);
    exe.root_module.addImport("voltaire", primitives_mod);

    b.installArtifact(exe);
    return exe;
}

pub fn createBytecodeRunner(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    provider_mod: *std.Build.Module,
    trie_mod: *std.Build.Module,
    build_options_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "bytecode-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/evms/zig/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });

    exe.root_module.addImport("evm", evm_mod);
    exe.root_module.addImport("voltaire", primitives_mod);
    exe.root_module.addImport("crypto", crypto_mod);
    exe.root_module.addImport("provider", provider_mod);
    exe.root_module.addImport("trie", trie_mod);
    exe.root_module.addImport("build_options", build_options_mod);

    b.installArtifact(exe);
    return exe;
}

pub fn createSnailTracer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    provider_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    trie_mod: *std.Build.Module,
) ?*std.Build.Step.Compile {
    // Check if snail tracer exists
    std.fs.cwd().access("bench/snailtracer/src/main.zig", .{}) catch return null;

    const exe = b.addExecutable(.{
        .name = "snailtracer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/snailtracer/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });

    exe.root_module.addImport("evm", evm_mod);
    exe.root_module.addImport("voltaire", primitives_mod);
    exe.root_module.addImport("crypto", crypto_mod);
    exe.root_module.addImport("provider", provider_mod);
    exe.root_module.addImport("trie", trie_mod);

    b.installArtifact(exe);
    return exe;
}

pub fn createTestSteps(
    b: *std.Build,
    executables: struct {
        crash_debugger: ?*std.Build.Step.Compile,
        bytecode_runner: *std.Build.Step.Compile,
        snailtracer: ?*std.Build.Step.Compile,
    },
) void {
    // Create crash-debug step if available
    if (executables.crash_debugger) |exe| {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("crash-debug", "Debug a crash");
        run_step.dependOn(&run_cmd.step);
    }

    // Create bytecode-runner step
    {
        const run_cmd = b.addRunArtifact(executables.bytecode_runner);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("bytecode-runner", "Run the bytecode runner");
        run_step.dependOn(&run_cmd.step);
    }

    // Create test-snailtracer step if available
    if (executables.snailtracer) |exe| {
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        const test_step = b.step("test-snailtracer", "Run snailtracer differential test");
        test_step.dependOn(&run.step);
    }
}