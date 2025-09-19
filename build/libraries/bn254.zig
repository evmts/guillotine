const std = @import("std");
const Config = @import("../config.zig");

pub fn createBn254BuildStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rust_target: ?[]const u8,
) *std.Build.Step {
    const bn254_build = b.step("build-bn254-rust", "Build Rust bn254_wrapper library");
    
    const cargo_args = if (optimize == .Debug) 
        &[_][]const u8{ "cargo", "build", "--manifest-path", b.pathFromRoot("lib/ark/Cargo.toml") }
    else
        &[_][]const u8{ "cargo", "build", "--release", "--manifest-path", b.pathFromRoot("lib/ark/Cargo.toml") };
    
    const cargo_build = b.addSystemCommand(cargo_args);
    
    // Set environment variables for cross-compilation compatibility on x86_64 Linux
    if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) {
        cargo_build.setEnvironmentVariable("CC", "gcc");
        cargo_build.setEnvironmentVariable("CXX", "g++");
        cargo_build.setEnvironmentVariable("AR", "ar");
        cargo_build.setEnvironmentVariable("RUSTFLAGS", "-C target-feature=-crt-static");
    }

    if (rust_target) |target_triple| {
        cargo_build.addArg("--target");
        cargo_build.addArg(target_triple);
    }
    
    bn254_build.dependOn(&cargo_build.step);
    return bn254_build;
}

pub fn createBn254Library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: Config.BuildOptions,
    bn254_build_step: ?*std.Build.Step,
    rust_target: ?[]const u8,
) ?*std.Build.Step.Compile {
    if (config.no_bn254 or rust_target == null) return null;

    const lib = b.addLibrary(.{
        .name = "bn254_wrapper",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    const profile_dir = if (optimize == .Debug) "debug" else "release";
    const lib_path = if (rust_target) |target_triple|
        b.fmt("target/{s}/{s}/libbn254_wrapper.a", .{ target_triple, profile_dir })
    else
        b.fmt("target/{s}/libbn254_wrapper.a", .{profile_dir});

    lib.addObjectFile(b.path(lib_path));
    lib.linkLibC();
    lib.addIncludePath(b.path("lib/ark"));

    if (bn254_build_step) |build_step| {
        lib.step.dependOn(build_step);
    }

    return lib;
}