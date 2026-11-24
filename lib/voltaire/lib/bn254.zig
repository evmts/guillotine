const std = @import("std");

// Returns the path to the Rust crypto_wrappers static library
// Best practice: Don't wrap Rust .a files in Zig libraries - link them directly to executables
// See: https://github.com/dajuguan/zigbuild-examples
//
// The archive is a generated path owned by `cargo_build_step` (lib/build.zig
// createCargoBuildStep), so every compile that links it, directly or through
// the exported `voltaire` and `crypto` modules, runs Cargo first. A plain
// source path has no producer, and a dependent package's fresh `zig build`
// failed with `libcrypto_wrappers.a: file not found` (guillotine #862, #863).
// Cargo writes to a fixed --target-dir, so the path is set at configure time
// instead of in a make() function, and configure-time getPath() still works.
pub fn getRustLibraryPath(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    cargo_build_step: *std.Build.Step,
) std.Build.LazyPath {
    const generated = b.allocator.create(std.Build.GeneratedFile) catch @panic("OOM");
    generated.* = .{
        .step = cargo_build_step,
        .path = b.pathFromRoot(rustLibrarySubPath(b, target)),
    };
    return .{ .generated = .{ .file = generated } };
}

fn rustLibrarySubPath(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    // Cargo always builds in release mode (see lib/build.zig createCargoBuildStep)
    const profile_dir = "release";

    // Check if this is a WASM target
    const is_wasm = target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64;
    if (is_wasm) {
        return b.fmt("target/wasm32-unknown-unknown/{s}/libcrypto_wrappers.a", .{profile_dir});
    }
    // On Windows, we force GNU toolchain with --target, so library goes in target-specific dir
    // On other platforms, we don't specify --target, so it goes in target/release
    else if (target.result.os.tag == .windows) {
        const rust_target = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-pc-windows-gnu",
            .x86 => "i686-pc-windows-gnu",
            .aarch64 => "aarch64-pc-windows-gnu",
            else => @panic("Unsupported Windows architecture for Rust build"),
        };
        return b.fmt("target/{s}/{s}/libcrypto_wrappers.a", .{ rust_target, profile_dir });
    } else {
        return b.fmt("target/{s}/libcrypto_wrappers.a", .{profile_dir});
    }
}
