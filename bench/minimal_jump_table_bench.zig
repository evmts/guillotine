const std = @import("std");
const zbench = @import("zbench");
const jump_table_benchmarks = @import("jump_table_benchmarks.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();
    
    // Add only jump table benchmarks
    try benchmark.add("Jump Table AoS Full", jump_table_benchmarks.zbench_aos_full_access, .{});
    try benchmark.add("Jump Table SoA Hot Fields", jump_table_benchmarks.zbench_soa_hot_fields, .{});
    try benchmark.add("Jump Table SoA Full", jump_table_benchmarks.zbench_soa_full_access, .{});
    try benchmark.add("Jump Table AoS Sequential", jump_table_benchmarks.zbench_aos_sequential, .{});
    try benchmark.add("Jump Table SoA Sequential", jump_table_benchmarks.zbench_soa_sequential, .{});
    try benchmark.add("Jump Table AoS Random", jump_table_benchmarks.zbench_aos_random, .{});
    try benchmark.add("Jump Table SoA Random", jump_table_benchmarks.zbench_soa_random, .{});
    
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n=== Jump Table Benchmark Results ===\n", .{});
    try stdout.print("Comparing Array-of-Structs (current) vs Struct-of-Arrays (new)\n\n", .{});
    
    try benchmark.run(stdout);
}