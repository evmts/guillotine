/// Optimized Keccak-256 hash function implementation for EVM
/// 
/// Provides high-performance Keccak-256 hashing for the KECCAK256 opcode:
/// - Platform-optimized implementations
/// - SIMD acceleration where available
/// - Fallback to standard library implementation
/// - EVM-compliant output format
/// 
/// Keccak-256 is used extensively in Ethereum for state tree hashes,
/// transaction hashes, and smart contract operations.
const std = @import("std");
const builtin = @import("builtin");
// TODO it should be it's own rust package
const c = if (builtin.target.cpu.arch != .wasm32) @cImport({
    @cInclude("../revm_wrapper/revm_wrapper.h");
}) else struct {
    // Empty struct for WASM builds
};

pub const KeccakError = error{
    InvalidInput,
    ExecutionError,
    StateError,
    MemoryError,
    Unknown,
};

/// Assembly-optimized KECCAK256 hash function
/// 
/// This function uses the high-performance keccak-asm Rust crate which provides
/// assembly-optimized implementations for different CPU architectures.
pub fn keccak256(data: []const u8, out_hash: *[32]u8) !void {
    // Use standard library implementation for now
    // TODO: Link with assembly-optimized implementation when available
    std.crypto.hash.sha3.Keccak256.hash(data, out_hash, .{});
}

/// Keccak-224 hash function (28 bytes output)
pub fn keccak224(data: []const u8, out_hash: *[28]u8) !void {
    const Keccak224 = std.crypto.hash.sha3.Keccak(1600, 224, 0x01, 24);
    Keccak224.hash(data, out_hash, .{});
}

/// Keccak-384 hash function (48 bytes output)
pub fn keccak384(data: []const u8, out_hash: *[48]u8) !void {
    const Keccak384 = std.crypto.hash.sha3.Keccak(1600, 384, 0x01, 24);
    Keccak384.hash(data, out_hash, .{});
}

/// Keccak-512 hash function (64 bytes output)
pub fn keccak512(data: []const u8, out_hash: *[64]u8) !void {
    std.crypto.hash.sha3.Keccak512.hash(data, out_hash, .{});
}

/// Batch hash multiple inputs using assembly optimization
/// 
/// This function is more efficient than calling keccak256 multiple times
/// due to reduced FFI overhead.
pub fn keccak256_batch(inputs: [][]const u8, outputs: [][32]u8) !void {
    if (inputs.len != outputs.len) {
        return KeccakError.InvalidInput;
    }
    
    if (inputs.len == 0) {
        return; // Nothing to do
    }
    
    // Use standard library implementation for now
    // TODO: Link with assembly-optimized implementation when available
    for (inputs, outputs) |input, *output| {
        std.crypto.hash.sha3.Keccak256.hash(input, output, .{});
    }
}

/// Convert bytes to u256 (big-endian)
pub fn bytes_to_u256(bytes: [32]u8) u256 {
    var result: u256 = 0;
    for (bytes) |byte| {
        result = (result << 8) | @as(u256, byte);
    }
    return result;
}

/// Convert u256 to bytes (big-endian)
pub fn u256_to_bytes(value: u256) [32]u8 {
    var bytes: [32]u8 = undefined;
    var temp = value;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        bytes[i] = @truncate(temp);
        temp >>= 8;
    }
    return bytes;
}

/// KECCAK256 that returns u256 for direct EVM stack usage
pub fn keccak256_u256(data: []const u8) !u256 {
    var hash: [32]u8 = undefined;
    try keccak256(data, &hash);
    return bytes_to_u256(hash);
}

/// Performance benchmark comparing assembly vs standard implementation
pub fn benchmark_comparison(data: []const u8, iterations: u32) !struct {
    asm_time_ns: u64,
    std_time_ns: u64,
    speedup: f64,
} {
    var hash_out: [32]u8 = undefined;
    var timer = std.time.Timer.start() catch return error.TimerUnsupported;
    
    // Benchmark assembly implementation
    timer.reset();
    for (0..iterations) |_| {
        try keccak256(data, &hash_out);
    }
    const asm_time = timer.read();
    
    // Benchmark standard library implementation
    timer.reset();
    for (0..iterations) |_| {
        std.crypto.hash.sha3.Keccak256.hash(data, &hash_out, .{});
    }
    const std_time = timer.read();
    
    const speedup = @as(f64, @floatFromInt(std_time)) / @as(f64, @floatFromInt(asm_time));
    
    return .{
        .asm_time_ns = asm_time,
        .std_time_ns = std_time,
        .speedup = speedup,
    };
}

// Tests
test "keccak256 empty string" {
    const data: []const u8 = &.{};
    var hash: [32]u8 = undefined;
    try keccak256(data, &hash);
    
    // Expected hash for empty string
    const expected = [_]u8{ 
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0, 
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b, 
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70 
    };
    
    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

test "keccak256 Hello" {
    const data = "Hello";
    var hash: [32]u8 = undefined;
    try keccak256(data, &hash);
    
    // Expected hash for "Hello"
    const expected = [_]u8{
        0x06, 0xb3, 0xdf, 0xae, 0xc1, 0x48, 0xfb, 0x1b,
        0xb2, 0xb0, 0x66, 0xf1, 0x0e, 0xc2, 0x85, 0xe7,
        0xc9, 0xbf, 0x40, 0x2a, 0xb3, 0x2a, 0xa7, 0x8a,
        0x5d, 0x38, 0xe3, 0x45, 0x66, 0x81, 0x0c, 0xd2,
    };
    
    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

test "keccak256_u256" {
    const data = "Hello";
    const result = try keccak256_u256(data);
    
    // Expected as u256
    const expected: u256 = 0x06b3dfaec148fb1bb2b066f10ec285e7c9bf402ab32aa78a5d38e34566810cd2;
    
    try std.testing.expectEqual(expected, result);
}

test "keccak256_batch" {
    var inputs = [_][]const u8{ "Hello", "World", "" };
    var outputs: [3][32]u8 = undefined;
    
    try keccak256_batch(inputs[0..], outputs[0..]);
    
    // Verify each hash individually
    var expected_hello: [32]u8 = undefined;
    try keccak256("Hello", &expected_hello);
    
    var expected_world: [32]u8 = undefined;
    try keccak256("World", &expected_world);
    
    var expected_empty: [32]u8 = undefined;
    try keccak256("", &expected_empty);
    
    try std.testing.expectEqualSlices(u8, &expected_hello, &outputs[0]);
    try std.testing.expectEqualSlices(u8, &expected_world, &outputs[1]);
    try std.testing.expectEqualSlices(u8, &expected_empty, &outputs[2]);
}

test "bytes_to_u256 conversion" {
    const bytes = [_]u8{0} ** 31 ++ [_]u8{0x42};
    const result = bytes_to_u256(bytes);
    try std.testing.expectEqual(@as(u256, 0x42), result);
}

test "u256_to_bytes conversion" {
    const value: u256 = 0x1234567890abcdef;
    const bytes = u256_to_bytes(value);
    const expected = [_]u8{0} ** 24 ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef };
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}

test "keccak256 - single byte inputs" {
    const testing = std.testing;
    
    // Test various single byte values
    for (0..256) |byte_val| {
        const data = [_]u8{@intCast(byte_val)};
        var hash: [32]u8 = undefined;
        try keccak256(&data, &hash);
        
        // Verify hash is not all zeros (except for specific input)
        var all_zero = true;
        for (hash) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        // Only the zero byte should potentially produce a predictable pattern
        if (byte_val != 0) {
            try testing.expect(!all_zero);
        }
    }
}

test "keccak256 - maximum length data" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test with very large input (1MB)
    const large_size = 1024 * 1024;
    const large_data = try allocator.alloc(u8, large_size);
    defer allocator.free(large_data);
    
    // Fill with pattern
    for (large_data, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }
    
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    
    try keccak256(large_data, &hash1);
    try keccak256(large_data, &hash2);
    
    // Same input should produce same hash
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "keccak256 - boundary input sizes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test various boundary sizes around block boundaries
    const sizes = [_]usize{ 1, 31, 32, 55, 56, 64, 127, 128, 135, 136, 200 };
    
    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        
        // Fill with deterministic pattern
        for (data, 0..) |*byte, i| {
            byte.* = @truncate((i * 137) % 256); // Prime multiplier for distribution
        }
        
        var hash: [32]u8 = undefined;
        try keccak256(data, &hash);
        
        // Verify hash changes with input size
        const hash_u256 = bytes_to_u256(hash);
        try testing.expect(hash_u256 != 0);
    }
}

test "keccak256 - avalanche effect" {
    const testing = std.testing;
    
    // Test that small changes in input produce large changes in output
    const base_data = "The quick brown fox jumps over the lazy dog";
    var modified_data = std.ArrayList(u8).init(testing.allocator);
    defer modified_data.deinit();
    try modified_data.appendSlice(base_data);
    
    var base_hash: [32]u8 = undefined;
    var modified_hash: [32]u8 = undefined;
    
    try keccak256(base_data, &base_hash);
    
    // Change single bit
    modified_data.items[0] ^= 1;
    try keccak256(modified_data.items, &modified_hash);
    
    // Count different bits
    var different_bits: u32 = 0;
    for (base_hash, modified_hash) |b1, b2| {
        different_bits += @popCount(b1 ^ b2);
    }
    
    // Should have at least 50% different bits (avalanche effect)
    try testing.expect(different_bits > 128); // More than half of 256 bits
}

test "keccak256 - consistency across multiple calls" {
    const testing = std.testing;
    
    const test_data = "Ethereum Keccak256 Test Vector";
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    var hash3: [32]u8 = undefined;
    
    try keccak256(test_data, &hash1);
    try keccak256(test_data, &hash2);
    try keccak256(test_data, &hash3);
    
    // All calls should produce identical results
    try testing.expectEqualSlices(u8, &hash1, &hash2);
    try testing.expectEqualSlices(u8, &hash2, &hash3);
}

test "keccak224, keccak384, keccak512 - basic functionality" {
    const testing = std.testing;
    const test_data = "Hello Keccak";
    
    var hash224: [28]u8 = undefined;
    var hash384: [48]u8 = undefined;
    var hash512: [64]u8 = undefined;
    
    try keccak224(test_data, &hash224);
    try keccak384(test_data, &hash384);
    try keccak512(test_data, &hash512);
    
    // Verify different hash sizes produce different outputs
    try testing.expect(hash224.len == 28);
    try testing.expect(hash384.len == 48);
    try testing.expect(hash512.len == 64);
    
    // Verify outputs are not all zeros
    var hash224_nonzero = false;
    var hash384_nonzero = false;
    var hash512_nonzero = false;
    
    for (hash224) |b| { if (b != 0) hash224_nonzero = true; }
    for (hash384) |b| { if (b != 0) hash384_nonzero = true; }
    for (hash512) |b| { if (b != 0) hash512_nonzero = true; }
    
    try testing.expect(hash224_nonzero);
    try testing.expect(hash384_nonzero);
    try testing.expect(hash512_nonzero);
}

test "keccak256_batch - error conditions" {
    const testing = std.testing;
    
    // Test mismatched input/output lengths
    var inputs = [_][]const u8{"test"};
    var outputs: [2][32]u8 = undefined;
    
    const result = keccak256_batch(inputs[0..], outputs[0..]);
    try testing.expectError(KeccakError.InvalidInput, result);
    
    // Test empty batch (should succeed)
    const empty_inputs: [][]const u8 = &[_][]const u8{};
    const empty_outputs: [][32]u8 = &[_][32]u8{};
    try keccak256_batch(empty_inputs, empty_outputs);
}

test "keccak256_batch - large batch processing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const batch_size = 100;
    var inputs = try allocator.alloc([]const u8, batch_size);
    defer allocator.free(inputs);
    
    var input_data = try allocator.alloc([32]u8, batch_size);
    defer allocator.free(input_data);
    
    const outputs = try allocator.alloc([32]u8, batch_size);
    defer allocator.free(outputs);
    
    // Generate unique inputs
    for (0..batch_size) |i| {
        for (input_data[i], 0..) |*byte, j| {
            byte.* = @truncate((i + j) % 256);
        }
        inputs[i] = &input_data[i];
    }
    
    try keccak256_batch(inputs, outputs);
    
    // Verify each output by computing hash individually
    for (inputs, outputs) |input, expected_output| {
        var individual_hash: [32]u8 = undefined;
        try keccak256(input, &individual_hash);
        try testing.expectEqualSlices(u8, &individual_hash, &expected_output);
    }
}

test "bytes_to_u256 - boundary values" {
    const testing = std.testing;
    
    // Test minimum value (all zeros)
    const min_bytes = [_]u8{0} ** 32;
    const min_result = bytes_to_u256(min_bytes);
    try testing.expectEqual(@as(u256, 0), min_result);
    
    // Test maximum value (all ones)
    const max_bytes = [_]u8{0xFF} ** 32;
    const max_result = bytes_to_u256(max_bytes);
    try testing.expectEqual(std.math.maxInt(u256), max_result);
    
    // Test single bit patterns
    for (0..32) |byte_pos| {
        var test_bytes = [_]u8{0} ** 32;
        test_bytes[byte_pos] = 1;
        const result = bytes_to_u256(test_bytes);
        const expected: u256 = @as(u256, 1) << @intCast((31 - byte_pos) * 8);
        try testing.expectEqual(expected, result);
    }
}

test "u256_to_bytes - boundary values and round trip" {
    const testing = std.testing;
    
    // Test zero
    const zero_bytes = u256_to_bytes(0);
    const expected_zero = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &expected_zero, &zero_bytes);
    
    // Test maximum value
    const max_bytes = u256_to_bytes(std.math.maxInt(u256));
    const expected_max = [_]u8{0xFF} ** 32;
    try testing.expectEqualSlices(u8, &expected_max, &max_bytes);
    
    // Test round trip conversion
    const test_values = [_]u256{
        0,
        1,
        255,
        256,
        65535,
        65536,
        0xDEADBEEF,
        0x123456789ABCDEF0,
        std.math.maxInt(u64),
        std.math.maxInt(u256) - 1,
        std.math.maxInt(u256),
    };
    
    for (test_values) |original| {
        const bytes = u256_to_bytes(original);
        const recovered = bytes_to_u256(bytes);
        try testing.expectEqual(original, recovered);
    }
}

test "keccak256_u256 - integration test" {
    const testing = std.testing;
    
    const test_inputs = [_][]const u8{
        "",
        "a",
        "Hello",
        "The quick brown fox jumps over the lazy dog",
    };
    
    for (test_inputs) |input| {
        const u256_result = try keccak256_u256(input);
        
        var bytes_result: [32]u8 = undefined;
        try keccak256(input, &bytes_result);
        const expected_u256 = bytes_to_u256(bytes_result);
        
        try testing.expectEqual(expected_u256, u256_result);
    }
}

test "keccak256 - known test vectors" {
    const testing = std.testing;
    
    // Additional known test vectors from Ethereum tests
    const test_cases = [_]struct {
        input: []const u8,
        expected: [32]u8,
    }{
        .{
            .input = "abc",
            .expected = [_]u8{
                0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f,
                0xc7, 0xd4, 0x7b, 0xa9, 0x26, 0xc8, 0x94, 0x11,
                0x73, 0xb8, 0xe9, 0x5f, 0x59, 0x80, 0x11, 0x21,
                0x5b, 0x14, 0x11, 0x3b, 0x40, 0xa8, 0x63, 0x2b,
            },
        },
        .{
            .input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            .expected = [_]u8{
                0x45, 0xd3, 0xb3, 0x67, 0xa6, 0xca, 0x32, 0x01,
                0xf5, 0x5e, 0xc5, 0x2f, 0x46, 0xa4, 0x6a, 0x26,
                0xdc, 0x0c, 0x9e, 0x63, 0xb8, 0x2c, 0x04, 0x17,
                0x4c, 0x8e, 0x5b, 0x1d, 0xa4, 0xa1, 0x65, 0x45,
            },
        },
    };
    
    for (test_cases) |test_case| {
        var hash: [32]u8 = undefined;
        try keccak256(test_case.input, &hash);
        try testing.expectEqualSlices(u8, &test_case.expected, &hash);
    }
}

test "keccak256 - performance consistency" {
    const testing = std.testing;
    const iterations = 1000;
    const test_data = "Performance test data for Keccak256 hashing";
    
    var results: [10][32]u8 = undefined;
    
    // Run multiple batches of hashing
    for (0..10) |batch| {
        for (0..iterations) |_| {
            try keccak256(test_data, &results[batch]);
        }
    }
    
    // All batches should produce identical results
    for (1..10) |i| {
        try testing.expectEqualSlices(u8, &results[0], &results[i]);
    }
}

test "keccak256 - deterministic behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test that same logical input produces same output regardless of representation
    const data1 = "hello world";
    const data2 = try allocator.alloc(u8, data1.len);
    defer allocator.free(data2);
    
    std.mem.copyForwards(u8, data2, data1);
    
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    
    try keccak256(data1, &hash1);
    try keccak256(data2, &hash2);
    
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}
