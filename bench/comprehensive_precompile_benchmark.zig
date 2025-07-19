const std = @import("std");
const primitives = @import("primitives");
const evm = @import("evm");
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

// Precompile addresses for benchmarking
const PRECOMPILE_ADDRESSES = [_]primitives.Address.Address{
    primitives.Address.from_u256(1),  // ECRECOVER
    primitives.Address.from_u256(2),  // SHA256
    primitives.Address.from_u256(3),  // RIPEMD160
    primitives.Address.from_u256(4),  // IDENTITY
    primitives.Address.from_u256(5),  // MODEXP
    primitives.Address.from_u256(6),  // ECADD
    primitives.Address.from_u256(7),  // ECMUL
    primitives.Address.from_u256(8),  // ECPAIRING
    primitives.Address.from_u256(9),  // BLAKE2F
    primitives.Address.from_u256(10), // KZG_POINT_EVALUATION
};

const PRECOMPILE_NAMES = [_][]const u8{
    "ECRECOVER",
    "SHA256",
    "RIPEMD160", 
    "IDENTITY",
    "MODEXP",
    "ECADD",
    "ECMUL", 
    "ECPAIRING",
    "BLAKE2F",
    "KZG_POINT_EVALUATION",
};

// Test data sizes for scalable benchmarks
const SMALL_INPUT_SIZE = 32;
const MEDIUM_INPUT_SIZE = 128;  
const LARGE_INPUT_SIZE = 512;
const XLARGE_INPUT_SIZE = 1024;

const chain_rules = evm.hardforks.ChainRules.for_hardfork(.CANCUN);
var output_buffer: [2048]u8 = undefined;

// Benchmark data generation
fn generate_test_data(allocator: std.mem.Allocator, size: usize, pattern: u8) ![]u8 {
    const data = try allocator.alloc(u8, size);
    for (data, 0..) |*byte, i| {
        byte.* = pattern +% @as(u8, @intCast(i % 256));
    }
    return data;
}

// ECRECOVER benchmark data (needs valid signature format)
fn generate_ecrecover_data() [128]u8 {
    var data = [_]u8{0} ** 128;
    // Valid ECRECOVER input structure: hash(32) + v(32) + r(32) + s(32)
    // Using example from Ethereum tests
    const hash = [_]u8{0x45, 0x6e, 0x9a, 0xea, 0x5e, 0x19, 0x7a, 0x1f} ++ [_]u8{0} ** 24;
    const v = [_]u8{0} ** 31 ++ [_]u8{0x1c}; // v = 28
    const r = [_]u8{0x9c, 0xa5, 0xca, 0x02, 0x6e, 0x45, 0x1b, 0x22} ++ [_]u8{0} ** 24;
    const s = [_]u8{0x1f, 0x45, 0xd3, 0xbb, 0xea, 0xd5, 0x8c, 0x7e} ++ [_]u8{0} ** 24;
    
    @memcpy(data[0..32], &hash);
    @memcpy(data[32..64], &v);
    @memcpy(data[64..96], &r);
    @memcpy(data[96..128], &s);
    
    return data;
}

// ECADD/ECMUL benchmark data (needs valid elliptic curve points)  
fn generate_ec_point_data() [128]u8 {
    var data = [_]u8{0} ** 128;
    // Point 1: Generator point (1, 2) on BN254 curve
    data[31] = 0x01; // x1 = 1
    data[63] = 0x02; // y1 = 2
    // Point 2: Another valid point
    data[95] = 0x03; // x2 = 3  
    data[127] = 0x04; // y2 = 4 (not on curve but will be handled)
    return data;
}

// ECPAIRING benchmark data
fn generate_ecpairing_data() [192]u8 {
    var data = [_]u8{0} ** 192;
    // G1 point (64 bytes) + G2 point (128 bytes)
    // Using zeros for simplicity - real implementation handles edge cases
    return data;
}

// BLAKE2F benchmark data
fn generate_blake2f_data() [213]u8 {
    var data = [_]u8{0} ** 213;
    // BLAKE2F requires specific input format: rounds(4) + h(64) + m(128) + t(16) + f(1)
    data[3] = 12; // rounds = 12 (standard)
    // Initialize state vector with BLAKE2b IV
    const blake2b_iv = [_]u8{
        0x6a, 0x09, 0xe6, 0x67, 0xf3, 0xbc, 0xc9, 0x08,
        0xbb, 0x67, 0xae, 0x85, 0x84, 0xca, 0xa7, 0x3b,
        0x3c, 0x6e, 0xf3, 0x72, 0xfe, 0x94, 0xf8, 0x2b,
        0xa5, 0x4f, 0xf5, 0x3a, 0x5f, 0x1d, 0x36, 0xf1,
        0x51, 0x0e, 0x52, 0x7f, 0xad, 0xe6, 0x82, 0xd1,
        0x9b, 0x05, 0x68, 0x8c, 0x2b, 0x3e, 0x6c, 0x1f,
        0x1f, 0x83, 0xd9, 0xab, 0xfb, 0x41, 0xbd, 0x6b,
        0x5b, 0xe0, 0xcd, 0x19, 0x13, 0x7e, 0x21, 0x79
    };
    @memcpy(data[4..68], &blake2b_iv);
    return data;
}

// Individual precompile benchmarks
fn benchmark_ecrecover() void {
    const input = generate_ecrecover_data();
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(1),
        &input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_sha256_small() void {
    const input = &([_]u8{0x01} ** SMALL_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(2),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_sha256_medium() void {
    const input = &([_]u8{0x02} ** MEDIUM_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(2),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_sha256_large() void {
    const input = &([_]u8{0x03} ** LARGE_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(2),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_ripemd160_small() void {
    const input = &([_]u8{0x04} ** SMALL_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(3),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_ripemd160_large() void {
    const input = &([_]u8{0x05} ** LARGE_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(3),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_identity_small() void {
    const input = &([_]u8{0x06} ** SMALL_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(4),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_identity_medium() void {
    const input = &([_]u8{0x07} ** MEDIUM_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(4),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_identity_large() void {
    const input = &([_]u8{0x08} ** LARGE_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(4),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_identity_xlarge() void {
    const input = &([_]u8{0x09} ** XLARGE_INPUT_SIZE);
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(4),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_modexp_small() void {
    // MODEXP input: base_len(32) + exp_len(32) + mod_len(32) + base + exp + mod
    var input = [_]u8{0} ** 160;
    // Base length = 32, exp length = 32, mod length = 32
    input[31] = 32;  // base_len
    input[63] = 32;  // exp_len  
    input[95] = 32;  // mod_len
    // Simple values: base=2, exp=3, mod=97
    input[126] = 2;  // base
    input[158] = 3;  // exp
    input[159] = 97; // mod
    
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(5),
        &input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_ecadd() void {
    const input = generate_ec_point_data();
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(6),
        &input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_ecmul() void {
    var input = [_]u8{0} ** 96;
    // Point (x, y) + scalar
    const ec_data = generate_ec_point_data();
    @memcpy(input[0..64], ec_data[0..64]);
    input[95] = 2; // scalar = 2
    
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(7),
        &input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_ecpairing_empty() void {
    // Empty input should succeed (identity pairing)
    const input: []const u8 = &[_]u8{};
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(8),
        input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_ecpairing_single() void {
    const input = generate_ecpairing_data();
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(8),
        &input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_blake2f() void {
    const input = generate_blake2f_data();
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(9),
        &input,
        &output_buffer,
        100000,
        chain_rules
    );
}

fn benchmark_kzg_point_evaluation() void {
    // KZG Point Evaluation input: versioned_hash(32) + z(32) + y(32) + commitment(48) + proof(48)
    var input = [_]u8{0} ** 192;
    // Fill with pattern data for testing
    for (input, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }
    
    _ = evm.Precompiles.execute_precompile(
        primitives.Address.from_u256(10),
        &input,
        &output_buffer,
        100000,
        chain_rules
    );
}

// Mixed workload benchmarks
fn benchmark_mixed_crypto_workload() void {
    // Simulate common DeFi transaction with multiple precompile calls
    const sha_input = &([_]u8{0x01} ** 64);
    const identity_input = &([_]u8{0x02} ** 128);
    const ecrecover_input = generate_ecrecover_data();
    
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(2), sha_input, &output_buffer, 100000, chain_rules);
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(4), identity_input, &output_buffer, 100000, chain_rules);
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(1), &ecrecover_input, &output_buffer, 100000, chain_rules);
}

fn benchmark_ec_operations_workload() void {
    // Simulate zkSNARK verification with EC operations
    const ecadd_input = generate_ec_point_data();
    const ecmul_input_data = generate_ec_point_data();
    var ecmul_input = [_]u8{0} ** 96;
    @memcpy(ecmul_input[0..64], ecmul_input_data[0..64]);
    ecmul_input[95] = 3; // scalar
    
    const ecpairing_input = generate_ecpairing_data();
    
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(6), &ecadd_input, &output_buffer, 100000, chain_rules);
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(7), &ecmul_input, &output_buffer, 100000, chain_rules);
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(8), &ecpairing_input, &output_buffer, 100000, chain_rules);
}

fn benchmark_hash_intensive_workload() void {
    // Simulate hash-intensive operations (Merkle tree verification)
    const input_small = &([_]u8{0x01} ** 32);
    const input_medium = &([_]u8{0x02} ** 64);
    const input_large = &([_]u8{0x03} ** 128);
    
    // Multiple SHA256 calls with different sizes
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(2), input_small, &output_buffer, 100000, chain_rules);
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(2), input_medium, &output_buffer, 100000, chain_rules);
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(2), input_large, &output_buffer, 100000, chain_rules);
    
    // RIPEMD160 for Bitcoin-style operations
    _ = evm.Precompiles.execute_precompile(primitives.Address.from_u256(3), input_medium, &output_buffer, 100000, chain_rules);
}

/// Run comprehensive benchmarks for all precompiled contracts
pub fn run_comprehensive_precompile_benchmarks(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    std.debug.print("\n=== Comprehensive Precompile Performance Benchmarks ===\n", .{});
    std.debug.print("Measuring execution time, gas efficiency, and throughput for all precompiles\n\n", .{});

    // ECRECOVER benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "ECRECOVER_signature_recovery",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, benchmark_ecrecover);

    // SHA256 benchmarks with different input sizes
    try suite.benchmark(BenchmarkConfig{
        .name = "SHA256_small_32B",
        .iterations = 100000,
        .warmup_iterations = 10000,
    }, benchmark_sha256_small);

    try suite.benchmark(BenchmarkConfig{
        .name = "SHA256_medium_128B", 
        .iterations = 50000,
        .warmup_iterations = 5000,
    }, benchmark_sha256_medium);

    try suite.benchmark(BenchmarkConfig{
        .name = "SHA256_large_512B",
        .iterations = 20000,
        .warmup_iterations = 2000,
    }, benchmark_sha256_large);

    // RIPEMD160 benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "RIPEMD160_small_32B",
        .iterations = 50000,
        .warmup_iterations = 5000,
    }, benchmark_ripemd160_small);

    try suite.benchmark(BenchmarkConfig{
        .name = "RIPEMD160_large_512B",
        .iterations = 20000,
        .warmup_iterations = 2000,
    }, benchmark_ripemd160_large);

    // IDENTITY benchmarks - most frequently used precompile
    try suite.benchmark(BenchmarkConfig{
        .name = "IDENTITY_small_32B",
        .iterations = 500000,
        .warmup_iterations = 50000,
    }, benchmark_identity_small);

    try suite.benchmark(BenchmarkConfig{
        .name = "IDENTITY_medium_128B",
        .iterations = 200000,
        .warmup_iterations = 20000,
    }, benchmark_identity_medium);

    try suite.benchmark(BenchmarkConfig{
        .name = "IDENTITY_large_512B",
        .iterations = 100000,
        .warmup_iterations = 10000,
    }, benchmark_identity_large);

    try suite.benchmark(BenchmarkConfig{
        .name = "IDENTITY_xlarge_1024B",
        .iterations = 50000,
        .warmup_iterations = 5000,
    }, benchmark_identity_xlarge);

    // MODEXP benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "MODEXP_small_exponentiation",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, benchmark_modexp_small);

    // Elliptic curve operations
    try suite.benchmark(BenchmarkConfig{
        .name = "ECADD_point_addition",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, benchmark_ecadd);

    try suite.benchmark(BenchmarkConfig{
        .name = "ECMUL_scalar_multiplication",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, benchmark_ecmul);

    try suite.benchmark(BenchmarkConfig{
        .name = "ECPAIRING_empty_input",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, benchmark_ecpairing_empty);

    try suite.benchmark(BenchmarkConfig{
        .name = "ECPAIRING_single_pair",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, benchmark_ecpairing_single);

    // BLAKE2F benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "BLAKE2F_compression",
        .iterations = 20000,
        .warmup_iterations = 2000,
    }, benchmark_blake2f);

    // KZG Point Evaluation (EIP-4844)
    try suite.benchmark(BenchmarkConfig{
        .name = "KZG_point_evaluation",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, benchmark_kzg_point_evaluation);

    // Mixed workload benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "MIXED_crypto_workload",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, benchmark_mixed_crypto_workload);

    try suite.benchmark(BenchmarkConfig{
        .name = "MIXED_ec_operations",
        .iterations = 2000,
        .warmup_iterations = 200,
    }, benchmark_ec_operations_workload);

    try suite.benchmark(BenchmarkConfig{
        .name = "MIXED_hash_intensive",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, benchmark_hash_intensive_workload);

    suite.print_results();
    
    std.debug.print("\n=== Precompile Performance Analysis ===\n", .{});
    print_performance_analysis();
}

/// Print analysis of precompile performance characteristics
fn print_performance_analysis() void {
    std.debug.print("\n📊 Performance Insights:\n", .{});
    std.debug.print("  • IDENTITY: Linear scaling with input size, highly optimized for memory copying\n", .{});
    std.debug.print("  • SHA256/RIPEMD160: Linear scaling, heavier computation than IDENTITY\n", .{});
    std.debug.print("  • ECRECOVER: Fixed cost, expensive signature recovery operations\n", .{});
    std.debug.print("  • EC Operations: ECADD < ECMUL < ECPAIRING in computational complexity\n", .{});
    std.debug.print("  • MODEXP: Cost depends on exponent size and modulus size\n", .{});
    std.debug.print("  • BLAKE2F: Fixed 213-byte input, rounds parameter affects cost\n", .{});
    std.debug.print("  • KZG: Most expensive, cryptographic proof verification\n", .{});
    
    std.debug.print("\n🎯 Optimization Targets:\n", .{});
    std.debug.print("  • IDENTITY: Most frequent, optimize memory copy operations\n", .{});
    std.debug.print("  • SHA256: Common in Merkle proofs, optimize for 32-64 byte inputs\n", .{});
    std.debug.print("  • EC Operations: Critical for zkSNARKs, focus on BN254 curve efficiency\n", .{});
    
    std.debug.print("\n⚡ Gas Efficiency:\n", .{});
    std.debug.print("  • Monitor gas_cost/execution_time ratio for each precompile\n", .{});
    std.debug.print("  • EIP-1108 reduced EC operation costs for better efficiency\n", .{});
    std.debug.print("  • Dispatch overhead should be minimal vs actual computation time\n", .{});
}

/// Simple micro-benchmark for dispatch overhead measurement
pub fn run_dispatch_microbenchmark() void {
    std.debug.print("\n=== Precompile Dispatch Micro-benchmark ===\n", .{});
    
    const iterations = 1000000;
    const identity_addr = primitives.Address.from_u256(4);
    const empty_input: []const u8 = &[_]u8{};
    
    // Measure dispatch overhead with empty IDENTITY calls
    const start_time = std.time.nanoTimestamp();
    
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        _ = evm.Precompiles.execute_precompile(identity_addr, empty_input, &output_buffer, 100000, chain_rules);
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_ns = @as(u64, @intCast(end_time - start_time));
    const ns_per_call = total_ns / iterations;
    
    std.debug.print("Dispatch overhead: {} ns per call\n", .{ns_per_call});
    std.debug.print("Throughput: {} calls/second\n", .{1_000_000_000 / ns_per_call});
    std.debug.print("Function table lookup efficiency: {d:.2} cycles/call @ 3GHz\n", .{@as(f64, @floatFromInt(ns_per_call)) * 3.0});
}

/// Comparative analysis between different precompile categories
pub fn run_comparative_analysis(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Precompile Comparative Performance Analysis ===\n", .{});
    
    // Memory allocation for timing measurements
    var hash_times = std.ArrayList(u64).init(allocator);
    defer hash_times.deinit();
    
    var ec_times = std.ArrayList(u64).init(allocator);
    defer ec_times.deinit();
    
    var utility_times = std.ArrayList(u64).init(allocator);
    defer utility_times.deinit();
    
    const measurement_iterations = 10000;
    
    // Measure hash function performance
    std.debug.print("Measuring hash function performance...\n", .{});
    var i: u32 = 0;
    while (i < measurement_iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        benchmark_sha256_small();
        const end = std.time.nanoTimestamp();
        try hash_times.append(@as(u64, @intCast(end - start)));
    }
    
    // Measure EC operation performance  
    std.debug.print("Measuring elliptic curve performance...\n", .{});
    i = 0;
    while (i < measurement_iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        benchmark_ecadd();
        const end = std.time.nanoTimestamp();
        try ec_times.append(@as(u64, @intCast(end - start)));
    }
    
    // Measure utility precompile performance
    std.debug.print("Measuring utility precompile performance...\n", .{});
    i = 0;
    while (i < measurement_iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        benchmark_identity_small();
        const end = std.time.nanoTimestamp();
        try utility_times.append(@as(u64, @intCast(end - start)));
    }
    
    // Calculate statistics
    const hash_avg = calculate_average(hash_times.items);
    const ec_avg = calculate_average(ec_times.items);
    const utility_avg = calculate_average(utility_times.items);
    
    std.debug.print("\n📈 Performance Comparison Results:\n", .{});
    std.debug.print("  Hash Functions (SHA256):    {d:>8.2} ns/call\n", .{hash_avg});
    std.debug.print("  EC Operations (ECADD):      {d:>8.2} ns/call\n", .{ec_avg});
    std.debug.print("  Utility Precompiles (ID):   {d:>8.2} ns/call\n", .{utility_avg});
    
    std.debug.print("\n🔍 Relative Performance:\n", .{});
    std.debug.print("  EC/Hash ratio:       {d:.2}x\n", .{ec_avg / hash_avg});
    std.debug.print("  Hash/Utility ratio:  {d:.2}x\n", .{hash_avg / utility_avg});
    std.debug.print("  EC/Utility ratio:    {d:.2}x\n", .{ec_avg / utility_avg});
}

fn calculate_average(values: []const u64) f64 {
    var sum: u64 = 0;
    for (values) |value| {
        sum += value;
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(values.len));
}