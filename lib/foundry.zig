const std = @import("std");

pub fn createFoundryLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rust_build_step: ?*std.Build.Step,
    rust_target: ?[]const u8,
) ?*std.Build.Step.Compile {
    // Check if the Rust source exists
    b.root.access(b.graph.io, "lib/foundry-compilers/src/lib.rs", .{}) catch |err| {
        if (err != error.FileNotFound) std.debug.panic("unable to access foundry-compilers source: {s}", .{@errorName(err)});
        std.debug.print("Warning: foundry-compilers Rust source not found, skipping\n", .{});
        return null;
    };

    // Create a static library wrapper for Zig
    const foundry_lib = b.addLibrary(.{
        .name = "foundry_wrapper",
        .linkage = .static,
        .use_llvm = true, // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .root_module = b.createModule(.{
            .root_source_file = null, // No Zig source, just linking Rust lib
            .target = target,
            .optimize = optimize,
        }),
    });

    // Determine the correct path based on target and optimize mode
    const profile_dir = switch (optimize) {
        .debug => "debug",
        .safe, .small => "release",
        .fast => "release-fast",
    };
    // Cargo writes to CARGO_TARGET_DIR when set, so link from the same place.
    const cargo_target_dir = b.graph.environ_map.get("CARGO_TARGET_DIR");
    const target_root = cargo_target_dir orelse "target";
    const rust_target_dir = if (rust_target) |target_triple|
        b.fmt("{s}/{s}/{s}", .{ target_root, target_triple, profile_dir })
    else
        b.fmt("{s}/{s}", .{ target_root, profile_dir });

    // Add the Rust static library
    const archive = b.fmt("{s}/libfoundry_wrapper.a", .{rust_target_dir});
    foundry_lib.root_module.addObjectFile(if (cargo_target_dir != null) .{ .cwd_relative = archive } else b.path(archive));
    foundry_lib.root_module.addIncludePath(b.path("lib/foundry-compilers"));

    // Link necessary system libraries
    foundry_lib.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        // Zig 0.15.1's LLD archiver nests the Rust archive as a single member
        // (#815). The native ELF archiver merges its object members instead.
        foundry_lib.use_lld = false;
        foundry_lib.root_module.linkSystemLibrary("m", .{});
        foundry_lib.root_module.linkSystemLibrary("pthread", .{});
        foundry_lib.root_module.linkSystemLibrary("dl", .{});
    } else if (target.result.os.tag == .macos) {
        foundry_lib.root_module.linkSystemLibrary("c++", .{});
        foundry_lib.root_module.linkFramework("Security", .{});
        foundry_lib.root_module.linkFramework("SystemConfiguration", .{});
        foundry_lib.root_module.linkFramework("CoreFoundation", .{});
    }

    // The rust_build_step should handle the workspace build
    // We just need to depend on it, not create our own cargo build
    if (rust_build_step) |step| {
        foundry_lib.step.dependOn(step);
    } else {
        // If no rust_build_step provided, create our own
        const cargo_build = b.addSystemCommand(&.{
            "cargo",
            "build",
            "--release",
            "--workspace",
        });

        if (rust_target) |target_triple| {
            cargo_build.addArg("--target");
            cargo_build.addArg(target_triple);
        }

        foundry_lib.step.dependOn(&cargo_build.step);
    }

    return foundry_lib;
}

pub fn createRustBuildStep(b: *std.Build, rust_target: ?[]const u8, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const rust_build = b.step("build-rust-workspace", "Build Rust workspace libraries");

    const cargo_build = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--workspace",
    });

    // Map Zig optimize modes to Rust build profiles
    switch (optimize) {
        .debug => {}, // cargo build without --release is debug
        .safe => {
            cargo_build.addArg("--release");
        },
        .fast => {
            cargo_build.addArg("--profile");
            cargo_build.addArg("release-fast");
        },
        .small => {
            cargo_build.addArg("--release");
            // Set environment variable to optimize for size
            cargo_build.setEnvironmentVariable("CARGO_PROFILE_RELEASE_OPT_LEVEL", "z");
            cargo_build.setEnvironmentVariable("CARGO_PROFILE_RELEASE_LTO", "true");
            cargo_build.setEnvironmentVariable("CARGO_PROFILE_RELEASE_CODEGEN_UNITS", "1");
        },
    }

    if (rust_target) |target_triple| {
        cargo_build.addArg("--target");
        cargo_build.addArg(target_triple);
    }

    rust_build.dependOn(&cargo_build.step);
    return rust_build;
}
