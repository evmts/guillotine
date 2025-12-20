const std = @import("std");

pub fn createWasmSteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
) *std.Build.Step {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize = optimize;

    const wasm_primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .single_threaded = true,
    });

    const wasm_crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .single_threaded = true,
    });
    // crypto - primitives dependency is circular as in main build
    wasm_crypto_mod.addImport("voltaire", wasm_primitives_mod);
    wasm_crypto_mod.addImport("build_options", build_options_mod);
    wasm_primitives_mod.addImport("crypto", wasm_crypto_mod);

    // Build the EVM library module (needed by C API)
    const wasm_evm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .single_threaded = true,
    });
    wasm_evm_mod.addImport("voltaire", wasm_primitives_mod);
    wasm_evm_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_mod.addImport("build_options", build_options_mod);

    // Build the C API module that exports functions for WASM
    // Using evm_c.zig which has WASM-specific allocator support
    const wasm_c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/evm_c.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .single_threaded = true,
    });
    wasm_c_api_mod.addImport("voltaire", wasm_primitives_mod);
    wasm_c_api_mod.addImport("evm", wasm_evm_mod);

    const wasm_lib = b.addExecutable(.{
        .name = "guillotine",
        .root_module = wasm_c_api_mod,
        .use_llvm = true, // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
    });
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{ .dest_sub_path = "guillotine.wasm" });

    const wasm_size_step = addWasmSizeReport(b, &[_][]const u8{"guillotine.wasm"}, &[_]*std.Build.Step{&wasm_install.step});

    const wasm_step = b.step("wasm", "Build WASM library and show bundle size");
    wasm_step.dependOn(&wasm_size_step.step);

    // Debug builds need the same module structure
    const wasm_evm_debug_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .Debug,
        .single_threaded = true,
    });
    wasm_evm_debug_mod.addImport("voltaire", wasm_primitives_mod);
    wasm_evm_debug_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_debug_mod.addImport("build_options", build_options_mod);

    const wasm_lib_debug = b.addExecutable(.{
        .name = "guillotine-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm_c.zig"),
            .target = wasm_target,
            .optimize = .Debug,
            .single_threaded = true,
        }),
        .use_llvm = true,
    });
    wasm_lib_debug.root_module.addImport("voltaire", wasm_primitives_mod);
    wasm_lib_debug.root_module.addImport("evm", wasm_evm_debug_mod);
    wasm_lib_debug.entry = .disabled;
    wasm_lib_debug.rdynamic = true;

    const wasm_debug_install = b.addInstallArtifact(wasm_lib_debug, .{ .dest_sub_path = "guillotine-debug.wasm" });

    const wasm_debug_size = addWasmSizeReport(b, &[_][]const u8{"guillotine-debug.wasm"}, &[_]*std.Build.Step{&wasm_debug_install.step});

    const wasm_debug_step = b.step("wasm-debug", "Build debug WASM for analysis");
    wasm_debug_step.dependOn(&wasm_debug_size.step);

    // MinimalEvm WASM build
    createMinimalEvmWasm(b, wasm_target, build_options_mod);

    // Return the main wasm build step
    return wasm_step;
}

fn addWasmSizeReport(
    b: *std.Build,
    wasm_files: []const []const u8,
    dependencies: []const *std.Build.Step,
) *std.Build.Step.Run {
    var cmd = std.ArrayList([]const u8).empty;
    cmd.append(b.allocator, "sh") catch @panic("OOM");
    cmd.append(b.allocator, "-c") catch @panic("OOM");

    var script = std.ArrayList(u8).empty;
    script.appendSlice(b.allocator, "echo '\n=== WASM Bundle Size Report ===' && ") catch @panic("OOM");

    for (wasm_files) |file| {
        const name = std.fs.path.stem(file);
        const seg1 = std.fmt.allocPrint(b.allocator, "echo '{s} WASM build:' && ", .{name}) catch @panic("OOM");
        defer b.allocator.free(seg1);
        script.appendSlice(b.allocator, seg1) catch @panic("OOM");
        const seg2 = std.fmt.allocPrint(b.allocator, "ls -lh zig-out/bin/{s} | awk '{{print \"  Size: \" $5}}' && ", .{file}) catch @panic("OOM");
        defer b.allocator.free(seg2);
        script.appendSlice(b.allocator, seg2) catch @panic("OOM");
    }

    script.appendSlice(b.allocator, "echo ''") catch @panic("OOM");

    const script_str = script.toOwnedSlice(b.allocator) catch @panic("OOM");
    defer b.allocator.free(script_str);
    cmd.append(b.allocator, script_str) catch @panic("OOM");

    const size_step = b.addSystemCommand(cmd.items);
    for (dependencies) |dep| {
        size_step.step.dependOn(dep);
    }

    return size_step;
}

pub fn createMinimalEvmWasm(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    build_options_mod: *std.Build.Module,
) void {
    const wasm_primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
    });

    const wasm_crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
    });
    wasm_crypto_mod.addImport("voltaire", wasm_primitives_mod);
    wasm_crypto_mod.addImport("build_options", build_options_mod);
    wasm_primitives_mod.addImport("crypto", wasm_crypto_mod);

    // Create the C API wrapper module
    const tracer_c_mod = b.createModule(.{
        .root_source_file = b.path("src/tracer/MinimalEvm_c.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
    });
    tracer_c_mod.addImport("voltaire", wasm_primitives_mod);
    tracer_c_mod.addImport("crypto", wasm_crypto_mod);

    // Build the MinimalEvm WASM binary
    const minimal_evm_wasm = b.addExecutable(.{
        .name = "minimal-evm",
        .root_module = tracer_c_mod,
        .use_llvm = true,
    });
    minimal_evm_wasm.entry = .disabled;
    minimal_evm_wasm.rdynamic = true;

    const minimal_install = b.addInstallArtifact(minimal_evm_wasm, .{ .dest_sub_path = "minimal-evm.wasm" });

    const minimal_size = addWasmSizeReport(b, &[_][]const u8{"minimal-evm.wasm"}, &[_]*std.Build.Step{&minimal_install.step});

    const minimal_step = b.step("wasm-minimal-evm", "Build MinimalEvm WASM and show bundle size");
    minimal_step.dependOn(&minimal_size.step);
}