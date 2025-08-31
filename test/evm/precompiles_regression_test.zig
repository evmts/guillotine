/// Regression tests for EVM precompiles to ensure real implementations are used
/// These tests verify that we're not accidentally using stub implementations

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

const precompiles = evm.precompiles;
const Address = primitives.Address.Address;

test "ecPairing uses real BN254 implementation - not stub" {
    const allocator = testing.allocator;
    
    // Test with valid pairing input that should return true (1)
    // This is the simplest valid case: e(P, Q) * e(-P, Q) = 1
    // Where P is the generator point and Q is a specific point
    var input = [_]u8{0} ** 384; // Two pairs of (G1, G2) points
    
    // First pair: generator point G1 and a valid G2 point
    // G1 generator (in Montgomery form):
    input[31] = 1;  // x coordinate = 1
    input[63] = 2;  // y coordinate = 2
    
    // G2 point (simplified valid point)
    input[95] = 1;   // x1 
    input[127] = 0;  // x2
    input[159] = 1;  // y1
    input[191] = 0;  // y2
    
    // Second pair: negated G1 point and same G2 point
    input[192 + 31] = 1;  // x coordinate = 1 (same x)
    // For negation on elliptic curve, y coordinate is p - y
    // This is a simplified test - real negation would need proper field arithmetic
    input[192 + 63] = 3;  // y coordinate = p - 2 (simplified)
    
    // Same G2 point
    input[192 + 95] = 1;   // x1
    input[192 + 127] = 0;  // x2
    input[192 + 159] = 1;  // y1
    input[192 + 191] = 0;  // y2
    
    const result = try precompiles.execute_ecpairing(allocator, &input, 1_000_000);
    defer allocator.free(result.output);
    
    // The real implementation should either:
    // 1. Return success with valid output
    // 2. Return success=false if the input is invalid
    // But it should NOT return NotImplemented error
    
    try testing.expect(result.output.len == 32);
    try testing.expect(result.gas_used > 0);
}

test "ecPairing with empty input returns correct result" {
    const allocator = testing.allocator;
    
    // Empty input should return 1 (true) per EVM spec
    const empty_input = "";
    
    const result = try precompiles.execute_ecpairing(allocator, empty_input, 1_000_000);
    defer allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expect(result.output.len == 32);
    // Check that the last byte is 1 (true)
    try testing.expectEqual(@as(u8, 1), result.output[31]);
}

test "KZG point evaluation fails gracefully when uninitialized" {
    const allocator = testing.allocator;
    
    // Well-formed 192-byte input for point evaluation but with dummy values
    var input = [_]u8{0} ** 192;
    // Set a KZG version byte in the versioned hash position to look structurally valid
    input[0] = 0x01;
    
    const result = try precompiles.execute_point_evaluation(allocator, &input, 1_000_000);
    // No output is expected and success should be false because KZG is not initialized
    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "SHA256 precompile works correctly" {
    const allocator = testing.allocator;
    
    // Test with known input/output
    const input = "abc";
    const expected_hash = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    
    const result = try precompiles.execute_sha256(allocator, input, 1_000_000);
    defer allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqualSlices(u8, &expected_hash, result.output);
}

test "Identity precompile works correctly" {
    const allocator = testing.allocator;
    
    const input = "Hello, Ethereum!";
    const result = try precompiles.execute_identity(allocator, input, 1_000_000);
    defer allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqualSlices(u8, input, result.output);
}

test "ecRecover handles invalid signatures gracefully" {
    const allocator = testing.allocator;
    
    // Invalid signature (all zeros)
    const input = [_]u8{0} ** 128;
    
    const result = try precompiles.execute_ecrecover(allocator, &input, 10_000);
    defer allocator.free(result.output);
    
    // Should return success but with zero address
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Check all bytes are zero
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Ripemd160 precompile produces correct hash" {
    const allocator = testing.allocator;
    
    const input = "test";
    const result = try precompiles.execute_ripemd160(allocator, input, 10_000);
    defer allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // First 12 bytes should be zero (padding)
    for (result.output[0..12]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    
    // Last 20 bytes should contain the hash
    // The hash should not be all zeros if using real implementation
    var all_zeros = true;
    for (result.output[12..32]) |byte| {
        if (byte != 0) {
            all_zeros = false;
            break;
        }
    }
    try testing.expect(!all_zeros); // Should not be all zeros
}

test "modexp handles basic exponentiation" {
    const allocator = testing.allocator;
    
    // Test 3^4 mod 5 = 81 mod 5 = 1
    var input: [128]u8 = [_]u8{0} ** 128;
    
    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;
    // base = 3
    input[96] = 3;
    // exp = 4
    input[97] = 4;
    // mod = 5
    input[98] = 5;
    
    const result = try precompiles.execute_modexp(allocator, input[0..99], 10_000);
    defer allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 1), result.output[0]);
}

test "Blake2F compression function validates input length" {
    const allocator = testing.allocator;
    
    // Invalid input length (should be exactly 213 bytes)
    const invalid_input = [_]u8{0} ** 100;
    
    const result = try precompiles.execute_blake2f(allocator, &invalid_input, 10_000);
    
    // Should fail due to invalid input length
    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "All precompiles are recognized correctly" {
    // Test that all precompile addresses are correctly identified
    try testing.expect(precompiles.is_precompile(precompiles.ECRECOVER_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.SHA256_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.RIPEMD160_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.IDENTITY_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.MODEXP_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.ECADD_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.ECMUL_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.ECPAIRING_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.BLAKE2F_ADDRESS));
    try testing.expect(precompiles.is_precompile(precompiles.POINT_EVALUATION_ADDRESS));
    
    // Test non-precompile addresses
    try testing.expect(!precompiles.is_precompile(primitives.ZERO_ADDRESS));
    try testing.expect(precompiles.is_precompile(primitives.Address.from_u256(11))); // 0x0B is now BLS12-381 G1_ADD
    try testing.expect(precompiles.is_precompile(primitives.Address.from_u256(0x12))); // 0x12 is BLS12-381 MAP_FP_TO_G1
    try testing.expect(!precompiles.is_precompile(primitives.Address.from_u256(0x13))); // 0x13 is beyond precompiles
}

test "Gas costs are reasonable for all precompiles" {
    // Verify gas costs are non-zero and reasonable
    try testing.expect(precompiles.GasCosts.ECRECOVER > 0);
    try testing.expect(precompiles.GasCosts.SHA256_BASE > 0);
    try testing.expect(precompiles.GasCosts.RIPEMD160_BASE > 0);
    try testing.expect(precompiles.GasCosts.IDENTITY_BASE > 0);
    try testing.expect(precompiles.GasCosts.MODEXP_MIN > 0);
    try testing.expect(precompiles.GasCosts.ECADD > 0);
    try testing.expect(precompiles.GasCosts.ECMUL > 0);
    try testing.expect(precompiles.GasCosts.ECPAIRING_BASE > 0);
    try testing.expect(precompiles.GasCosts.BLAKE2F_PER_ROUND > 0);
    try testing.expect(precompiles.GasCosts.POINT_EVALUATION > 0);
}
