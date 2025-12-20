const std = @import("std");

pub fn createBn254Library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: anytype,
    workspace_build_step: ?*std.Build.Step,
    rust_target: ?[]const u8,
) ?*std.Build.Step.Compile {
    _ = config;

    if (rust_target == null) return null;

    const lib = b.addLibrary(.{
        .name = "bn254_wrapper",
        .use_llvm = true, // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    // Map Zig optimize modes to Rust profile directories
    const profile_dir = switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe, .ReleaseSmall => "release",
        .ReleaseFast => "release-fast",
    };
    const lib_path = if (rust_target) |target_triple|
        b.fmt("target/{s}/{s}/libbn254_wrapper.a", .{ target_triple, profile_dir })
    else
        b.fmt("target/{s}/libbn254_wrapper.a", .{profile_dir});

    lib.addObjectFile(b.path(lib_path));
    lib.linkLibC();
    lib.addIncludePath(b.path("lib/ark"));

    if (workspace_build_step) |build_step| {
        lib.step.dependOn(build_step);
    }

    return lib;
}