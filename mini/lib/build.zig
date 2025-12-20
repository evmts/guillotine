const std = @import("std");

// Import individual library build configurations
pub const BlstLib = @import("blst.zig");
pub const CKzgLib = @import("c-kzg.zig");
pub const Bn254Lib = @import("bn254.zig");
pub const FoundryLib = @import("foundry.zig");

// Re-export the main functions for convenience
pub const createBlstLibrary = BlstLib.createBlstLibrary;
pub const createCKzgLibrary = CKzgLib.createCKzgLibrary;
pub const createBn254Library = Bn254Lib.createBn254Library;
pub const createFoundryLibrary = FoundryLib.createFoundryLibrary;
pub const createRustBuildStep = FoundryLib.createRustBuildStep;

pub fn checkSubmodules() void {
    const submodules = [_]struct {
        path: []const u8,
        name: []const u8,
    }{
        .{ .path = "lib/c-kzg-4844/.git", .name = "c-kzg-4844" },
    };

    var has_error = false;

    for (submodules) |submodule| {
        std.fs.cwd().access(submodule.path, .{}) catch {
            if (!has_error) {
                std.debug.print("\n", .{});
                std.debug.print("❌ ERROR: Git submodules are not initialized!\n", .{});
                std.debug.print("\n", .{});
                std.debug.print("The following required submodules are missing:\n", .{});
                has_error = true;
            }
            std.debug.print("  • {s}\n", .{submodule.name});
        };
    }

    if (has_error) {
        std.debug.print("\n", .{});
        std.debug.print("To fix this, run the following commands:\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  git submodule update --init --recursive\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("This will download and initialize all required dependencies.\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(1);
    }
}