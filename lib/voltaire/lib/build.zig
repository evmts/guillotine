const std = @import("std");

// Import individual library build configurations
pub const BlstLib = @import("blst.zig");
pub const CKzgLib = @import("c-kzg.zig");
pub const Bn254Lib = @import("bn254.zig");
pub const KeccakLib = @import("keccak.zig");

// Re-export the main functions for convenience
pub const createBlstLibrary = BlstLib.createBlstLibrary;
pub const createCKzgLibrary = CKzgLib.createCKzgLibrary;
pub const getRustLibraryPath = Bn254Lib.getRustLibraryPath;

pub fn checkCargoInstalled() void {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "cargo", "--version" },
    }) catch {
        std.debug.print("\n", .{});
        std.debug.print("❌ ERROR: Cargo (Rust build tool) is not installed!\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("This project requires Rust libraries (bn254_wrapper, keccak_wrapper).\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("To install Rust and Cargo, visit:\n", .{});
        std.debug.print("  https://rustup.rs/\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("Or run: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(1);
    };
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        std.debug.print("\n", .{});
        std.debug.print("❌ ERROR: Cargo command failed!\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("Please ensure Cargo is properly installed and in your PATH.\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(1);
    }
}

pub fn createCargoBuildStep(b: *std.Build, optimize: std.builtin.OptimizeMode, target: std.Build.ResolvedTarget) *std.Build.Step {
    const cargo_build = b.addSystemCommand(&[_][]const u8{"cargo"});
    cargo_build.addArg("build");

    // Always build Rust in release mode for FFI libraries
    // Rust debug mode doesn't provide significant benefits when called from Zig,
    // and release mode works correctly across all platforms
    _ = optimize;
    cargo_build.addArg("--release");

    // Handle WASM targets - use portable pure Rust implementation
    const is_wasm = target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64;
    if (is_wasm) {
        cargo_build.addArg("--target");
        cargo_build.addArg("wasm32-unknown-unknown");
        cargo_build.addArg("--no-default-features");
        cargo_build.addArg("--features");
        cargo_build.addArg("portable");
    }
    // On Windows, force GNU toolchain to produce .a files with lib prefix
    // MSVC toolchain produces .lib files without lib prefix which breaks our build
    else if (target.result.os.tag == .windows) {
        const rust_target = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-pc-windows-gnu",
            .x86 => "i686-pc-windows-gnu",
            .aarch64 => "aarch64-pc-windows-gnu",
            else => @panic("Unsupported Windows architecture for Rust build"),
        };
        cargo_build.addArg("--target");
        cargo_build.addArg(rust_target);
    }

    // Set working directory to the primitives package root (where Cargo.toml lives)
    cargo_build.setCwd(b.path("."));

    return &cargo_build.step;
}

pub fn checkVendoredDeps(b: *std.Build) void {
    // Verify vendored c-kzg-4844 dependencies exist relative to build root
    const deps = [_]struct {
        path: []const u8,
        name: []const u8,
    }{
        .{ .path = "lib/c-kzg-4844/src", .name = "c-kzg-4844 source" },
        .{ .path = "lib/c-kzg-4844/blst/src", .name = "blst source" },
    };

    var missing = false;

    for (deps) |dep| {
        const full_path = b.path(dep.path);
        const path_str = full_path.getPath(b);
        std.fs.cwd().access(path_str, .{}) catch {
            if (!missing) {
                std.debug.print("\n", .{});
                std.debug.print("❌ ERROR: Required vendored dependencies are missing!\n", .{});
                std.debug.print("\n", .{});
                missing = true;
            }
            std.debug.print("  • {s}\n", .{dep.name});
        };
    }

    if (missing) {
        std.debug.print("\n", .{});
        std.debug.print("Vendored dependencies should be present in lib/c-kzg-4844/\n", .{});
        std.debug.print("This may indicate a corrupted clone or checkout.\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(1);
    }
}
