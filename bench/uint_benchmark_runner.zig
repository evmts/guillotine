const std = @import("std");
const uint_benchmark = @import("uint_benchmark.zig");
const zbench = @import("zbench");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🚀 Uint Library Performance Benchmark Suite\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("Comparing custom Uint library against Zig's native u256\n\n", .{});

    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();

    try uint_benchmark.run_uint_benchmarks(allocator, &benchmark);

    std.debug.print("\n✅ Benchmark suite completed successfully!\n", .{});
}