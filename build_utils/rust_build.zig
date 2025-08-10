const std = @import("std");

pub const RustLibraryType = enum {
    static_lib, // .a file
    dynamic_lib, // .dylib/.so file
    rlib, // .rlib file
};

pub const RustBuildConfig = struct {
    name: []const u8,
    manifest_path: []const u8,
    target_triple: ?[]const u8 = null,
    profile: enum { dev, release } = .release,
    library_type: RustLibraryType = .static_lib,
    verbose: bool = true,
    rust_flags: ?[]const u8 = null,
};

pub fn buildRustLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: RustBuildConfig,
) *std.Build.Step.Compile {
    // Override profile based on optimize mode - always use release for non-Debug builds
    const actual_profile = switch (optimize) {
        .Debug => config.profile,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .release,
    };

    const rust_profile = switch (actual_profile) {
        .dev => "dev",
        .release => "release",
    };

    const rust_target_dir = switch (actual_profile) {
        .dev => "debug",
        .release => "release",
    };

    // Build cargo command
    var args = std.ArrayList([]const u8).init(b.allocator);
    args.appendSlice(&[_][]const u8{ "cargo", "build", "--profile", rust_profile }) catch @panic("OOM");

    if (config.target_triple) |triple| {
        args.appendSlice(&[_][]const u8{ "--target", triple }) catch @panic("OOM");
    }

    args.appendSlice(&[_][]const u8{ "--manifest-path", config.manifest_path }) catch @panic("OOM");

    if (config.verbose) {
        args.append("--verbose") catch @panic("OOM");
    }

    const rust_build = b.addSystemCommand(args.items);

    // Set environment variables
    if (config.rust_flags) |flags| {
        rust_build.setEnvironmentVariable("RUSTFLAGS", flags);
    } else {
        // Build default RUSTFLAGS based on optimization mode
        var rust_flags = std.ArrayList(u8).init(b.allocator);

        // Add aggressive optimizations for ReleaseFast
        if (optimize == .ReleaseFast) {
            rust_flags.appendSlice("-C opt-level=3 -C target-cpu=native -C codegen-units=1 -C lto=fat") catch @panic("OOM");
        }

        // Add macOS library path if needed
        if (target.result.os.tag == .macos) {
            if (rust_flags.items.len > 0) {
                rust_flags.append(' ') catch @panic("OOM");
            }
            rust_flags.appendSlice("-L/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib") catch @panic("OOM");
        }

        if (rust_flags.items.len > 0) {
            rust_build.setEnvironmentVariable("RUSTFLAGS", rust_flags.items);
        }
    }

    // Create library artifact
    const lib = b.addStaticLibrary(.{
        .name = config.name,
        .target = target,
        .optimize = optimize,
    });

    // Determine the output filename
    const extension = switch (config.library_type) {
        .static_lib => ".a",
        .dynamic_lib => if (target.result.os.tag == .macos) ".dylib" else ".so",
        .rlib => ".rlib",
    };

    const lib_filename = b.fmt("lib{s}{s}", .{ config.name, extension });

    // Determine library path
    const lib_path = if (config.target_triple) |triple|
        b.fmt("target/{s}/{s}/{s}", .{ triple, rust_target_dir, lib_filename })
    else
        b.fmt("target/{s}/{s}", .{ rust_target_dir, lib_filename });

    lib.addObjectFile(b.path(lib_path));
    lib.linkLibC();

    // Platform-specific libraries
    if (target.result.os.tag == .linux) {
        lib.linkSystemLibrary("dl");
        lib.linkSystemLibrary("pthread");
        lib.linkSystemLibrary("m");
        lib.linkSystemLibrary("rt");
    } else if (target.result.os.tag == .macos) {
        lib.linkFramework("Security");
        lib.linkFramework("CoreFoundation");
    }

    // Make rust build a dependency
    lib.step.dependOn(&rust_build.step);

    return lib;
}
