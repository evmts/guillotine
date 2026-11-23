const std = @import("std");

pub fn createBlstLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const is_wasm = target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64;

    // Build blst library
    const lib = b.addLibrary(.{
        .name = "blst",
        .linkage = .static,
        .use_llvm = true, // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.linkLibC();

    // For native targets, assemble the checked-in assembly.S directly with Zig
    // (avoiding ./build.sh which mutates the source tree and races under parallel builds).
    // For WASM, use portable C-only implementation.
    if (!is_wasm) {
        lib.addAssemblyFile(b.path("lib/c-kzg-4844/blst/build/assembly.S"));
    }

    // Add blst source files with portable flag
    // For WASM, __BLST_PORTABLE__ ensures pure C implementation without assembly
    // For native, __BLST_PORTABLE__ provides fallback while assembly is optimized path
    const c_flags = if (is_wasm)
        &[_][]const u8{ "-std=c99", "-D__BLST_PORTABLE__", "-D__BLST_NO_ASM__", "-fno-sanitize=undefined" }
    else
        &[_][]const u8{ "-std=c99", "-D__BLST_PORTABLE__", "-fno-sanitize=undefined" };

    lib.addCSourceFiles(.{
        .files = &.{
            "lib/c-kzg-4844/blst/src/server.c",
        },
        .flags = c_flags,
    });

    lib.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));

    return lib;
}
