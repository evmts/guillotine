const std = @import("std");

pub fn createBlstLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    // Build blst assembly first
    const blst_build_cmd = b.addSystemCommand(&.{
        "sh", "-c", "cd lib/c-kzg-4844/blst && ./build.sh",
    });

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

    lib.root_module.link_libc = true;
    lib.step.dependOn(&blst_build_cmd.step);

    // Add blst source files
    lib.root_module.addCSourceFiles(.{
        .files = &.{
            "lib/c-kzg-4844/blst/src/server.c",
        },
        .flags = &.{"-std=c99", "-D__BLST_PORTABLE__", "-fno-sanitize=undefined"},
    });

    lib.root_module.addAssemblyFile(b.path("lib/c-kzg-4844/blst/build/assembly.S"));
    lib.root_module.addIncludePath(b.path("lib/c-kzg-4844/blst/bindings"));

    return lib;
}