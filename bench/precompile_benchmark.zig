const std = @import("std");
const primitives = @import("primitives");
const evm = @import("evm");
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

// Test data
const addresses = [_]primitives.Address.Address{
    primitives.Address.from_u256(1), // ECRECOVER
    primitives.Address.from_u256(2), // SHA256
    primitives.Address.from_u256(3), // RIPEMD160
    primitives.Address.from_u256(4), // IDENTITY
    primitives.Address.from_u256(5), // MODEXP
    primitives.Address.from_u256(6), // ECADD
    primitives.Address.from_u256(7), // ECMUL
    primitives.Address.from_u256(8), // ECPAIRING
    primitives.Address.from_u256(9), // BLAKE2F
    primitives.Address.from_u256(10), // KZG_POINT_EVALUATION
};

const empty_input = &[_]u8{};
const small_input = &[_]u8{0x01} ** 32;
const medium_input = &[_]u8{0x02} ** 128;
const large_input = &[_]u8{0x03} ** 512;

const chain_rules = evm.hardforks.chain_rules.for_hardfork(.CANCUN); // Latest hardfork
var output_buffer: [1024]u8 = undefined;

// Benchmark helper functions
fn benchmark_dispatch_empty() void {
    const addr = primitives.Address.from_u256(4); // IDENTITY
    _ = evm.Precompiles.execute_precompile(addr, empty_input, &output_buffer, 100000, chain_rules);
}

fn benchmark_dispatch_small() void {
    const addr = primitives.Address.from_u256(4); // IDENTITY
    _ = evm.Precompiles.execute_precompile(addr, small_input, &output_buffer, 100000, chain_rules);
}

fn benchmark_dispatch_medium() void {
    const addr = primitives.Address.from_u256(4); // IDENTITY
    _ = evm.Precompiles.execute_precompile(addr, medium_input, &output_buffer, 100000, chain_rules);
}

fn benchmark_dispatch_large() void {
    const addr = primitives.Address.from_u256(4); // IDENTITY
    _ = evm.Precompiles.execute_precompile(addr, large_input, &output_buffer, 100000, chain_rules);
}

fn benchmark_mixed_workload() void {
    // Simulate realistic mixed workload
    for (addresses) |addr| {
        _ = evm.Precompiles.execute_precompile(addr, small_input, &output_buffer, 100000, chain_rules);
    }
}

fn benchmark_identity_heavy() void {
    // Identity precompile is commonly used, benchmark it heavily
    const identity_addr = primitives.Address.from_u256(4);
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        _ = evm.Precompiles.execute_precompile(identity_addr, medium_input, &output_buffer, 100000, chain_rules);
    }
}

/// Benchmark suite for precompile dispatch performance
pub fn run_precompile_benchmarks(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    std.debug.print("\n=== Precompile Dispatch Performance Benchmarks ===\n", .{});

    // Basic dispatch benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "precompile_dispatch_empty",
        .iterations = 100000,
        .warmup_iterations = 10000,
    }, benchmark_dispatch_empty);

    try suite.benchmark(BenchmarkConfig{
        .name = "precompile_dispatch_small",
        .iterations = 100000,
        .warmup_iterations = 10000,
    }, benchmark_dispatch_small);

    try suite.benchmark(BenchmarkConfig{
        .name = "precompile_dispatch_medium",
        .iterations = 50000,
        .warmup_iterations = 5000,
    }, benchmark_dispatch_medium);

    try suite.benchmark(BenchmarkConfig{
        .name = "precompile_dispatch_large",
        .iterations = 20000,
        .warmup_iterations = 2000,
    }, benchmark_dispatch_large);

    // Mixed workload benchmark (most important for measuring dispatch overhead)
    try suite.benchmark(BenchmarkConfig{
        .name = "precompile_mixed_workload",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, benchmark_mixed_workload);

    // Heavy identity workload
    try suite.benchmark(BenchmarkConfig{
        .name = "precompile_identity_heavy",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, benchmark_identity_heavy);

    suite.print_results();
}

/// Simple micro-benchmark for just the dispatch overhead
pub fn run_dispatch_microbenchmark() void {
    std.debug.print("\n=== Precompile Dispatch Micro-benchmark ===\n", .{});

    const iterations = 1000000;
    const identity_addr = primitives.Address.from_u256(4);

    // Time the dispatch overhead
    const start = std.time.nanoTimestamp();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        _ = evm.Precompiles.execute_precompile(identity_addr, empty_input, &output_buffer, 100000, chain_rules);
    }

    const end = std.time.nanoTimestamp();
    const total_ns = @as(u64, @intCast(end - start));
    const ns_per_call = total_ns / iterations;

    std.debug.print("Dispatch overhead: {} ns per call\n", .{ns_per_call});
    std.debug.print("Calls per second: {}\n", .{1_000_000_000 / ns_per_call});
}

/// Comparative benchmark between old switch-based and new table-based dispatch
/// This requires temporarily keeping both implementations
pub fn run_comparative_benchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Precompile Dispatch Performance Comparison ===\n", .{});
    std.debug.print("Note: This benchmark measures the dispatch overhead, not the actual precompile execution\n\n", .{});

    // Run the standard benchmarks
    try run_precompile_benchmarks(allocator);

    // Run the micro-benchmark
    run_dispatch_microbenchmark();

    std.debug.print("\nTo measure improvement:\n", .{});
    std.debug.print("1. Run this benchmark before applying the function table optimization\n", .{});
    std.debug.print("2. Apply the optimization and run again\n", .{});
    std.debug.print("3. Compare the results, particularly for 'precompile_mixed_workload'\n", .{});
    std.debug.print("4. Look for >5% improvement in dispatch performance\n", .{});
}
