const std = @import("std");
const foundry = @import("foundry");

fn makeTestBuild(allocator: std.mem.Allocator) !*std.Build {
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.testing.io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = try std.testing.environ.createMap(allocator),
        .host = .{ .query = .{}, .result = try std.zig.system.resolveTargetQuery(std.testing.io, .{}) },
        .generated_files = .empty,
        .wip_configuration = .{ .gpa = allocator },
    };
    const root: std.Build.Cache.Path = .{
        .root_dir = .{ .path = ".", .handle = std.Io.Dir.cwd() },
    };
    return try std.Build.create(graph, root, &.{});
}

test "Foundry Linux wrapper uses the flattening ELF archiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try makeTestBuild(arena.allocator());
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
    const b = try makeTestBuild(arena.allocator());
    const target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const cargo = b.step("cargo", "Cargo prerequisite");
    const library = foundry.createFoundryLibrary(b, target, .Debug, cargo, "aarch64-apple-darwin") orelse return error.MissingFoundrySource;
    try std.testing.expectEqual(@as(?bool, null), library.use_lld);
}
