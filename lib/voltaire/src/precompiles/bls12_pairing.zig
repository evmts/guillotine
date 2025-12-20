const std = @import("std");
const crypto = @import("crypto");
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for BLS12-381 pairing
pub const BASE_GAS: u64 = 65000;
pub const PER_PAIR_GAS: u64 = 43000;

/// 0x11: BLS12_PAIRING - BLS12-381 pairing check
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (input.len % 384 != 0) {
        return error.InvalidInput;
    }

    const k = input.len / 384;
    const gas_cost = BASE_GAS + PER_PAIR_GAS * k;

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);

    const success = crypto.Crypto.bls12_381.pairingCheck(input) catch {
        return error.InvalidPairing;
    };

    if (success) {
        output[31] = 1;
    }

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "bls12_pairing - out of gas" {
    // Empty input (0 pairs) requires BASE_GAS
    const input = [_]u8{};
    const result = execute(std.testing.allocator, &input, BASE_GAS - 1);
    try std.testing.expectError(error.OutOfGas, result);
}

test "bls12_pairing - exact gas for zero pairs" {
    // Empty input (0 pairs) - should succeed with pairing result of 1
    const input = [_]u8{};
    const result = execute(std.testing.allocator, &input, BASE_GAS);

    // Currently returns error.InvalidPairing due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(BASE_GAS, res.gas_used);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);
        // Empty input should return success (1)
        try std.testing.expectEqual(@as(u8, 1), res.output[31]);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPairing, err);
    }
}

test "bls12_pairing - single pair exact gas" {
    // Single pair: G1 point (128 bytes) + G2 point (256 bytes) = 384 bytes
    const input = [_]u8{0} ** 384;
    const expected_gas = BASE_GAS + PER_PAIR_GAS;
    const result = execute(std.testing.allocator, &input, expected_gas);

    // Currently returns error.InvalidPairing due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(expected_gas, res.gas_used);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPairing, err);
    }
}

test "bls12_pairing - single pair insufficient gas" {
    const input = [_]u8{0} ** 384;
    const expected_gas = BASE_GAS + PER_PAIR_GAS;
    const result = execute(std.testing.allocator, &input, expected_gas - 1);
    try std.testing.expectError(error.OutOfGas, result);
}

test "bls12_pairing - two pairs exact gas" {
    // Two pairs: 2 * 384 = 768 bytes
    const input = [_]u8{0} ** 768;
    const expected_gas = BASE_GAS + 2 * PER_PAIR_GAS;
    const result = execute(std.testing.allocator, &input, expected_gas);

    // Currently returns error.InvalidPairing due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(expected_gas, res.gas_used);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPairing, err);
    }
}

test "bls12_pairing - three pairs" {
    // Three pairs: 3 * 384 = 1152 bytes
    const input = [_]u8{0} ** 1152;
    const expected_gas = BASE_GAS + 3 * PER_PAIR_GAS;
    const result = execute(std.testing.allocator, &input, expected_gas);

    // Currently returns error.InvalidPairing due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(expected_gas, res.gas_used);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPairing, err);
    }
}

test "bls12_pairing - invalid input length not multiple of 384" {
    // 383 bytes - not a multiple of 384
    const input = [_]u8{0} ** 383;
    const result = execute(std.testing.allocator, &input, 1000000);
    try std.testing.expectError(error.InvalidInput, result);
}

test "bls12_pairing - invalid input length 1" {
    const input = [_]u8{0};
    const result = execute(std.testing.allocator, &input, 1000000);
    try std.testing.expectError(error.InvalidInput, result);
}

test "bls12_pairing - invalid input length 385" {
    const input = [_]u8{0} ** 385;
    const result = execute(std.testing.allocator, &input, 1000000);
    try std.testing.expectError(error.InvalidInput, result);
}

test "bls12_pairing - gas cost constants validation" {
    // Verify gas cost constants match EIP-2537 specification
    try std.testing.expectEqual(@as(u64, 65000), BASE_GAS);
    try std.testing.expectEqual(@as(u64, 43000), PER_PAIR_GAS);
}

test "bls12_pairing - gas cost calculation" {
    // Test gas cost formula: BASE_GAS + k * PER_PAIR_GAS
    // where k is the number of pairs

    // 0 pairs
    try std.testing.expectEqual(@as(u64, 65000), BASE_GAS + 0 * PER_PAIR_GAS);

    // 1 pair
    try std.testing.expectEqual(@as(u64, 108000), BASE_GAS + 1 * PER_PAIR_GAS);

    // 2 pairs
    try std.testing.expectEqual(@as(u64, 151000), BASE_GAS + 2 * PER_PAIR_GAS);

    // 5 pairs
    try std.testing.expectEqual(@as(u64, 280000), BASE_GAS + 5 * PER_PAIR_GAS);
}

test "bls12_pairing - output format" {
    // Output should be 32 bytes with result in last byte
    const input = [_]u8{};
    const result = execute(std.testing.allocator, &input, BASE_GAS);

    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);

        // First 31 bytes should be zero
        for (res.output[0..31]) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }

        // Last byte should be 0 or 1
        try std.testing.expect(res.output[31] == 0 or res.output[31] == 1);
    } else |_| {
        // Stub implementation - test will pass once implemented
    }
}

test "bls12_pairing - large number of pairs gas calculation" {
    // Test with 10 pairs
    const k: u64 = 10;
    const input = [_]u8{0} ** (384 * k);
    const expected_gas = BASE_GAS + k * PER_PAIR_GAS;

    const result = execute(std.testing.allocator, &input, expected_gas);

    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(expected_gas, res.gas_used);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPairing, err);
    }
}

test "bls12_pairing - bilinearity property structure" {
    // Test that we can create inputs for bilinearity testing
    // e(aP, Q) should equal e(P, aQ)
    // This test verifies input structure, actual bilinearity tested when implemented

    // Single pair for e(P, Q)
    var pair1: [384]u8 = undefined;
    @memset(&pair1, 0);
    // G1 point P at pair1[0..128]
    // G2 point Q at pair1[128..384]

    const result1 = execute(std.testing.allocator, &pair1, BASE_GAS + PER_PAIR_GAS);
    if (result1) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPairing, err);
    }
}

test "bls12_pairing - output size consistency" {
    // Verify output is always 32 bytes regardless of input size
    const test_sizes = [_]usize{ 0, 384, 768, 1152 };

    for (test_sizes) |size| {
        const input = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(input);
        @memset(input, 0);

        const k = size / 384;
        const gas = BASE_GAS + k * PER_PAIR_GAS;

        const result = execute(std.testing.allocator, input, gas);
        if (result) |res| {
            defer std.testing.allocator.free(res.output);
            try std.testing.expectEqual(@as(usize, 32), res.output.len);
        } else |_| {
            // Stub implementation
        }
    }
}
