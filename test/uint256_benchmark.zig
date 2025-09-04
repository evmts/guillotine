const std = @import("std");
const testing = std.testing;
const primitives = @import("../src/primitives/uint.zig");

// Type aliases for clarity  
const U256 = primitives.Uint(256, 4);

/// Benchmarking suite to compare our U256 implementation with native u256
/// This helps identify performance regressions and optimization opportunities

pub const Benchmark = struct {
    const Self = @This();
    
    timer: std.time.Timer,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .timer = try std.time.Timer.start(),
            .allocator = allocator,
        };
    }
    
    pub fn timeOperation(self: *Self, comptime name: []const u8, comptime op: anytype, iterations: u32) !void {
        self.timer.reset();
        
        op();
        
        const elapsed = self.timer.read();
        const per_op = elapsed / iterations;
        
        std.debug.print("{s}: {} total, {} ns/op ({} iterations)\n", .{
            name, 
            std.fmt.fmtDuration(elapsed),
            per_op,
            iterations
        });
    }
};

/// Generate test data for benchmarks
fn generateBenchmarkData(allocator: std.mem.Allocator, count: usize) ![]U256 {
    var data = try allocator.alloc(U256, count);
    var rng = std.rand.DefaultPrng.init(12345);
    
    for (data, 0..) |*item, i| {
        if (i % 4 == 0) {
            item.* = U256.from_u64(rng.random().int(u64));
        } else if (i % 4 == 1) {
            item.* = U256.from_limbs(.{
                rng.random().int(u64),
                rng.random().int(u64),
                0, 0
            });
        } else if (i % 4 == 2) {
            item.* = U256.from_limbs(.{
                rng.random().int(u64),
                rng.random().int(u64),
                rng.random().int(u64),
                0
            });
        } else {
            item.* = U256.from_limbs(.{
                rng.random().int(u64),
                rng.random().int(u64),
                rng.random().int(u64),
                rng.random().int(u64)
            });
        }
    }
    
    return data;
}

/// Generate native u256 test data for comparison
fn generateNativeBenchmarkData(allocator: std.mem.Allocator, count: usize) ![]u256 {
    var data = try allocator.alloc(u256, count);
    var rng = std.rand.DefaultPrng.init(12345);
    
    for (data) |*item| {
        const bytes = rng.random().bytes([32]u8);
        item.* = std.mem.readInt(u256, &bytes, .little);
    }
    
    return data;
}

test "benchmark: addition operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const count = 10000;
    const iterations = count / 2;
    
    // Generate test data
    const u256_data = try generateBenchmarkData(allocator, count);
    defer allocator.free(u256_data);
    
    const native_data = try generateNativeBenchmarkData(allocator, count);
    defer allocator.free(native_data);
    
    var benchmark = try Benchmark.init(allocator);
    
    // Benchmark U256 addition
    try benchmark.timeOperation("U256 addition", struct {
        fn op() void {
            var result = U256.ZERO;
            for (0..iterations) |i| {
                const a = u256_data[i * 2];
                const b = u256_data[i * 2 + 1];
                result = result.wrapping_add(a.wrapping_add(b));
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
    
    // Benchmark native u256 addition
    try benchmark.timeOperation("native u256 addition", struct {
        fn op() void {
            var result: u256 = 0;
            for (0..iterations) |i| {
                const a = native_data[i * 2];
                const b = native_data[i * 2 + 1];
                result = result +% (a +% b);
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
}

test "benchmark: multiplication operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const count = 10000;
    const iterations = count / 2;
    
    const u256_data = try generateBenchmarkData(allocator, count);
    defer allocator.free(u256_data);
    
    const native_data = try generateNativeBenchmarkData(allocator, count);
    defer allocator.free(native_data);
    
    var benchmark = try Benchmark.init(allocator);
    
    // Benchmark U256 multiplication
    try benchmark.timeOperation("U256 multiplication", struct {
        fn op() void {
            var result = U256.ONE;
            for (0..iterations) |i| {
                const a = u256_data[i * 2];
                const b = u256_data[i * 2 + 1];
                result = result.wrapping_add(a.wrapping_mul(b));
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
    
    // Benchmark native u256 multiplication
    try benchmark.timeOperation("native u256 multiplication", struct {
        fn op() void {
            var result: u256 = 1;
            for (0..iterations) |i| {
                const a = native_data[i * 2];
                const b = native_data[i * 2 + 1];
                result = result +% (a *% b);
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
}

test "benchmark: division operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const count = 1000; // Division is slower, use fewer iterations
    const iterations = count / 2;
    
    const u256_data = try generateBenchmarkData(allocator, count);
    defer allocator.free(u256_data);
    
    const native_data = try generateNativeBenchmarkData(allocator, count);
    defer allocator.free(native_data);
    
    var benchmark = try Benchmark.init(allocator);
    
    // Benchmark U256 division
    try benchmark.timeOperation("U256 division", struct {
        fn op() void {
            var result = U256.from_u64(12345);
            for (0..iterations) |i| {
                var a = u256_data[i * 2];
                var b = u256_data[i * 2 + 1];
                
                // Ensure b is not zero
                if (b.is_zero()) b = U256.ONE;
                
                result = result.wrapping_add(a.wrapping_div(b));
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
    
    // Benchmark native u256 division
    try benchmark.timeOperation("native u256 division", struct {
        fn op() void {
            var result: u256 = 12345;
            for (0..iterations) |i| {
                var a = native_data[i * 2];
                var b = native_data[i * 2 + 1];
                
                // Ensure b is not zero
                if (b == 0) b = 1;
                
                result = result +% (a / b);
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
}

test "benchmark: bitwise operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const count = 10000;
    const iterations = count / 2;
    
    const u256_data = try generateBenchmarkData(allocator, count);
    defer allocator.free(u256_data);
    
    const native_data = try generateNativeBenchmarkData(allocator, count);
    defer allocator.free(native_data);
    
    var benchmark = try Benchmark.init(allocator);
    
    // Benchmark U256 bitwise operations
    try benchmark.timeOperation("U256 bitwise ops", struct {
        fn op() void {
            var result = U256.ZERO;
            for (0..iterations) |i| {
                const a = u256_data[i * 2];
                const b = u256_data[i * 2 + 1];
                result = result.bit_xor(a.bit_and(b).bit_or(a.bit_xor(b)));
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
    
    // Benchmark native u256 bitwise operations
    try benchmark.timeOperation("native u256 bitwise ops", struct {
        fn op() void {
            var result: u256 = 0;
            for (0..iterations) |i| {
                const a = native_data[i * 2];
                const b = native_data[i * 2 + 1];
                result = result ^ ((a & b) | (a ^ b));
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
}

test "benchmark: shift operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const count = 10000;
    
    const u256_data = try generateBenchmarkData(allocator, count);
    defer allocator.free(u256_data);
    
    const native_data = try generateNativeBenchmarkData(allocator, count);
    defer allocator.free(native_data);
    
    var benchmark = try Benchmark.init(allocator);
    
    // Benchmark U256 shift operations
    try benchmark.timeOperation("U256 shifts", struct {
        fn op() void {
            var result = U256.from_u64(1);
            for (0..count) |i| {
                const a = u256_data[i];
                const shift = @intCast(i % 128);
                result = result.bit_xor(a.wrapping_shl(shift).wrapping_shr(shift));
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, count);
    
    // Benchmark native u256 shift operations
    try benchmark.timeOperation("native u256 shifts", struct {
        fn op() void {
            var result: u256 = 1;
            for (0..count) |i| {
                const a = native_data[i];
                const shift = @intCast(i % 128);
                result = result ^ ((a << shift) >> shift);
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, count);
}

test "benchmark: comparison operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const count = 10000;
    const iterations = count / 2;
    
    const u256_data = try generateBenchmarkData(allocator, count);
    defer allocator.free(u256_data);
    
    const native_data = try generateNativeBenchmarkData(allocator, count);
    defer allocator.free(native_data);
    
    var benchmark = try Benchmark.init(allocator);
    
    // Benchmark U256 comparisons
    try benchmark.timeOperation("U256 comparisons", struct {
        fn op() void {
            var result: u32 = 0;
            for (0..iterations) |i| {
                const a = u256_data[i * 2];
                const b = u256_data[i * 2 + 1];
                
                if (a.lt(b)) result += 1;
                if (a.gt(b)) result += 2;  
                if (a.eq(b)) result += 4;
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
    
    // Benchmark native u256 comparisons
    try benchmark.timeOperation("native u256 comparisons", struct {
        fn op() void {
            var result: u32 = 0;
            for (0..iterations) |i| {
                const a = native_data[i * 2];
                const b = native_data[i * 2 + 1];
                
                if (a < b) result += 1;
                if (a > b) result += 2;
                if (a == b) result += 4;
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, iterations);
}

test "benchmark: conversion operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const count = 10000;
    
    const native_data = try generateNativeBenchmarkData(allocator, count);
    defer allocator.free(native_data);
    
    var benchmark = try Benchmark.init(allocator);
    
    // Benchmark U256 -> native conversions
    try benchmark.timeOperation("U256 to native u256", struct {
        fn op() void {
            var result: u256 = 0;
            for (0..count) |i| {
                const a = U256.from_u256(native_data[i]);
                if (a.to_u256()) |native_val| {
                    result = result +% native_val;
                }
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, count);
    
    // Benchmark native -> U256 conversions  
    try benchmark.timeOperation("native u256 to U256", struct {
        fn op() void {
            var result = U256.ZERO;
            for (0..count) |i| {
                const a = U256.from_u256(native_data[i]);
                result = result.wrapping_add(a);
            }
            std.mem.doNotOptimizeAway(&result);
        }
    }.op, count);
}

/// Comprehensive benchmark suite
test "benchmark: comprehensive performance comparison" {
    if (@import("builtin").mode != .ReleaseFast) {
        std.debug.print("Benchmarks should be run in ReleaseFast mode for accurate results\n", .{});
        return;
    }
    
    std.debug.print("\n=== U256 vs Native u256 Performance Comparison ===\n");
    
    // Run all benchmarks
    _ = @import("std").testing.refAllDecls(@This());
}