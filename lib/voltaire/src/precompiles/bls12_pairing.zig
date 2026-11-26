const std = @import("std");
const crypto = @import("crypto");
const PrecompileError = @import("common.zig").PrecompileError;
const backend_error = @import("bls12_backend_error.zig");
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for BLS12-381 pairing
pub const BASE_GAS: u64 = 37700;
pub const PER_PAIR_GAS: u64 = 32600;

/// 0x0F: BLS12_PAIRING_CHECK - BLS12-381 pairing check
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    // EIP-2537: empty input is an error.
    if (input.len % 384 != 0 or input.len == 0) {
        return error.InvalidInput;
    }

    const k = input.len / 384;
    const gas_cost = BASE_GAS + PER_PAIR_GAS * k;

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 32);
    errdefer allocator.free(output);
    @memset(output, 0);

    const success = crypto.Crypto.bls12_381.pairingCheck(input) catch |err| {
        return backend_error.precompileError(err, error.InvalidPairing);
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

test "bls12_pairing - empty input is an error" {
    // EIP-2537: "must return an error if the input is empty", whatever gas is supplied.
    const input = [_]u8{};
    try std.testing.expectError(error.InvalidInput, execute(std.testing.allocator, &input, 1_000_000));
    try std.testing.expectError(error.InvalidInput, execute(std.testing.allocator, &input, 0));
}

test "bls12_pairing - single pair exact gas" {
    // Single pair: G1 point (128 bytes) + G2 point (256 bytes) = 384 bytes
    const input = @as([384]u8, @splat(0));
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
    const input = @as([384]u8, @splat(0));
    const expected_gas = BASE_GAS + PER_PAIR_GAS;
    const result = execute(std.testing.allocator, &input, expected_gas - 1);
    try std.testing.expectError(error.OutOfGas, result);
}

test "bls12_pairing - two pairs exact gas" {
    // Two pairs: 2 * 384 = 768 bytes
    const input = @as([768]u8, @splat(0));
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
    const input = @as([1152]u8, @splat(0));
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
    const input = @as([383]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, 1000000);
    try std.testing.expectError(error.InvalidInput, result);
}

test "bls12_pairing - invalid input length 1" {
    const input = [_]u8{0};
    const result = execute(std.testing.allocator, &input, 1000000);
    try std.testing.expectError(error.InvalidInput, result);
}

test "bls12_pairing - invalid input length 385" {
    const input = @as([385]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, 1000000);
    try std.testing.expectError(error.InvalidInput, result);
}

test "bls12_pairing - gas cost constants validation" {
    // Verify gas cost constants match EIP-2537 specification
    try std.testing.expectEqual(@as(u64, 37700), BASE_GAS);
    try std.testing.expectEqual(@as(u64, 32600), PER_PAIR_GAS);
}

test "bls12_pairing - gas cost calculation" {
    // EIP-2537: 32600 * k + 37700
    try std.testing.expectEqual(@as(u64, 70300), BASE_GAS + 1 * PER_PAIR_GAS);
    try std.testing.expectEqual(@as(u64, 102900), BASE_GAS + 2 * PER_PAIR_GAS);
    try std.testing.expectEqual(@as(u64, 200700), BASE_GAS + 5 * PER_PAIR_GAS);
}

test "bls12_pairing - output format" {
    // One pair of points at infinity: e(O, O) = 1, so the check succeeds.
    const input = @as([384]u8, @splat(0));
    const res = try execute(std.testing.allocator, &input, BASE_GAS + PER_PAIR_GAS);
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(BASE_GAS + PER_PAIR_GAS, res.gas_used);
    try std.testing.expectEqual(@as(usize, 32), res.output.len);
    for (res.output[0..31]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    try std.testing.expectEqual(@as(u8, 1), res.output[31]);
}

test "bls12_pairing - large number of pairs gas calculation" {
    // Test with 10 pairs
    const k: u64 = 10;
    const input = @as([(384 * k)]u8, @splat(0));
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
    const test_sizes = [_]usize{ 384, 768, 1152 };

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

test "EIP-2537 pairing rejects padding and noncanonical field elements without leaking" {
    var input = @as([384]u8, @splat(0));
    const modulus: u512 = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;
    for (0..6) |slot| {
        const offset = slot * 64;
        for (0..16) |padding| {
            input[offset + padding] = 1;
            try std.testing.expectError(error.InvalidPairing, execute(std.testing.allocator, &input, 1_000_000));
            input[offset + padding] = 0;
        }
        std.mem.writeInt(u512, input[offset..][0..64], modulus, .big);
        try std.testing.expectError(error.InvalidPairing, execute(std.testing.allocator, &input, 1_000_000));
        @memset(input[offset..][0..64], 0);
    }
}
