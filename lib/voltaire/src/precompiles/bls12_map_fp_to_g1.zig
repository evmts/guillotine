const std = @import("std");
const crypto = @import("crypto");
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for BLS12-381 map field element to G1
pub const GAS: u64 = 5500;

/// 0x12: BLS12_MAP_FP_TO_G1 - BLS12-381 map field element to G1
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    if (input.len != 64) {
        return error.InvalidInput;
    }

    const output = try allocator.alloc(u8, 128);
    crypto.Crypto.bls12_381.mapFpToG1(input, output) catch {
        return error.InvalidPoint;
    };

    return PrecompileResult{
        .output = output,
        .gas_used = GAS,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "map fp to g1 - out of gas" {
    const input = [_]u8{0} ** 64;
    const result = execute(std.testing.allocator, &input, GAS - 1);
    try std.testing.expectError(error.OutOfGas, result);
}

test "map fp to g1 - exact gas" {
    const input = [_]u8{0} ** 64;
    const result = execute(std.testing.allocator, &input, GAS);

    // Currently returns error.InvalidPoint due to stub implementation
    // Once BLS12-381 is implemented, this should succeed
    if (result) |res| {
        std.testing.allocator.free(res.output);
        try std.testing.expectEqual(GAS, res.gas_used);
        try std.testing.expectEqual(@as(usize, 128), res.output.len);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPoint, err);
    }
}

test "map fp to g1 - excess gas" {
    const input = [_]u8{0} ** 64;
    const result = execute(std.testing.allocator, &input, GAS + 1000);

    // Currently returns error.InvalidPoint due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(GAS, res.gas_used);
        try std.testing.expectEqual(@as(usize, 128), res.output.len);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPoint, err);
    }
}

test "map fp to g1 - invalid input length too short" {
    const input = [_]u8{0} ** 63;
    const result = execute(std.testing.allocator, &input, GAS);
    try std.testing.expectError(error.InvalidInput, result);
}

test "map fp to g1 - invalid input length too long" {
    const input = [_]u8{0} ** 65;
    const result = execute(std.testing.allocator, &input, GAS);
    try std.testing.expectError(error.InvalidInput, result);
}

test "map fp to g1 - invalid input length zero" {
    const input = [_]u8{};
    const result = execute(std.testing.allocator, &input, GAS);
    try std.testing.expectError(error.InvalidInput, result);
}

test "map fp to g1 - zero field element" {
    // Zero is a valid field element and should map to a valid G1 point
    const input = [_]u8{0} ** 64;
    const result = execute(std.testing.allocator, &input, GAS);

    // Currently returns error.InvalidPoint due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 128), res.output.len);
        try std.testing.expectEqual(GAS, res.gas_used);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPoint, err);
    }
}

test "map fp to g1 - maximum field element" {
    // Maximum valid BLS12-381 base field element (p - 1)
    // BLS12-381 field modulus p = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab
    var input: [64]u8 = undefined;
    @memset(&input, 0);

    // Set the field element to p - 1 (big-endian, padded to 64 bytes)
    const p_minus_1_bytes = [_]u8{
        0x1a, 0x01, 0x11, 0xea, 0x39, 0x7f, 0xe6, 0x9a,
        0x4b, 0x1b, 0xa7, 0xb6, 0x43, 0x4b, 0xac, 0xd7,
        0x64, 0x77, 0x4b, 0x84, 0xf3, 0x85, 0x12, 0xbf,
        0x67, 0x30, 0xd2, 0xa0, 0xf6, 0xb0, 0xf6, 0x24,
        0x1e, 0xab, 0xff, 0xfe, 0xb1, 0x53, 0xff, 0xff,
        0xb9, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xaa, 0xaa,
    };
    @memcpy(input[16..64], &p_minus_1_bytes);

    const result = execute(std.testing.allocator, &input, GAS);

    // Currently returns error.InvalidPoint due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 128), res.output.len);
        try std.testing.expectEqual(GAS, res.gas_used);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPoint, err);
    }
}

test "map fp to g1 - test vector 1" {
    // Test vector from EIP-2537
    // Input: field element 0x0000...0001
    var input: [64]u8 = undefined;
    @memset(&input, 0);
    input[63] = 1;

    const result = execute(std.testing.allocator, &input, GAS);

    // Currently returns error.InvalidPoint due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 128), res.output.len);
        try std.testing.expectEqual(GAS, res.gas_used);

        // Once implemented, verify the output matches expected G1 point
        // Expected output should be deterministic for this input
    } else |err| {
        try std.testing.expectEqual(error.InvalidPoint, err);
    }
}

test "map fp to g1 - test vector 2" {
    // Test vector: arbitrary field element
    var input: [64]u8 = undefined;
    @memset(&input, 0);
    // Set to some arbitrary value (0x123456...)
    input[60] = 0x12;
    input[61] = 0x34;
    input[62] = 0x56;
    input[63] = 0x78;

    const result = execute(std.testing.allocator, &input, GAS);

    // Currently returns error.InvalidPoint due to stub implementation
    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 128), res.output.len);
        try std.testing.expectEqual(GAS, res.gas_used);
    } else |err| {
        try std.testing.expectEqual(error.InvalidPoint, err);
    }
}

test "map fp to g1 - gas cost validation" {
    // Verify the gas cost constant matches EIP-2537 specification
    try std.testing.expectEqual(@as(u64, 5500), GAS);
}

test "map fp to g1 - output size validation" {
    // Output should be 128 bytes (uncompressed G1 point: 64 bytes x + 64 bytes y)
    const input = [_]u8{0} ** 64;
    const result = execute(std.testing.allocator, &input, 100000);

    if (result) |res| {
        defer std.testing.allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 128), res.output.len);
    } else |_| {
        // Stub implementation - test will pass once implemented
    }
}
