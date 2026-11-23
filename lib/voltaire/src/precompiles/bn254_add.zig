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
    var input_buf: [128]u8 = [_]u8{0} ** 128;
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
    const input = [_]u8{0} ** 128;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqual(GAS, result.gas_used);
}

test "bn254Add - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 128;
    const result = execute(allocator, &input, GAS - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bn254Add - exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 128;
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(GAS, result.gas_used);
}

test "bn254Add - input too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 127;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "bn254Add - input too long padded correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 200;
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

    const input = [_]u8{0} ** 128;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

// ============================================================================
// Official Ethereum Test Vectors from go-ethereum
// Source: https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256Add.json
// ============================================================================

test "bn254Add - geth chfast1" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "18b18acfb4c2c30276db5411368e7185b311dd124691610c5d3b74034e093dc9063c909c4720840cb5134cb9f59fa749755796819658d32efc0d288198f3726607c2b7f58a84bd6145f00c9c2bc0bb1a187f20ff2c92963a88019e7c6a014eed06614e20c147e940f2d70da3f74c9a17df361706a4485c742bd6788478fa17d7";
    const expected_hex = "2243525c5efd4b9c3d3c45ac0ca3fe4dd85e830a4ce6b65fa1eeaee202839703301d1d33be6da8e509df21cc35964723180eed7532537db9ae5e7d48f195c915";

    var input: [128]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth chfast2" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "2243525c5efd4b9c3d3c45ac0ca3fe4dd85e830a4ce6b65fa1eeaee202839703301d1d33be6da8e509df21cc35964723180eed7532537db9ae5e7d48f195c91518b18acfb4c2c30276db5411368e7185b311dd124691610c5d3b74034e093dc9063c909c4720840cb5134cb9f59fa749755796819658d32efc0d288198f37266";
    const expected_hex = "2bd3e6d0f3b142924f5ca7b49ce5b9d54c4703d7ae5648e61d02268b1a0a9fb721611ce0a6af85915e2f1d70300909ce2e49dfad4a4619c8390cae66cefdb204";

    var input: [128]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio4 empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const expected = [_]u8{0} ** 64;

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio2" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const expected_hex = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    var input: [64]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio8" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";
    const expected_hex = "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";

    var input: [64]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - invalid point not on curve" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";

    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - geth cdetrio11" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";
    const expected_hex = "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd315ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4";

    var input: [128]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio13" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d98";
    const expected_hex = "15bf2bb17880144b5d1cd2b1f46eff9d617bffd1ca57c37fb5a49bd84e53cf66049c797f9ce0d17083deb32b5e36f2ea2a212ee036598dd7624c168993d1355f";

    var input: [128]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio14" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa92e83f8d734803fc370eba25ed1f6b8768bd6d83887b87165fc2434fe11a830cb00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const expected_hex = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    var input: [192]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - reversed geth cdetrio13 operands" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d9817c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c";
    const expected_hex = "15bf2bb17880144b5d1cd2b1f46eff9d617bffd1ca57c37fb5a49bd84e53cf66049c797f9ce0d17083deb32b5e36f2ea2a212ee036598dd7624c168993d1355f";

    var input: [128]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - double a point with large coordinates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d98039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d98";
    const expected_hex = "2dbc7ba68f840c758c76373cd37b2cd78d6b02bee047cf401e8db90d73ce56f7062800987ee0dae9f9f36e1f050eb2621cbb4aa7c50b1c168ecc319370889de2";

    var input: [128]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - geth cdetrio12" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const expected_hex = "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd315ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4";

    var input: [192]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Add - invalid x larger than field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd48000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";

    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - invalid y larger than field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "000000000000000000000000000000000000000000000000000000000000000130644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4800000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";

    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - coordinates at field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4730644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";

    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Add - zero point with valid point" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d98";
    const expected_hex = "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d98";

    var input: [128]u8 = undefined;
    var expected: [64]u8 = undefined;

    _ = try std.fmt.hexToBytes(&input, input_hex);
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}
