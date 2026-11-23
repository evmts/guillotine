const std = @import("std");
const crypto = @import("crypto");
const bn254 = crypto.bn254;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for BN254 addition
pub const GAS: u64 = 150;

/// 0x06: BN254ADD - BN254 elliptic curve addition
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    // Input: 128 bytes (two points, 64 bytes each)
    var input_buf: [128]u8 = @as([128]u8, @splat(0));
    @memcpy(input_buf[0..@min(input.len, 128)], input[0..@min(input.len, 128)]);

    const output = try allocator.alloc(u8, 64);
    errdefer allocator.free(output);

    // Perform addition using pure Zig implementation
    bn254.bn254Add(&input_buf, output) catch {
        return error.InvalidPoint;
    };

    return PrecompileResult{
        .output = output,
        .gas_used = GAS,
    };
}

test "bn254Add - point at infinity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Adding point at infinity to itself
    const input = @as([128]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqual(GAS, result.gas_used);
}

test "bn254Add - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([128]u8, @splat(0));
    const result = execute(allocator, &input, GAS - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bn254Add - exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([128]u8, @splat(0));
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(GAS, result.gas_used);
}

test "bn254Add - input too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([127]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "bn254Add - input too long padded correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([200]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "bn254Add - zero input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "bn254Add - gas cost constant" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 150), GAS);
}

test "bn254Add - output size validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([128]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

// ============================================================================
// Official Ethereum Test Vectors from go-ethereum
// Source: https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256Add.json
// ============================================================================

test "bn254Add - geth chfast1" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "18b18acfb4c2c30276db5411368e7185b311dd124691610c5d3b74034e093dc9063c909c4720840cb5134cb9f59fa749755796819658d32efc0d288198f3726607c2b7f58a84bd6145f00c9c2bc0bb1a187f20ff2c92963a88019e7c6a014eed06614e20c147e940f2d70da3f74c9a17df361706a4485c742bd6788478fa17d7");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2243525c5efd4b9c3d3c45ac0ca3fe4dd85e830a4ce6b65fa1eeaee202839703301d1d33be6da8e509df21cc35964723180eed7532537db9ae5e7d48f195c915");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth chfast2" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "2243525c5efd4b9c3d3c45ac0ca3fe4dd85e830a4ce6b65fa1eeaee202839703301d1d33be6da8e509df21cc35964723180eed7532537db9ae5e7d48f195c91518b18acfb4c2c30276db5411368e7185b311dd124691610c5d3b74034e093dc9063c909c4720840cb5134cb9f59fa749755796819658d32efc0d288198f37266");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2bd3e6d0f3b142924f5ca7b49ce5b9d54c4703d7ae5648e61d02268b1a0a9fb721611ce0a6af85915e2f1d70300909ce2e49dfad4a4619c8390cae66cefdb204");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio1 empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const expected = @as([64]u8, @splat(0));

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio1" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio2" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [64]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio3" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [80]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - regression cdetrio4 invalid point not on curve" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - geth cdetrio5" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [192]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio6" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio7" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [192]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio8" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [64]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio9" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio10" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [192]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - regression cdetrio11 invalid x larger than field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";

    var input: [129]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - regression cdetrio12 invalid y larger than field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "000000000000000000000000000000000000000000000000000000000000000130644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd470000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";

    var input: [129]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - regression cdetrio13 coordinates at field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4730644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd470000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";

    var input: [129]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - geth cdetrio14" {
    // go-ethereum core/vm/testdata/precompiles/bn256Add.json
    var input_buf: [192]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa92e83f8d734803fc370eba25ed1f6b8768bd6d83887b87165fc2434fe11a830cb00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "EIP-196 ADD rejects noncanonical coordinates in either point" {
    var input = @as([128]u8, @splat(0));
    for (0..4) |slot| {
        std.mem.writeInt(u256, input[slot * 32 ..][0..32], bn254.FP_MOD, .big);
        try std.testing.expectError(error.InvalidPoint, execute(std.testing.allocator, &input, GAS));
        std.mem.writeInt(u256, input[slot * 32 ..][0..32], bn254.FP_MOD + 1, .big);
        try std.testing.expectError(error.InvalidPoint, execute(std.testing.allocator, &input, GAS));
        @memset(input[slot * 32 ..][0..32], 0);
    }
}
