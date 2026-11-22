const std = @import("std");
const foundry = @import("foundry");

test "Foundry Linux wrapper uses the flattening ELF archiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph: std.Build.Graph = .{
        .arena = allocator,
        .cache = .{ .gpa = allocator, .manifest_dir = std.fs.cwd() },
        .zig_exe = "zig",
        .env_map = try std.process.getEnvMap(allocator),
        .global_cache_root = .{ .path = ".", .handle = std.fs.cwd() },
        .zig_lib_directory = .{ .path = ".", .handle = std.fs.cwd() },
        .host = .{ .query = .{}, .result = try std.zig.system.resolveTargetQuery(.{}) },
        .time_report = false,
    };
    const root = std.Build.Cache.Directory{ .path = ".", .handle = std.fs.cwd() };
    const b = try std.Build.create(&graph, root, root, &.{});
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const cargo = b.step("cargo", "Cargo prerequisite");
    const library = foundry.createFoundryLibrary(b, target, .Debug, cargo, "x86_64-unknown-linux-gnu") orelse return error.MissingFoundrySource;
    try std.testing.expectEqual(false, library.use_lld.?);
    try std.testing.expectEqual(std.builtin.LinkMode.static, library.linkage.?);
    try std.testing.expect(std.mem.indexOfScalar(*std.Build.Step, library.step.dependencies.items, cargo) != null);
}

test "Foundry macOS wrapper preserves default linker selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph: std.Build.Graph = .{
        .arena = allocator,
        .cache = .{ .gpa = allocator, .manifest_dir = std.fs.cwd() },
        .zig_exe = "zig",
        .env_map = try std.process.getEnvMap(allocator),
        .global_cache_root = .{ .path = ".", .handle = std.fs.cwd() },
        .zig_lib_directory = .{ .path = ".", .handle = std.fs.cwd() },
        .host = .{ .query = .{}, .result = try std.zig.system.resolveTargetQuery(.{}) },
        .time_report = false,
    };
    const root = std.Build.Cache.Directory{ .path = ".", .handle = std.fs.cwd() };
    const b = try std.Build.create(&graph, root, root, &.{});
    const target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const cargo = b.step("cargo", "Cargo prerequisite");
    const library = foundry.createFoundryLibrary(b, target, .Debug, cargo, "aarch64-apple-darwin") orelse return error.MissingFoundrySource;
    try std.testing.expectEqual(@as(?bool, null), library.use_lld);
}
