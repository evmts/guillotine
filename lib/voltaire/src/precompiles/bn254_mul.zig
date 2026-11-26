const std = @import("std");
const crypto = @import("crypto");
const bn254 = crypto.bn254;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;
const Hardfork = @import("voltaire").Hardfork;

/// Gas cost for BN254 multiplication from Istanbul (EIP-1108)
pub const GAS: u64 = 6000;
/// Gas cost for BN254 multiplication in Byzantium through Petersburg (EIP-196)
pub const GAS_BYZANTIUM: u64 = 40000;

/// Gas cost of BN254MUL in `hardfork`.
pub fn gasCost(hardfork: Hardfork) u64 {
    return if (hardfork.isAtLeast(.ISTANBUL)) GAS else GAS_BYZANTIUM;
}

/// 0x07: BN254MUL at Istanbul+ pricing (EIP-1108).
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    return executeAtFork(allocator, input, gas_limit, .ISTANBUL);
}

/// 0x07: BN254MUL - BN254 elliptic curve scalar multiplication, priced for `hardfork`.
pub fn executeAtFork(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
    hardfork: Hardfork,
) PrecompileError!PrecompileResult {
    const cost = gasCost(hardfork);
    if (gas_limit < cost) {
        return error.OutOfGas;
    }

    // Input: 96 bytes (point 64 bytes + scalar 32 bytes)
    var input_buf: [96]u8 = @as([96]u8, @splat(0));
    @memcpy(input_buf[0..@min(input.len, 96)], input[0..@min(input.len, 96)]);

    const output = try allocator.alloc(u8, 64);
    errdefer allocator.free(output);

    // Perform multiplication using pure Zig implementation
    bn254.bn254Mul(&input_buf, output) catch {
        return error.InvalidPoint;
    };

    return PrecompileResult{
        .output = output,
        .gas_used = cost,
    };
}

test "bn254Mul - multiply by zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Multiply any point by zero = point at infinity
    const input = @as([96]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqual(GAS, result.gas_used);
}

test "bn254Mul - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([96]u8, @splat(0));
    const result = execute(allocator, &input, GAS - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bn254Mul - exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([96]u8, @splat(0));
    const result = try execute(allocator, &input, GAS);
    defer result.deinit(allocator);

    try testing.expectEqual(GAS, result.gas_used);
}

test "bn254Mul - input too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([95]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "bn254Mul - input too long padded correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([150]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "bn254Mul - zero input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "bn254Mul - gas cost constant" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 6000), GAS);
}

test "bn254Mul - output size validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([96]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

// ============================================================================
// Official Ethereum Test Vectors from go-ethereum
// Source: https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256ScalarMul.json
// ============================================================================

test "bn254Mul - geth chfast1" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "2bd3e6d0f3b142924f5ca7b49ce5b9d54c4703d7ae5648e61d02268b1a0a9fb721611ce0a6af85915e2f1d70300909ce2e49dfad4a4619c8390cae66cefdb20400000000000000000000000000000000000000000000000011138ce750fa15c2");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "070a8d6a982153cae4be29d434e8faef8a47b274a053f5a4ee2a6c9c13c31e5c031b8ce914eba3a9ffb989f9cdd5b0f01943074bf4f0f315690ec3cec6981afc");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth chfast2" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "070a8d6a982153cae4be29d434e8faef8a47b274a053f5a4ee2a6c9c13c31e5c031b8ce914eba3a9ffb989f9cdd5b0f01943074bf4f0f315690ec3cec6981afc30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd46");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "025a6f4181d2b4ea8b724290ffb40156eb0adb514c688556eb79cdea0752c2bb2eff3f31dea215f1eb86023a133a996eb6300b44da664d64251d05381bb8a02e");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth chfast3" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "025a6f4181d2b4ea8b724290ffb40156eb0adb514c688556eb79cdea0752c2bb2eff3f31dea215f1eb86023a133a996eb6300b44da664d64251d05381bb8a02e183227397098d014dc2822db40c0ac2ecbc0b548b438e5469e10460b6c3e7ea3");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "14789d0d4a730b354403b5fac948113739e276c23e0258d8596ee72f9cd9d3230af18a63153e0ec25ff9f2951dd3fa90ed0197bfef6e2a1a62b5095b9d2b4a27");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio1 empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const expected = @as([64]u8, @splat(0));

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio1" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "1a87b0584ce92f4593d161480614f2989035225609f08058ccfa3d0f940febe31a2f3c951f6dadcc7ee9007dff81504b0fcd6d7cf59996efdc33d92bf7f9f8f6ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2cde5879ba6f13c0b5aa4ef627f159a3347df9722efce88a9afbb20b763b4c411aa7e43076f6aee272755a7f9b84832e71559ba0d2e0b17d5f9f01755e5b0d11");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio2" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "1a87b0584ce92f4593d161480614f2989035225609f08058ccfa3d0f940febe31a2f3c951f6dadcc7ee9007dff81504b0fcd6d7cf59996efdc33d92bf7f9f8f630644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "1a87b0584ce92f4593d161480614f2989035225609f08058ccfa3d0f940febe3163511ddc1c3f25d396745388200081287b3fd1472d8339d5fecb2eae0830451");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio3" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "1a87b0584ce92f4593d161480614f2989035225609f08058ccfa3d0f940febe31a2f3c951f6dadcc7ee9007dff81504b0fcd6d7cf59996efdc33d92bf7f9f8f60000000000000000000000000000000100000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "1051acb0700ec6d42a88215852d582efbaef31529b6fcbc3277b5c1b300f5cf0135b2394bb45ab04b8bd7611bd2dfe1de6a4e6e2ccea1ea1955f577cd66af85b");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio4" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "1a87b0584ce92f4593d161480614f2989035225609f08058ccfa3d0f940febe31a2f3c951f6dadcc7ee9007dff81504b0fcd6d7cf59996efdc33d92bf7f9f8f60000000000000000000000000000000000000000000000000000000000000009");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "1dbad7d39dbc56379f78fac1bca147dc8e66de1b9d183c7b167351bfe0aeab742cd757d51289cd8dbd0acf9e673ad67d0f0a89f912af47ed1be53664f5692575");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - regression cdetrio5 invalid point not on curve" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000";

    var input: [95]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Mul - geth cdetrio6" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7cffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "29e587aadd7c06722aabba753017c093f70ba7eb1f1c0104ec0564e7e3e21f6022b1143f6a41008e7755c71c3d00b6b915d386de21783ef590486d8afa8453b1");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio7" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa92e83f8d734803fc370eba25ed1f6b8768bd6d83887b87165fc2434fe11a830cb");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio8" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c0000000000000000000000000000000100000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "221a3577763877920d0d14a91cd59b9479f83b87a653bb41f82a3f6f120cea7c2752c7f64cdd7f0e494bff7b60419f242210f2026ed2ec70f89f78a4c56a1f15");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio9" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c0000000000000000000000000000000000000000000000000000000000000009");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "228e687a379ba154554040f8821f4e41ee2be287c201aa9c3bc02c9dd12f1e691e0fd6ee672d04cfd924ed8fdc7ba5f2d06c53c1edc30f65f2af5a5b97f0a76a");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - regression cdetrio10 invalid coordinate at field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47000000000000000000000000000000000000000000000000000000000000000030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47";

    var input: [96]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Mul - regression cdetrio11 invalid coordinate exceeds field modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_hex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd48000000000000000000000000000000000000000000000000000000000000000030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47";

    var input: [96]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, input_hex);

    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidPoint, result);
}

test "bn254Mul - geth cdetrio12" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d9830644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b8692929ee761a352600f54921df9bf472e66217e7bb0cee9032e00acc86b3c8bfaf");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio13" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d980000000000000000000000000000000100000000000000000000000000000000");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "1071b63011e8c222c5a771dfa03c2e11aac9666dd097f2c620852c3951a4376a2f46fe2f73e1cf310a168d56baa5575a8319389d7bfa6b29ee2d908305791434");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio14" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d980000000000000000000000000000000000000000000000000000000000000009");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "19f75b9dd68c080a688774a6213f131e3052bd353a304a189d7a2ee367e3c2582612f545fb9fc89fde80fd81c68fc7dcb27fea5fc124eeda69433cf5c46d2d7f");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Mul - geth cdetrio15" {
    // go-ethereum core/vm/testdata/precompiles/bn256ScalarMul.json
    var input_buf: [96]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buf, "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d980000000000000000000000000000000000000000000000000000000000000001");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d98");
    const result = try execute(std.testing.allocator, input, 1_000_000);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "EIP-196 MUL validates noncanonical and off-curve points before zero scalar" {
    var input = @as([96]u8, @splat(0));
    for (0..2) |slot| {
        std.mem.writeInt(u256, input[slot * 32 ..][0..32], bn254.FP_MOD, .big);
        try std.testing.expectError(error.InvalidPoint, execute(std.testing.allocator, &input, GAS));
        @memset(input[slot * 32 ..][0..32], 0);
    }
    input[31] = 1;
    input[63] = 3;
    try std.testing.expectError(error.InvalidPoint, execute(std.testing.allocator, &input, GAS));
}

test "bn254Mul - Byzantium charges 40000, Istanbul charges 6000" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const input = @as([96]u8, @splat(0));

    try testing.expectError(error.OutOfGas, executeAtFork(allocator, &input, 39999, .BYZANTIUM));
    const byz = try executeAtFork(allocator, &input, 40000, .CONSTANTINOPLE);
    defer byz.deinit(allocator);
    try testing.expectEqual(@as(u64, 40000), byz.gas_used);
    const ist = try executeAtFork(allocator, &input, 40000, .ISTANBUL);
    defer ist.deinit(allocator);
    try testing.expectEqual(@as(u64, 6000), ist.gas_used);
}

test "bn254Mul - infinity times any scalar is infinity" {
    const testing = std.testing;
    const allocator = testing.allocator;
    // Scalars from EEST test_ecmul inf_times_*: 2^128, r - 1, r - 2, 2^256 - 1, 1.
    const r: u256 = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    const scalars = [_]u256{ @as(u256, 1) << 128, r - 1, r - 2, std.math.maxInt(u256), 1, 2, 9 };
    for (scalars) |scalar| {
        var input = @as([96]u8, @splat(0));
        std.mem.writeInt(u256, input[64..96], scalar, .big);
        const result = try execute(allocator, &input, GAS);
        defer result.deinit(allocator);
        try testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), result.output);
    }
}
