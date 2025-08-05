/// Benchmark to compare original vs optimized precompile implementations
const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const timing = @import("timing.zig");

const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

// Import both implementations
const precompiles_original = @import("evm").precompiles.precompiles;
const precompiles_optimized = @import("evm").Precompiles;

const ChainRules = @import("evm").chain_rules.ChainRules;
const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

// Test data
const TestData = struct {
    const small = &[_]u8{0x01} ** 32;
    const medium = &[_]u8{0x02} ** 128;
    const large = &[_]u8{0x03} ** 512;
};

// Precompile addresses
const sha256_addr = primitives.Address.from_u256(2);
const ripemd160_addr = primitives.Address.from_u256(3);
const identity_addr = primitives.Address.from_u256(4);

var output_buffer: [1024]u8 = undefined;

/// Benchmark SHA256 precompile - original vs optimized
pub fn benchmark_sha256_comparison(allocator: std.mem.Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkFn = struct {
        // Original implementation
        fn sha256_original_small() void {
            _ = precompiles_original.execute_precompile(sha256_addr, TestData.small, &output_buffer, 100000, chain_rules);
        }
        fn sha256_original_medium() void {
            _ = precompiles_original.execute_precompile(sha256_addr, TestData.medium, &output_buffer, 100000, chain_rules);
        }
        fn sha256_original_large() void {
            _ = precompiles_original.execute_precompile(sha256_addr, TestData.large, &output_buffer, 100000, chain_rules);
        }
        
        // Optimized implementation
        fn sha256_optimized_small() void {
            _ = precompiles_optimized.execute_precompile(sha256_addr, TestData.small, &output_buffer, 100000, chain_rules);
        }
        fn sha256_optimized_medium() void {
            _ = precompiles_optimized.execute_precompile(sha256_addr, TestData.medium, &output_buffer, 100000, chain_rules);
        }
        fn sha256_optimized_large() void {
            _ = precompiles_optimized.execute_precompile(sha256_addr, TestData.large, &output_buffer, 100000, chain_rules);
        }
    };
    
    // Original benchmarks
    try suite.benchmark(BenchmarkConfig{ .name = "SHA256_original_small", .iterations = 10000, .warmup_iterations = 1000 }, BenchmarkFn.sha256_original_small);
    try suite.benchmark(BenchmarkConfig{ .name = "SHA256_original_medium", .iterations = 5000, .warmup_iterations = 500 }, BenchmarkFn.sha256_original_medium);
    try suite.benchmark(BenchmarkConfig{ .name = "SHA256_original_large", .iterations = 2000, .warmup_iterations = 200 }, BenchmarkFn.sha256_original_large);
    
    // Optimized benchmarks
    try suite.benchmark(BenchmarkConfig{ .name = "SHA256_optimized_small", .iterations = 10000, .warmup_iterations = 1000 }, BenchmarkFn.sha256_optimized_small);
    try suite.benchmark(BenchmarkConfig{ .name = "SHA256_optimized_medium", .iterations = 5000, .warmup_iterations = 500 }, BenchmarkFn.sha256_optimized_medium);
    try suite.benchmark(BenchmarkConfig{ .name = "SHA256_optimized_large", .iterations = 2000, .warmup_iterations = 200 }, BenchmarkFn.sha256_optimized_large);
    
    return suite;
}

/// Benchmark RIPEMD160 precompile - original vs optimized
pub fn benchmark_ripemd160_comparison(allocator: std.mem.Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkFn = struct {
        // Original implementation
        fn ripemd160_original_small() void {
            _ = precompiles_original.execute_precompile(ripemd160_addr, TestData.small, &output_buffer, 100000, chain_rules);
        }
        fn ripemd160_original_medium() void {
            _ = precompiles_original.execute_precompile(ripemd160_addr, TestData.medium, &output_buffer, 100000, chain_rules);
        }
        
        // Optimized implementation
        fn ripemd160_optimized_small() void {
            _ = precompiles_optimized.execute_precompile(ripemd160_addr, TestData.small, &output_buffer, 100000, chain_rules);
        }
        fn ripemd160_optimized_medium() void {
            _ = precompiles_optimized.execute_precompile(ripemd160_addr, TestData.medium, &output_buffer, 100000, chain_rules);
        }
    };
    
    // Original benchmarks
    try suite.benchmark(BenchmarkConfig{ .name = "RIPEMD160_original_small", .iterations = 8000, .warmup_iterations = 800 }, BenchmarkFn.ripemd160_original_small);
    try suite.benchmark(BenchmarkConfig{ .name = "RIPEMD160_original_medium", .iterations = 4000, .warmup_iterations = 400 }, BenchmarkFn.ripemd160_original_medium);
    
    // Optimized benchmarks
    try suite.benchmark(BenchmarkConfig{ .name = "RIPEMD160_optimized_small", .iterations = 8000, .warmup_iterations = 800 }, BenchmarkFn.ripemd160_optimized_small);
    try suite.benchmark(BenchmarkConfig{ .name = "RIPEMD160_optimized_medium", .iterations = 4000, .warmup_iterations = 400 }, BenchmarkFn.ripemd160_optimized_medium);
    
    return suite;
}

/// Benchmark dispatch overhead - test the union vs direct function call
pub fn benchmark_dispatch_overhead(allocator: std.mem.Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkFn = struct {
        // Test multiple different precompiles to measure dispatch overhead
        fn dispatch_original_mixed() void {
            _ = precompiles_original.execute_precompile(sha256_addr, TestData.small, &output_buffer, 100000, chain_rules);
            _ = precompiles_original.execute_precompile(ripemd160_addr, TestData.small, &output_buffer, 100000, chain_rules);
            _ = precompiles_original.execute_precompile(identity_addr, TestData.small, &output_buffer, 100000, chain_rules);
        }
        
        fn dispatch_optimized_mixed() void {
            _ = precompiles_optimized.execute_precompile(sha256_addr, TestData.small, &output_buffer, 100000, chain_rules);
            _ = precompiles_optimized.execute_precompile(ripemd160_addr, TestData.small, &output_buffer, 100000, chain_rules);
            _ = precompiles_optimized.execute_precompile(identity_addr, TestData.small, &output_buffer, 100000, chain_rules);
        }
    };
    
    try suite.benchmark(BenchmarkConfig{ .name = "Dispatch_original_mixed", .iterations = 5000, .warmup_iterations = 500 }, BenchmarkFn.dispatch_original_mixed);
    try suite.benchmark(BenchmarkConfig{ .name = "Dispatch_optimized_mixed", .iterations = 5000, .warmup_iterations = 500 }, BenchmarkFn.dispatch_optimized_mixed);
    
    return suite;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("\n=== Precompile Optimization Benchmarks ===\n", .{});
    std.debug.print("Comparing original vs optimized implementations\n\n", .{});
    
    // Run SHA256 comparison
    std.debug.print("SHA256 Precompile Comparison:\n", .{});
    std.debug.print("-----------------------------\n", .{});
    var sha256_suite = try benchmark_sha256_comparison(allocator);
    defer sha256_suite.deinit();
    sha256_suite.print_results();
    
    std.debug.print("\nRIPEMD160 Precompile Comparison:\n", .{});
    std.debug.print("---------------------------------\n", .{});
    var ripemd160_suite = try benchmark_ripemd160_comparison(allocator);
    defer ripemd160_suite.deinit();
    ripemd160_suite.print_results();
    
    std.debug.print("\nDispatch Overhead Comparison:\n", .{});
    std.debug.print("-----------------------------\n", .{});
    var dispatch_suite = try benchmark_dispatch_overhead(allocator);
    defer dispatch_suite.deinit();
    dispatch_suite.print_results();
    
    std.debug.print("\n=== Optimization Summary ===\n", .{});
    std.debug.print("1. Uniform interface eliminates union dispatch overhead (Issue #333)\n", .{});
    std.debug.print("2. Direct hash to output eliminates intermediate buffers (Issue #332)\n", .{});
    std.debug.print("3. Compile-time dispatch table improves cache locality\n", .{});
    std.debug.print("\n", .{});
}