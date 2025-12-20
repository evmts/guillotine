const std = @import("std");

// Returns the path to the Rust crypto_wrappers static library
// Best practice: Don't wrap Rust .a files in Zig libraries - link them directly to executables
// See: https://github.com/dajuguan/zigbuild-examples
pub fn getRustLibraryPath(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) std.Build.LazyPath {
    // Cargo always builds in release mode (see lib/build.zig createCargoBuildStep)
    const profile_dir = "release";

    // Check if this is a WASM target
    const is_wasm = target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64;
    if (is_wasm) {
        return b.path(b.fmt("target/wasm32-unknown-unknown/{s}/libcrypto_wrappers.a", .{profile_dir}));
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
        return b.path(b.fmt("target/{s}/{s}/libcrypto_wrappers.a", .{ rust_target, profile_dir }));
    } else {
        return b.path(b.fmt("target/{s}/libcrypto_wrappers.a", .{profile_dir}));
    }
}
