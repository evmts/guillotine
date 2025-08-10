const std = @import("std");
const bn254_rust_benchmark = @import("bn254_rust_benchmark.zig");
const bn254_zig_benchmark = @import("bn254_zig_benchmark.zig");

pub fn runBn254Benchmarks(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== BN254 Benchmark Comparison ===\n", .{});
    std.debug.print("\nThis benchmark runs the Rust wrapper and Zig native implementations separately.\n", .{});
    std.debug.print("To ensure accurate measurements without interference.\n\n", .{});

    // Run Rust wrapper benchmarks
    std.debug.print("Running Rust wrapper benchmarks...\n", .{});
    try bn254_rust_benchmark.runBn254RustBenchmarks(allocator);

    std.debug.print("\n" ++ "=" ** 60 ++ "\n\n", .{});

    // Run Zig native benchmarks
    std.debug.print("Running Zig native benchmarks...\n", .{});
    try bn254_zig_benchmark.runBn254ZigBenchmarks(allocator);

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("\n=== Performance Comparison Instructions ===\n", .{});
    std.debug.print("To compare performance between implementations:\n", .{});
    std.debug.print("1. Run: zig build bench-bn254-rust\n", .{});
    std.debug.print("2. Run: zig build bench-bn254-zig\n", .{});
    std.debug.print("3. Compare the results manually or use hyperfine:\n", .{});
    std.debug.print("   hyperfine 'zig build bench-bn254-rust' 'zig build bench-bn254-zig'\n", .{});
    std.debug.print("\nNote: The precompile may use either Rust (arkworks) or native Zig implementation\n", .{});
    std.debug.print("depending on build configuration. Use --no-bn254 build flag to force native Zig\n", .{});
    std.debug.print("implementation in precompiles.\n", .{});

    std.debug.print("\n=== BN254 Benchmark Comparison Complete ===\n", .{});
}

// Standalone main for running just these benchmarks
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runBn254Benchmarks(allocator);
}
