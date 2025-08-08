const std = @import("std");

pub const RustConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    no_bn254: bool,
};

pub const RustLibraries = struct {
    bn254_lib: ?*std.Build.Step.Compile,
    revm_lib: ?*std.Build.Step.Compile,
    workspace_build_step: ?*std.Build.Step.Run,
};

pub fn setupRustIntegration(b: *std.Build, config: RustConfig) RustLibraries {
    // Determine the Rust target triple based on the Zig target
    const rust_target = getRustTarget(config.target);

    // Single workspace build command that builds all Rust crates at once
    const workspace_build_step = if (rust_target != null) blk: {
        const rust_cmd = b.addSystemCommand(&[_][]const u8{
            "cargo",     "build",
            "--profile", if (config.optimize == .Debug) "dev" else "release",
        });
        if (rust_target) |target_triple| {
            rust_cmd.addArgs(&[_][]const u8{ "--target", target_triple });
        }
        break :blk rust_cmd;
    } else null;

    // Create BN254 library that depends on workspace build
    const bn254_lib = if (!config.no_bn254 and rust_target != null) blk: {
        const lib = b.addStaticLibrary(.{
            .name = "bn254_wrapper",
            .target = config.target,
            .optimize = config.optimize,
        });

        const profile_dir = if (config.optimize == .Debug) "debug" else "release";
        const lib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/libbn254_wrapper.a", .{ target_triple, profile_dir })
        else
            b.fmt("target/{s}/libbn254_wrapper.a", .{profile_dir});

        lib.addObjectFile(b.path(lib_path));
        lib.linkLibC();
        lib.addIncludePath(b.path("src/bn254_wrapper"));

        // Make sure workspace builds first
        if (workspace_build_step) |build_step| {
            lib.step.dependOn(&build_step.step);
        }

        break :blk lib;
    } else null;

    // Create REVM library that depends on workspace build
    const revm_lib = if (rust_target != null) blk: {
        const lib = b.addStaticLibrary(.{
            .name = "revm_wrapper",
            .target = config.target,
            .optimize = config.optimize,
        });

        const profile_dir = if (config.optimize == .Debug) "debug" else "release";
        const lib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.a", .{ target_triple, profile_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.a", .{profile_dir});

        lib.addObjectFile(b.path(lib_path));
        lib.linkLibC();
        lib.addIncludePath(b.path("src/revm_wrapper"));

        // Make sure workspace builds first
        if (workspace_build_step) |build_step| {
            lib.step.dependOn(&build_step.step);
        }

        break :blk lib;
    } else null;

    return .{
        .bn254_lib = bn254_lib,
        .revm_lib = revm_lib,
        .workspace_build_step = workspace_build_step,
    };
}

pub fn createRevmModule(b: *std.Build, config: RustConfig, primitives_mod: *std.Build.Module, revm_lib: ?*std.Build.Step.Compile) ?*std.Build.Module {
    if (revm_lib == null) return null;

    const revm_mod = b.createModule(.{
        .root_source_file = b.path("src/revm_wrapper/revm.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    revm_mod.addImport("primitives", primitives_mod);

    // Link REVM Rust library if available
    if (revm_lib) |lib| {
        revm_mod.linkLibrary(lib);
        revm_mod.addIncludePath(b.path("src/revm_wrapper"));
    }

    return revm_mod;
}

fn getRustTarget(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => null,
        },
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => null,
        },
        else => null,
    };
}