const std = @import("std");

pub fn createCKzgLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    blst_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    // Build c-kzg-4844 from source
    const lib = b.addLibrary(.{
        .name = "c-kzg-4844",
        .linkage = .static,
        .use_llvm = true, // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.root_module.link_libc = true;
    lib.root_module.linkLibrary(blst_lib);

    lib.root_module.addCSourceFiles(.{
        .files = &.{
            "lib/c-kzg-4844/src/ckzg.c",
        },
        .flags = &.{"-std=c99", "-fno-sanitize=undefined"},
    });

    lib.root_module.addIncludePath(b.path("lib/c-kzg-4844/src"));
    lib.root_module.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));

    return lib;
}