const std = @import("std");
const Allocator = std.mem.Allocator;
const zbench = @import("zbench");

// Export modules for use by other files in bench folder
pub const Evm = @import("evm");
pub const primitives = @import("primitives");

pub const zbench_runner = @import("zbench_runner.zig");
pub const precompile_benchmark = @import("precompile_benchmark.zig");
pub const opcode_benchmarks = @import("opcode_benchmarks.zig");
pub const benchmarks = @import("benchmarks.zig");
pub const frame_benchmark = @import("frame_benchmark_simplified.zig");

pub fn run(allocator: Allocator) !void {
    std.log.info("Starting EVM benchmark suite", .{});
    
    // Run the comprehensive opcode benchmarks (Issue #62)
    std.log.info("Running comprehensive opcode benchmarks", .{});
    try opcode_benchmarks.run_comprehensive_opcode_benchmarks(allocator);
    
    // Run the comprehensive precompile benchmarks (Issue #68)
    std.log.info("Running comprehensive precompile benchmarks", .{});
    try benchmarks.run_all_precompile_benchmarks(allocator);
    
    // Run the frame management benchmarks (Issue #58)
    std.log.info("Running frame management benchmarks", .{});
    try frame_benchmark.run_frame_benchmarks(allocator);
    
    // Run the zbench-based benchmarks
    std.log.info("Running zbench benchmarks", .{});
    try zbench_runner.run_benchmarks(allocator, zbench);
    
    // Run original precompile dispatch benchmarks for comparison
    std.log.info("Running precompile dispatch benchmarks", .{});
    try precompile_benchmark.run_precompile_benchmarks(allocator);
    
    std.log.info("Benchmark suite completed", .{});
}

test {
    std.testing.refAllDeclsRecursive(@This());
}