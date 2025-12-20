const std = @import("std");

pub fn createBlstLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    // Build blst library - using portable C implementation
    // Note: We define __uint128_t to work around a blst bug where llimb_t is not defined for 64-bit platforms
    // server.c is a unity build that includes all other .c files including vect.c
    // We define both __BLST_NO_ASM__ and __BLST_PORTABLE__ to ensure the C implementation is used everywhere
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

    // Add blst source files (using portable mode without assembly)
    lib.addCSourceFiles(.{
        .files = &.{
            "lib/c-kzg-4844/blst/src/server.c",
        },
        .flags = &.{"-std=c99", "-D__BLST_NO_ASM__", "-D__BLST_PORTABLE__", "-Dllimb_t=__uint128_t", "-fno-sanitize=undefined", "-Wno-unused-command-line-argument"},
    });

    lib.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));

    return lib;
}