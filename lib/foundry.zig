const std = @import("std");

pub fn createFoundryLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rust_build_step: ?*std.Build.Step,
    requested: ?[]const u8,
) ?*std.Build.Step.Compile {
    _ = requested;
    const rust_target = rustTarget(b, target);
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
    const name = if (target.result.os.tag == .windows and target.result.abi == .msvc) "foundry_wrapper.lib" else "libfoundry_wrapper.a";
    const archive = b.fmt("{s}/{s}", .{ rust_target_dir, name });
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
        foundry_lib.step.dependOn(createRustBuildStep(b, rust_target, optimize));
    }

    return foundry_lib;
}

pub fn createRustBuildStep(b: *std.Build, requested: ?[]const u8, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    _ = requested;
    const rust_target = rustTarget(b, selectedTarget(b));
    const rust_build = b.step("build-rust-workspace", "Build Rust workspace libraries");

    const cargo_build = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--workspace",
        "--locked",
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

// Return null for native Cargo builds; reject unsupported cross targets explicitly.
pub fn rustTarget(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (target.query.isNativeTriple()) return null;
    const arch = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .riscv64 => "riscv64gc",
        else => {
            std.log.err("unsupported Rust target architecture: {s}", .{@tagName(target.result.cpu.arch)});
            std.process.exit(1);
        },
    };
    return switch (target.result.os.tag) {
        .linux => switch (target.result.abi) {
            .gnu => b.fmt("{s}-unknown-linux-gnu", .{arch}),
            .musl => b.fmt("{s}-unknown-linux-musl", .{arch}),
            else => {
                std.log.err("unsupported Rust Linux ABI: {s}", .{@tagName(target.result.abi)});
                std.process.exit(1);
            },
        },
        .macos => b.fmt("{s}-apple-darwin", .{arch}),
        .windows => switch (target.result.abi) {
            .gnu => b.fmt("{s}-pc-windows-gnu", .{arch}),
            .msvc => b.fmt("{s}-pc-windows-msvc", .{arch}),
            else => {
                std.log.err("unsupported Rust Windows ABI: {s}", .{@tagName(target.result.abi)});
                std.process.exit(1);
            },
        },
        else => {
            std.log.err("unsupported Rust target OS: {s}", .{@tagName(target.result.os.tag)});
            std.process.exit(1);
        },
    };
}

fn selectedTarget(b: *std.Build) std.Build.ResolvedTarget {
    const triple = if (b.user_input_options.get("target")) |option| switch (option) {
        .scalar => |value| value,
        else => {
            std.log.err("target must be a single target triple", .{});
            std.process.exit(1);
        },
    } else "native";
    const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| {
        std.log.err("invalid target {s}: {s}", .{ triple, @errorName(err) });
        std.process.exit(1);
    };
    return b.resolveTargetQuery(query);
}
