const std = @import("std");
const Allocator = std.mem.Allocator;
const zbench = @import("zbench");

// Export modules for use by other files in bench folder
pub const Evm = @import("evm");
pub const primitives = @import("primitives");

pub const zbench_runner = @import("zbench_runner.zig");
pub const precompile_benchmark = @import("precompile_benchmark.zig");

pub fn run(allocator: Allocator) !void {
    std.log.info("Starting EVM benchmark suite", .{});
    
    try zbench_runner.run_benchmarks(allocator, zbench);
    
    // Enable precompile benchmarks
    std.log.info("Running precompile dispatch benchmarks", .{});
    try precompile_benchmark.run_precompile_benchmarks(allocator);
    
    std.log.info("Benchmark suite completed", .{});
}

test {
    std.testing.refAllDeclsRecursive(@This());
}