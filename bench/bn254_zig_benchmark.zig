const std = @import("std");
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

// Import our Zig implementations
const FpMont = @import("crypto").bn254.FpMont;
const Fr = @import("crypto").bn254.Fr;
const Fp2Mont = @import("crypto").bn254.Fp2Mont;
const G1 = @import("crypto").bn254.G1;
const G2 = @import("crypto").bn254.G2;
const pairing = @import("crypto").bn254.pairing;

// Test vectors for benchmarking
const TEST_VECTORS = struct {
    // G1 generator point coordinates
    const G1_GEN_X = 0x1;
    const G1_GEN_Y = 0x2;

    // Scalar for multiplication
    const SCALAR = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF;
};

pub fn runBn254ZigBenchmarks(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== BN254 Native Zig Implementation Benchmarks ===\n", .{});

    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    // Benchmark ECMUL operations
    std.debug.print("\n--- ECMUL Benchmarks ---\n", .{});

    // Native Zig ECMUL benchmark
    const ZigEcmulBench = struct {
        fn bench() !void {
            // Parse input
            const x = TEST_VECTORS.G1_GEN_X;
            const y = TEST_VECTORS.G1_GEN_Y;
            const scalar = TEST_VECTORS.SCALAR;

            // Create field elements
            const x_fp = FpMont.init(x);
            const y_fp = FpMont.init(y);
            const z_fp = FpMont.ONE;

            // Create G1 point
            const g1_point = try G1.init(&x_fp, &y_fp, &z_fp);

            // Perform scalar multiplication
            const fr_scalar = Fr.init(scalar);
            _ = g1_point.mul(&fr_scalar);
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "ECMUL (Zig native)",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, ZigEcmulBench.bench);

    // Benchmark ECPAIRING operations
    std.debug.print("\n--- ECPAIRING Benchmarks ---\n", .{});

    // Native Zig ECPAIRING benchmark
    const ZigEcpairingBench = struct {
        fn bench() !void {
            // Parse G1 point
            const g1_x = TEST_VECTORS.G1_GEN_X;
            const g1_y = TEST_VECTORS.G1_GEN_Y;

            // Create field elements
            const x_fp = FpMont.init(g1_x);
            const y_fp = FpMont.init(g1_y);
            const z_fp = FpMont.ONE;

            // Create G1 point
            const g1_point = try G1.init(&x_fp, &y_fp, &z_fp);

            // Use G2 generator
            const g2_point = G2.GENERATOR;

            // Perform pairing
            _ = pairing(&g1_point, &g2_point);
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "ECPAIRING (Zig native)",
        .iterations = 100,
        .warmup_iterations = 10,
    }, ZigEcpairingBench.bench);

    // Component benchmarks
    std.debug.print("\n--- Component Operation Benchmarks ---\n", .{});

    // Field multiplication benchmark
    const FieldMulBench = struct {
        fn bench() void {
            const a = FpMont.init(0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF);
            const b = FpMont.init(0xFEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210);
            _ = a.mul(&b);
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "Field multiplication (Fp)",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, FieldMulBench.bench);

    // Field inversion benchmark
    const FieldInvBench = struct {
        fn bench() void {
            const a = FpMont.init(0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF);
            _ = a.inv() catch unreachable;
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "Field inversion (Fp)",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, FieldInvBench.bench);

    // G1 point addition benchmark
    const G1AddBench = struct {
        fn bench() !void {
            const p1 = G1.GENERATOR;
            const p2 = G1.GENERATOR.double();
            _ = p1.add(&p2);
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "G1 point addition",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, G1AddBench.bench);

    // G1 point doubling benchmark
    const G1DoubleBench = struct {
        fn bench() void {
            const p = G1.GENERATOR;
            _ = p.double();
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "G1 point doubling",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, G1DoubleBench.bench);

    // Print results
    suite.print_results();

    std.debug.print("\n=== BN254 Native Zig Benchmark Complete ===\n", .{});
}

// Standalone main for running just these benchmarks
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runBn254ZigBenchmarks(allocator);
}
