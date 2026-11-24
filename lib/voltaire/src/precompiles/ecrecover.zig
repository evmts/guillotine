const std = @import("std");
const crypto = @import("crypto");
const secp256k1 = crypto.secp256k1;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for ECRECOVER precompile
pub const GAS: u64 = 3000;

/// 0x01: ECRECOVER - Elliptic curve signature recovery
///
/// Input: 128 bytes (hash32, v32, r32, s32), right-padded with zeros when shorter.
/// Validation follows the Yellow Paper (Appendix E), not transaction rules:
/// 1. v must be the full 32-byte word 27 or 28
/// 2. r and s must be in range [1, secp256k1_n - 1]; high s is allowed (EIP-2 limits transactions only)
///
/// A failed recovery returns empty output, so the caller sees RETURNDATASIZE 0.
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    var input_buf: [128]u8 = [_]u8{0} ** 128;
    @memcpy(input_buf[0..@min(input.len, 128)], input[0..@min(input.len, 128)]);

    const hash = input_buf[0..32];
    const v = std.mem.readInt(u256, input_buf[32..64], .big);
    const r = std.mem.readInt(u256, input_buf[64..96], .big);
    const s = std.mem.readInt(u256, input_buf[96..128], .big);

    if (v != 27 and v != 28) return empty(allocator);
    const pubkey = secp256k1.recoverPubkeyAnyS(hash, r, s, @intCast(v - 27)) catch return empty(allocator);

    // Address is the last 20 bytes of keccak256(pubkey), left-padded to 32 bytes.
    var hash_output: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(&pubkey, &hash_output);

    const output = try allocator.alloc(u8, 32);
    @memset(output[0..12], 0);
    @memcpy(output[12..32], hash_output[12..32]);

    return PrecompileResult{
        .output = output,
        .gas_used = GAS,
    };
}

fn empty(allocator: std.mem.Allocator) PrecompileError!PrecompileResult {
    return PrecompileResult{
        .output = try allocator.alloc(u8, 0),
        .gas_used = GAS,
    };
}

fn vectorInput(v: u8, s: [32]u8) [128]u8 {
    // go-ethereum ecrecover vector; signer 0x7156526fbd7a3c72969b54f64e42c10fbb768c8a.
    const hash = [_]u8{ 0x45, 0x6e, 0x9a, 0xea, 0x5e, 0x19, 0x7a, 0x1f, 0x1a, 0xf7, 0xa3, 0xe8, 0x5a, 0x32, 0x12, 0xfa, 0x40, 0x49, 0xa3, 0xba, 0x34, 0xc2, 0x28, 0x9b, 0x4c, 0x86, 0x0f, 0xc0, 0xb0, 0xc6, 0x4e, 0xf3 };
    const r = [_]u8{ 0x92, 0x42, 0x68, 0x5b, 0xf1, 0x61, 0x79, 0x3c, 0xc2, 0x56, 0x03, 0xc2, 0x31, 0xbc, 0x2f, 0x56, 0x8e, 0xb6, 0x30, 0xea, 0x16, 0xaa, 0x13, 0x7d, 0x26, 0x64, 0xac, 0x80, 0x38, 0x82, 0x56, 0x08 };
    var input = [_]u8{0} ** 128;
    @memcpy(input[0..32], &hash);
    input[63] = v;
    @memcpy(input[64..96], &r);
    @memcpy(input[96..128], &s);
    return input;
}

const vector_s = [_]u8{ 0x4f, 0x8a, 0xe3, 0xbd, 0x75, 0x35, 0x24, 0x8d, 0x0b, 0xd4, 0x48, 0x29, 0x8c, 0xc2, 0xe2, 0x07, 0x1e, 0x56, 0x99, 0x2d, 0x07, 0x74, 0xdc, 0x34, 0x0c, 0x36, 0x8a, 0xe9, 0x50, 0x85, 0x2a, 0xda };
const vector_signer = [_]u8{0} ** 12 ++ [_]u8{ 0x71, 0x56, 0x52, 0x6f, 0xbd, 0x7a, 0x3c, 0x72, 0x96, 0x9b, 0x54, 0xf6, 0x4e, 0x42, 0xc1, 0x0f, 0xbb, 0x76, 0x8c, 0x8a };

test "ecRecover - known vector recovers the signer" {
    const allocator = std.testing.allocator;
    const input = vectorInput(28, vector_s);
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &vector_signer, result.output);
}

test "ecRecover - high s recovers the same signer with flipped v" {
    // The precompile has no EIP-2 low-s rule: (r, n - s, v ^ 1) recovers the same key.
    const allocator = std.testing.allocator;
    const s = std.mem.readInt(u256, &vector_s, .big);
    var high_s: [32]u8 = undefined;
    std.mem.writeInt(u256, &high_s, secp256k1.SECP256K1_N - s, .big);
    const input = vectorInput(27, high_s);
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &vector_signer, result.output);
}

test "ecRecover - v with nonzero high bytes returns empty" {
    const allocator = std.testing.allocator;
    var input = vectorInput(28, vector_s);
    input[32] = 1;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - raw recovery id 1 is not a valid v" {
    const allocator = std.testing.allocator;
    const input = vectorInput(1, vector_s);
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
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

    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - input too long truncated" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 200;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{};
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - v value 27" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    input[63] = 27;

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - v value 28" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    input[63] = 28;

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - invalid v value returns empty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    input[63] = 29;

    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - all zero input returns empty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 128;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.output.len);
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

    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "ecRecover - invalid signature graceful failure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0xFF} ** 128;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.output.len);
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
    try testing.expectEqual(@as(usize, 0), result.output.len);
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
    try testing.expectEqual(@as(usize, 0), result.output.len);
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
    try testing.expectEqual(@as(usize, 0), result.output.len);
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
    try testing.expectEqual(@as(usize, 0), result.output.len);
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
    try testing.expectEqual(@as(usize, 0), result.output.len);
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
    try testing.expectEqual(@as(usize, 0), result.output.len);
}
