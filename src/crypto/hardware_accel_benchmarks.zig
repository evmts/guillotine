//! Comprehensive benchmark suite for hardware-accelerated cryptographic operations
//!
//! This module benchmarks the performance improvements of hardware acceleration
//! for SHA256 and Keccak256 across various input sizes and use cases relevant
//! to Ethereum operations.

const std = @import("std");
const crypto = @import("crypto");
const Timer = std.time.Timer;

test "comprehensive_crypto_hardware_acceleration_benchmarks" {
    std.testing.log_level = .warn;

    const allocator = std.testing.allocator;
    var timer = try Timer.start();

    // Log CPU features
    const features = crypto.CpuFeatures.cpu_features;
    std.log.debug("\n=== CPU Features Detected ===", .{});
    features.log();

    // Test data sizes relevant to Ethereum
    const test_cases = [_]struct {
        name: []const u8,
        size: usize,
        iterations: usize,
    }{
        .{ .name = "Function signature (4 bytes)", .size = 4, .iterations = 100000 },
        .{ .name = "Address (20 bytes)", .size = 20, .iterations = 100000 },
        .{ .name = "Word (32 bytes)", .size = 32, .iterations = 100000 },
        .{ .name = "Two words (64 bytes)", .size = 64, .iterations = 50000 },
        .{ .name = "Event data (128 bytes)", .size = 128, .iterations = 50000 },
        .{ .name = "Small transaction (256 bytes)", .size = 256, .iterations = 25000 },
        .{ .name = "Medium data (1 KB)", .size = 1024, .iterations = 10000 },
        .{ .name = "Large data (4 KB)", .size = 4096, .iterations = 2500 },
        .{ .name = "Contract code (16 KB)", .size = 16384, .iterations = 500 },
    };

    // Benchmark SHA256
    std.log.debug("\n=== SHA256 Benchmarks ===", .{});
    for (test_cases) |test_case| {
        const data = try allocator.alloc(u8, test_case.size);
        defer allocator.free(data);

        // Fill with pseudo-random data
        for (data, 0..) |*byte, i| {
            byte.* = @as(u8, @intCast((i * 7 + 13) & 0xFF));
        }

        // Benchmark hardware-accelerated SHA256
        timer.reset();
        var i: usize = 0;
        while (i < test_case.iterations) : (i += 1) {
            var output: [32]u8 = undefined;
            crypto.SHA256_Accel.SHA256_Accel.hash(data, &output);
        }
        const hw_time = timer.read();

        // Benchmark standard library SHA256
        timer.reset();
        i = 0;
        while (i < test_case.iterations) : (i += 1) {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(data);
            var output: [32]u8 = undefined;
            hasher.final(&output);
        }
        const std_time = timer.read();

        // Calculate throughput in MB/s
        const total_bytes = test_case.size * test_case.iterations;
        const hw_throughput = (@as(f64, @floatFromInt(total_bytes)) / 1024.0 / 1024.0) /
            (@as(f64, @floatFromInt(hw_time)) / 1_000_000_000.0);
        const std_throughput = (@as(f64, @floatFromInt(total_bytes)) / 1024.0 / 1024.0) /
            (@as(f64, @floatFromInt(std_time)) / 1_000_000_000.0);

        std.log.debug("  {s}:", .{test_case.name});
        std.log.debug("    Hardware: {} ns total, {d:.2} MB/s", .{ hw_time, hw_throughput });
        std.log.debug("    Standard: {} ns total, {d:.2} MB/s", .{ std_time, std_throughput });
        std.log.debug("    Speedup: {d:.2}x", .{@as(f64, @floatFromInt(std_time)) / @as(f64, @floatFromInt(hw_time))});
    }

    // Benchmark Keccak256
    std.log.debug("\n=== Keccak256 Benchmarks ===", .{});
    for (test_cases) |test_case| {
        const data = try allocator.alloc(u8, test_case.size);
        defer allocator.free(data);

        // Fill with pseudo-random data
        for (data, 0..) |*byte, i| {
            byte.* = @as(u8, @intCast((i * 11 + 17) & 0xFF));
        }

        // Benchmark hardware-accelerated Keccak256
        timer.reset();
        var i: usize = 0;
        while (i < test_case.iterations) : (i += 1) {
            var output: [32]u8 = undefined;
            crypto.Keccak256_Accel.Keccak256_Accel.hash(data, &output);
        }
        const hw_time = timer.read();

        // Benchmark standard library Keccak256
        timer.reset();
        i = 0;
        while (i < test_case.iterations) : (i += 1) {
            var output: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(data, &output, .{});
        }
        const std_time = timer.read();

        // Calculate throughput in MB/s
        const total_bytes = test_case.size * test_case.iterations;
        const hw_throughput = (@as(f64, @floatFromInt(total_bytes)) / 1024.0 / 1024.0) /
            (@as(f64, @floatFromInt(hw_time)) / 1_000_000_000.0);
        const std_throughput = (@as(f64, @floatFromInt(total_bytes)) / 1024.0 / 1024.0) /
            (@as(f64, @floatFromInt(std_time)) / 1_000_000_000.0);

        std.log.debug("  {s}:", .{test_case.name});
        std.log.debug("    Hardware: {} ns total, {d:.2} MB/s", .{ hw_time, hw_throughput });
        std.log.debug("    Standard: {} ns total, {d:.2} MB/s", .{ std_time, std_throughput });
        std.log.debug("    Speedup: {d:.2}x", .{@as(f64, @floatFromInt(std_time)) / @as(f64, @floatFromInt(hw_time))});
    }

    // Benchmark EVM-specific patterns
    std.log.debug("\n=== EVM-Specific Pattern Benchmarks ===", .{});

    // Address generation (Keccak256 of public key)
    const pub_key = [_]u8{0x04} ++ [_]u8{0x42} ** 64; // Uncompressed public key
    timer.reset();
    var j: usize = 0;
    while (j < 10000) : (j += 1) {
        var hash: [32]u8 = undefined;
        crypto.Keccak256_Accel.Keccak256_Accel.hash(&pub_key, &hash);
        // Last 20 bytes would be the address
    }
    const addr_gen_time = timer.read();
    std.log.debug("  Address generation (10k operations): {} ns ({d:.2} addresses/sec)", .{ addr_gen_time, 10000.0 / (@as(f64, @floatFromInt(addr_gen_time)) / 1_000_000_000.0) });

    // Function selector computation
    const func_sig = "transfer(address,uint256)";
    timer.reset();
    j = 0;
    while (j < 100000) : (j += 1) {
        var hash: [32]u8 = undefined;
        crypto.Keccak256_Accel.Keccak256_Accel.hash(func_sig, &hash);
        // First 4 bytes would be the selector
    }
    const selector_time = timer.read();
    std.log.debug("  Function selector (100k operations): {} ns ({d:.2} selectors/sec)", .{ selector_time, 100000.0 / (@as(f64, @floatFromInt(selector_time)) / 1_000_000_000.0) });

    // Mixed workload simulation
    std.log.debug("\n=== Mixed Workload Simulation ===", .{});
    const workload_iterations = 1000;

    timer.reset();
    j = 0;
    while (j < workload_iterations) : (j += 1) {
        // Simulate various crypto operations in a transaction
        var hash: [32]u8 = undefined;

        // Address hashing
        const addr = [_]u8{0x12} ** 20;
        crypto.Keccak256_Accel.Keccak256_Accel.hash(&addr, &hash);

        // Function selector
        crypto.Keccak256_Accel.Keccak256_Accel.hash("balanceOf(address)", &hash);

        // Event data (128 bytes)
        const event_data = [_]u8{0xEF} ** 128;
        crypto.Keccak256_Accel.Keccak256_Accel.hash(&event_data, &hash);

        // SHA256 for some precompile work
        crypto.SHA256_Accel.SHA256_Accel.hash(&event_data, &hash);
    }
    const mixed_hw_time = timer.read();

    // Same workload with standard library
    timer.reset();
    j = 0;
    while (j < workload_iterations) : (j += 1) {
        var hash: [32]u8 = undefined;

        const addr = [_]u8{0x12} ** 20;
        std.crypto.hash.sha3.Keccak256.hash(&addr, &hash, .{});

        std.crypto.hash.sha3.Keccak256.hash("balanceOf(address)", &hash, .{});

        const event_data = [_]u8{0xEF} ** 128;
        std.crypto.hash.sha3.Keccak256.hash(&event_data, &hash, .{});

        var sha_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        sha_hasher.update(&event_data);
        sha_hasher.final(&hash);
    }
    const mixed_std_time = timer.read();

    std.log.debug("  Hardware-accelerated: {} ns", .{mixed_hw_time});
    std.log.debug("  Standard library: {} ns", .{mixed_std_time});
    std.log.debug("  Overall speedup: {d:.2}x", .{@as(f64, @floatFromInt(mixed_std_time)) / @as(f64, @floatFromInt(mixed_hw_time))});

    // Summary
    std.log.debug("\n=== Summary ===", .{});
    if (features.hasShaAcceleration() or features.hasSimdAcceleration()) {
        std.log.debug("✓ Hardware acceleration features detected and utilized", .{});
    } else {
        std.log.debug("ℹ No hardware acceleration features detected - using optimized software implementation", .{});
    }
}
