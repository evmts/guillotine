const std = @import("std");
const wasm = @import("../steps/wasm.zig");

pub fn createWasmSteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
) void {
    const wasm_target = wasm.setupWasmTarget(b);
    const wasm_optimize = optimize;

    const wasm_primitives_mod = wasm.createWasmModule(b, "src/primitives/root.zig", wasm_target, wasm_optimize);

    const wasm_crypto_mod = wasm.createWasmModule(b, "src/crypto/root.zig", wasm_target, wasm_optimize);
    // crypto - primitives dependency is circular as in main build
    wasm_crypto_mod.addImport("primitives", wasm_primitives_mod);
    wasm_crypto_mod.addImport("build_options", build_options_mod);
    wasm_primitives_mod.addImport("crypto", wasm_crypto_mod);

    // Build the EVM library module (needed by C API)
    const wasm_evm_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, wasm_optimize);
    wasm_evm_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_mod.addImport("build_options", build_options_mod);

    // Build the C API module that exports functions for WASM
    // Using evm_c.zig which has WASM-specific allocator support
    const wasm_c_api_mod = wasm.createWasmModule(b, "src/evm_c.zig", wasm_target, wasm_optimize);
    wasm_c_api_mod.addImport("primitives", wasm_primitives_mod);
    wasm_c_api_mod.addImport("evm", wasm_evm_mod);

    const wasm_lib_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine",
        .root_source_file = "src/evm_c.zig",
        .dest_sub_path = "guillotine.wasm",
    }, wasm_c_api_mod);

    const wasm_size_step = wasm.addWasmSizeReportStep(
        b,
        &[_][]const u8{"guillotine.wasm"},
        &[_]*std.Build.Step{
            &wasm_lib_build.install.step,
        },
    );

    const wasm_step = b.step("wasm", "Build WASM library and show bundle size");
    wasm_step.dependOn(&wasm_size_step.step);

    // Debug builds need the same module structure
    const wasm_evm_debug_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, .Debug);
    wasm_evm_debug_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_debug_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_debug_mod.addImport("build_options", build_options_mod);

    const wasm_debug_mod = wasm.createWasmModule(b, "src/evm_c.zig", wasm_target, .Debug);
    wasm_debug_mod.addImport("primitives", wasm_primitives_mod);
    wasm_debug_mod.addImport("evm", wasm_evm_debug_mod);

    const wasm_debug_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-debug",
        .root_source_file = "src/evm_c.zig",
        .dest_sub_path = "../bin/guillotine-debug.wasm",
        .debug_build = true,
    }, wasm_debug_mod);

    const wasm_debug_step = b.step("wasm-debug", "Build debug WASM for analysis");
    wasm_debug_step.dependOn(&wasm_debug_build.install.step);

    // MinimalEvm WASM build
    {
        // Create MinimalEvm module with ReleaseSmall optimization
        const wasm_minimal_evm_mod = wasm.createWasmModule(b, "src/tracer/minimal_evm_c.zig", wasm_target, .ReleaseSmall);
        wasm_minimal_evm_mod.addImport("primitives", wasm_primitives_mod);

        const wasm_minimal_evm_build = wasm.buildWasmExecutable(b, .{
            .name = "minimal-evm",
            .root_source_file = "src/tracer/minimal_evm_c.zig",
            .dest_sub_path = "minimal-evm.wasm",
        }, wasm_minimal_evm_mod);

        const wasm_minimal_evm_size = wasm.addWasmSizeReportStep(
            b,
            &[_][]const u8{"minimal-evm.wasm"},
            &[_]*std.Build.Step{
                &wasm_minimal_evm_build.install.step,
            },
        );

        const wasm_minimal_evm_step = b.step("wasm-minimal-evm", "Build MinimalEvm WASM and show bundle size");
        wasm_minimal_evm_step.dependOn(&wasm_minimal_evm_size.step);
    }
}