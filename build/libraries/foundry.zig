const std = @import("std");

pub fn createFoundryLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rust_build_step: ?*std.Build.Step,
    rust_target: ?[]const u8,
) ?*std.Build.Step.Compile {
    // Check if the Rust source exists
    std.fs.cwd().access("lib/foundry-compilers/src/lib.rs", .{}) catch {
        std.debug.print("Warning: foundry-compilers Rust source not found, skipping\n", .{});
        return null;
    };

    // Build the Rust static library
    const cargo_build = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        b.pathFromRoot("lib/foundry-compilers/Cargo.toml"),
    });

    if (rust_target) |target_triple| {
        cargo_build.addArg("--target");
        cargo_build.addArg(target_triple);
    }

    if (rust_build_step) |step| {
        cargo_build.step.dependOn(step);
    }

    // Generate C bindings using the build.rs script (happens automatically with cargo build)
    // The build.rs will generate foundry_wrapper.h

    // Create a static library wrapper for Zig
    const foundry_lib = b.addLibrary(.{
        .name = "foundry_wrapper",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = null, // No Zig source, just linking Rust lib
            .target = target,
            .optimize = optimize,
        }),
    });

    // Determine the correct path based on target
    const rust_target_dir = if (rust_target) |target_triple|
        b.fmt("target/{s}/release", .{target_triple})
    else
        "target/release";

    // Add the Rust static library
    foundry_lib.addObjectFile(b.path(b.fmt("{s}/libfoundry_wrapper.a", .{rust_target_dir})));
    foundry_lib.addIncludePath(b.path("lib/foundry-compilers"));

    // Link necessary system libraries
    foundry_lib.linkLibC();
    if (target.result.os.tag == .linux) {
        foundry_lib.linkSystemLibrary("m");
        foundry_lib.linkSystemLibrary("pthread");
        foundry_lib.linkSystemLibrary("dl");
    } else if (target.result.os.tag == .macos) {
        foundry_lib.linkSystemLibrary("c++");
        foundry_lib.linkFramework("Security");
        foundry_lib.linkFramework("SystemConfiguration");
        foundry_lib.linkFramework("CoreFoundation");
    }

    foundry_lib.step.dependOn(&cargo_build.step);

    return foundry_lib;
}

pub fn createRustBuildStep(b: *std.Build) *std.Build.Step {
    const rust_build = b.step("build-foundry-rust", "Build Rust foundry-compilers library");
    
    const cargo_build = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        b.pathFromRoot("lib/foundry-compilers/Cargo.toml"),
    });
    
    rust_build.dependOn(&cargo_build.step);
    return rust_build;
}