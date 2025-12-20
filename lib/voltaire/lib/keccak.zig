const std = @import("std");

pub fn createKeccakLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: anytype,
    workspace_build_step: ?*std.Build.Step,
    rust_target: ?[]const u8,
) ?*std.Build.Step.Compile {
    _ = config;
    _ = target;
    _ = optimize;
    _ = workspace_build_step;
    _ = rust_target;

    // Keccak wrapper is now part of crypto_wrappers library (see bn254.zig)
    // This function is kept for backwards compatibility but returns null
    // since the combined library is created by createBn254Library()
    _ = b;
    return null;
}
