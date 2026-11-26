const std = @import("std");
const crypto = @import("crypto");
const secp256k1 = crypto.secp256k1;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for ECRECOVER precompile
pub const GAS: u64 = 3000;

/// 0x01: ECRECOVER - Elliptic curve signature recovery
///
/// Input is right-padded with zeros to 128 bytes: hash32 || v32 || r32 || s32.
/// The call always succeeds and charges `GAS`. Output is the 32-byte left-padded
/// address, or EMPTY when the signature is invalid:
/// - v must be exactly 27 or 28 as a 32-byte big-endian word (high 31 bytes zero)
/// - r and s must be in [1, n-1]; EIP-2 low-s applies to transactions only, not here
/// - recovery must yield a valid public key
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    var input_buf: [128]u8 = @as([128]u8, @splat(0));
    const n = @min(input.len, 128);
    @memcpy(input_buf[0..n], input[0..n]);

    const pubkey = recover(&input_buf) orelse return PrecompileResult{
        .output = try allocator.alloc(u8, 0),
        .gas_used = GAS,
    };

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

/// Public key for a padded ECRECOVER input, or null when the signature is invalid.
fn recover(input: *const [128]u8) ?[64]u8 {
    for (input[32..63]) |byte| {
        if (byte != 0) return null;
    }
    const v = input[63];
    if (v != 27 and v != 28) return null;
    const r = std.mem.readInt(u256, input[64..96], .big);
    const s = std.mem.readInt(u256, input[96..128], .big);
    return secp256k1.recoverPubkeyPrecompile(input[0..32], r, s, @intCast(v - 27)) catch |err| switch (err) {
        error.InvalidSignature => null,
    };
}

// geth core/vm/contracts_test.go "ValidKey": hash, v=28, r, s. Its s is above n/2, so
// it also proves EIP-2 low-s is not enforced by the precompile.
const valid_input_hex = "18c547e4f7b0f325ad1e56f57e26c745b09a3e503d86e00e5255ff7f715d3d1c" ++
    "000000000000000000000000000000000000000000000000000000000000001c" ++
    "73b1693892219d736caba55bdb67216e485557ea6b6af75f37096c9aa6a5a75f" ++
    "eeb940b1d03b21e36b0e47e79769f095fe2ab855bd91e3a38756b7d75a9c4549";
const valid_output_hex = "000000000000000000000000a94f5374fce5edbc8e2a8697c15331677e6ebf0b";
const secp256k1_n: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

test "ecRecover - recovers geth ValidKey vector with high s" {
    const testing = std.testing;
    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, valid_input_hex);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, valid_output_hex);
    try testing.expect(std.mem.readInt(u256, input[96..128], .big) > secp256k1_n / 2);

    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &expected, result.output);
    try testing.expectEqual(GAS, result.gas_used);
}

test "ecRecover - malleated low-s twin recovers the same address" {
    const testing = std.testing;
    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, valid_input_hex);
    const s = std.mem.readInt(u256, input[96..128], .big);
    std.mem.writeInt(u256, input[96..128], secp256k1_n - s, .big);
    input[63] = 27;
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, valid_output_hex);

    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "ecRecover - out of gas" {
    const testing = std.testing;
    const input = @as([128]u8, @splat(0));
    try testing.expectError(error.OutOfGas, execute(testing.allocator, &input, GAS - 1));
}

test "ecRecover - invalid inputs return empty output and charge full gas" {
    const testing = std.testing;
    var base: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&base, valid_input_hex);

    const Mutation = enum { v_zero, v_one, v_29, v_high_byte, r_zero, s_zero, r_n, s_n, all_zero };
    for (std.enums.values(Mutation)) |mutation| {
        var input = base;
        switch (mutation) {
            .v_zero => input[63] = 0,
            .v_one => input[63] = 1,
            .v_29 => input[63] = 29,
            .v_high_byte => input[32] = 1,
            .r_zero => @memset(input[64..96], 0),
            .s_zero => @memset(input[96..128], 0),
            .r_n => std.mem.writeInt(u256, input[64..96], secp256k1_n, .big),
            .s_n => std.mem.writeInt(u256, input[96..128], secp256k1_n, .big),
            .all_zero => @memset(&input, 0),
        }
        const result = try execute(testing.allocator, &input, GAS);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), result.output.len);
        try testing.expectEqual(GAS, result.gas_used);
    }
}

test "ecRecover - short input is right-padded, long input is truncated" {
    const testing = std.testing;
    var long: [160]u8 = @as([160]u8, @splat(0xff));
    _ = try std.fmt.hexToBytes(long[0..128], valid_input_hex);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, valid_output_hex);

    const long_result = try execute(testing.allocator, &long, GAS);
    defer long_result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &expected, long_result.output);

    // Dropping the last byte of s pads it with zero: a different (invalid or other) key.
    const short_result = try execute(testing.allocator, long[0..127], GAS);
    defer short_result.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, &expected, short_result.output));

    const empty_result = try execute(testing.allocator, &.{}, GAS);
    defer empty_result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty_result.output.len);
}
