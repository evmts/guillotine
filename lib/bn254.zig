const std = @import("std");
const foundry = @import("foundry.zig");

pub fn createBn254Library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: anytype,
    workspace_build_step: ?*std.Build.Step,
    requested: ?[]const u8,
) ?*std.Build.Step.Compile {
    _ = config;
    _ = requested;
    const triple = foundry.rustTarget(b, target);
    const profile = switch (optimize) {
        .debug => "debug",
        .safe, .small => "release",
        .fast => "release-fast",
    };
    const root = b.graph.environ_map.get("CARGO_TARGET_DIR") orelse "target";
    const name = if (target.result.os.tag == .windows and target.result.abi == .msvc) "bn254_wrapper.lib" else "libbn254_wrapper.a";
    const archive = if (triple) |value|
        b.fmt("{s}/{s}/{s}/{s}", .{ root, value, profile, name })
    else
        b.fmt("{s}/{s}/{s}", .{ root, profile, name });
    const lib = b.addLibrary(.{
        .name = "bn254_wrapper",
        .linkage = .static,
        .use_llvm = true,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.root_module.addObjectFile(if (b.graph.environ_map.get("CARGO_TARGET_DIR") != null) .{ .cwd_relative = archive } else b.path(archive));
    lib.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        lib.use_lld = false;
        lib.root_module.linkSystemLibrary("unwind", .{});
    }
    lib.step.dependOn(workspace_build_step orelse foundry.createRustBuildStep(b, triple, optimize));
    return lib;
}
