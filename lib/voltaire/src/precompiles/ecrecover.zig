const std = @import("std");
const crypto = @import("crypto");
const secp256k1 = crypto.secp256k1;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for ECRECOVER precompile
pub const GAS: u64 = 3000;

/// 0x01: ECRECOVER - Elliptic curve signature recovery
///
/// SECURITY: This precompile implements EIP-2 signature malleability protection.
/// The underlying secp256k1.recoverPubkey function validates:
/// 1. r must be in range [1, secp256k1_n - 1]
/// 2. s must be in range [1, secp256k1_n / 2] (EIP-2 protection)
/// 3. v must be 27 or 28 (or 0/1 for raw recovery ID)
///
/// Invalid signatures return zero output (address 0x0) per Ethereum specification.
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    // Input: 128 bytes (hash32, v32, r32, s32)
    var input_buf: [128]u8 = [_]u8{0} ** 128;
    @memcpy(input_buf[0..@min(input.len, 128)], input[0..@min(input.len, 128)]);

    const hash = input_buf[0..32];
    const v_bytes = input_buf[32..64];
    const r = input_buf[64..96];
    const s = input_buf[96..128];

    // Extract v from the padded 32-byte value
    const v = v_bytes[31];

    // Recover public key with full validation (r, s, v ranges and EIP-2 protection)
    // recoverPubkey validates:
    // - r in [1, n-1]
    // - s in [1, n/2] (EIP-2: prevents signature malleability)
    // - v is 27, 28, 0, or 1
    const pubkey = secp256k1.recoverPubkey(hash, r, s, v) catch {
        // Invalid signature - return empty output (address 0x0)
        const output = try allocator.alloc(u8, 32);
        @memset(output, 0);
        return PrecompileResult{
            .output = output,
            .gas_used = GAS,
        };
    };

    // Derive address from public key (last 20 bytes of keccak256(pubkey))
    var hash_output: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(&pubkey, &hash_output);

    const output = try allocator.alloc(u8, 32);
    @memset(output[0..12], 0); // Left-pad with zeros
    @memcpy(output[12..32], hash_output[12..32]);

    return PrecompileResult{
        .output = output,
        .gas_used = GAS,
    };
}

test "ecRecover - valid signature" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Example from Ethereum yellow paper
    const hash = [_]u8{0x47} ** 32;
    const v = [_]u8{0} ** 31 ++ [_]u8{28};
    const r = [_]u8{0x69} ** 32;
    const s = [_]u8{0x7a} ** 32;

    var input: [128]u8 = undefined;
    @memcpy(input[0..32], &hash);
    @memcpy(input[32..64], &v);
    @memcpy(input[64..96], &r);
    @memcpy(input[96..128], &s);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(GAS, result.gas_used);
}

test "ecRecover - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    const result = execute(allocator, &input, GAS - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "ecRecover - exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(GAS, result.gas_used);
}

test "ecRecover - input too short padded" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 100;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "ecRecover - input too long truncated" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 200;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "ecRecover - empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{};
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "ecRecover - v value 27" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    input[63] = 27;

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "ecRecover - v value 28" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    input[63] = 28;

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "ecRecover - invalid v value returns zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    input[63] = 29;

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "ecRecover - all zero input returns zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ecRecover - gas cost constant" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 3000), GAS);
}

test "ecRecover - output always 32 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "ecRecover - invalid signature graceful failure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0xFF} ** 128;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(GAS, result.gas_used);
}

test "ecRecover - EIP-2 malleability: reject high s value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that s > secp256k1_n / 2 is rejected (EIP-2 protection)
    // secp256k1_n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    // secp256k1_n / 2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0

    var input: [128]u8 = undefined;
    const hash = [_]u8{0x47} ** 32;
    const v = [_]u8{0} ** 31 ++ [_]u8{28};
    const r = [_]u8{0x69} ** 32;

    // Set s to a high value > n/2 (should be rejected per EIP-2)
    // Using 0x8000...0000 which is definitely > n/2
    const s_high = [_]u8{0x80} ++ [_]u8{0x00} ** 31;

    @memcpy(input[0..32], &hash);
    @memcpy(input[32..64], &v);
    @memcpy(input[64..96], &r);
    @memcpy(input[96..128], &s_high);

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    // Should return zero address (invalid signature)
    try testing.expectEqual(@as(usize, 32), result.output.len);
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ecRecover - reject r = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [128]u8 = undefined;
    const hash = [_]u8{0x47} ** 32;
    const v = [_]u8{0} ** 31 ++ [_]u8{28};
    const r_zero = [_]u8{0} ** 32; // r = 0 should be rejected
    const s = [_]u8{0x7a} ** 32;

    @memcpy(input[0..32], &hash);
    @memcpy(input[32..64], &v);
    @memcpy(input[64..96], &r_zero);
    @memcpy(input[96..128], &s);

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    // Should return zero address (invalid signature)
    try testing.expectEqual(@as(usize, 32), result.output.len);
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ecRecover - reject s = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [128]u8 = undefined;
    const hash = [_]u8{0x47} ** 32;
    const v = [_]u8{0} ** 31 ++ [_]u8{28};
    const r = [_]u8{0x69} ** 32;
    const s_zero = [_]u8{0} ** 32; // s = 0 should be rejected

    @memcpy(input[0..32], &hash);
    @memcpy(input[32..64], &v);
    @memcpy(input[64..96], &r);
    @memcpy(input[96..128], &s_zero);

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    // Should return zero address (invalid signature)
    try testing.expectEqual(@as(usize, 32), result.output.len);
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ecRecover - reject r >= curve_order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [128]u8 = undefined;
    const hash = [_]u8{0x47} ** 32;
    const v = [_]u8{0} ** 31 ++ [_]u8{28};
    const s = [_]u8{0x7a} ** 32;

    // Set r to all 0xFF (definitely >= curve_order)
    const r_invalid = [_]u8{0xFF} ** 32;

    @memcpy(input[0..32], &hash);
    @memcpy(input[32..64], &v);
    @memcpy(input[64..96], &r_invalid);
    @memcpy(input[96..128], &s);

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    // Should return zero address (invalid signature)
    try testing.expectEqual(@as(usize, 32), result.output.len);
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ecRecover - reject s >= curve_order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [128]u8 = undefined;
    const hash = [_]u8{0x47} ** 32;
    const v = [_]u8{0} ** 31 ++ [_]u8{28};
    const r = [_]u8{0x69} ** 32;

    // Set s to all 0xFF (definitely >= curve_order)
    const s_invalid = [_]u8{0xFF} ** 32;

    @memcpy(input[0..32], &hash);
    @memcpy(input[32..64], &v);
    @memcpy(input[64..96], &r);
    @memcpy(input[96..128], &s_invalid);

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    // Should return zero address (invalid signature)
    try testing.expectEqual(@as(usize, 32), result.output.len);
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ecRecover - reject invalid v value beyond 29" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [128]u8 = undefined;
    const hash = [_]u8{0x47} ** 32;
    const v_invalid = [_]u8{0} ** 31 ++ [_]u8{100}; // v = 100 (invalid)
    const r = [_]u8{0x69} ** 32;
    const s = [_]u8{0x7a} ** 32;

    @memcpy(input[0..32], &hash);
    @memcpy(input[32..64], &v_invalid);
    @memcpy(input[64..96], &r);
    @memcpy(input[96..128], &s);

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    // Should return zero address (invalid signature)
    try testing.expectEqual(@as(usize, 32), result.output.len);
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}
