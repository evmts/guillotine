const std = @import("std");
const crypto = @import("crypto");
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for BLS12-381 map field element to G2
pub const GAS: u64 = 23800;

/// 0x11: BLS12_MAP_FP2_TO_G2 - BLS12-381 map field element to G2
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    if (input.len != 128) {
        return error.InvalidInput;
    }

    const output = try allocator.alloc(u8, 256);
    errdefer allocator.free(output);
    crypto.Crypto.bls12_381.mapFp2ToG2(input, output) catch {
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

test "map fp2 to g2 - out of gas" {
    const input = @as([128]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, GAS - 1);
    try std.testing.expectError(error.OutOfGas, result);
}

test "map fp2 to g2 - exact gas" {
    const input = @as([128]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(GAS, res.gas_used);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
}

test "map fp2 to g2 - excess gas" {
    const input = @as([128]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, GAS + 1000);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(GAS, res.gas_used);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
}

test "map fp2 to g2 - invalid input length too short" {
    const input = @as([127]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, GAS);
    try std.testing.expectError(error.InvalidInput, result);
}

test "map fp2 to g2 - invalid input length too long" {
    const input = @as([129]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, GAS);
    try std.testing.expectError(error.InvalidInput, result);
}

test "map fp2 to g2 - invalid input length zero" {
    const input = [_]u8{};
    const result = execute(std.testing.allocator, &input, GAS);
    try std.testing.expectError(error.InvalidInput, result);
}

test "map fp2 to g2 - zero fp2 element" {
    // Zero Fp2 element (c0=0, c1=0) should map to a valid G2 point
    const input = @as([128]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
    try std.testing.expectEqual(GAS, res.gas_used);
}

test "map fp2 to g2 - maximum field element c0" {
    // Fp2 element with maximum c0, zero c1
    // BLS12-381 field modulus p = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab
    var input: [128]u8 = undefined;
    @memset(&input, 0);

    // Set c0 to p - 1 (first 64 bytes)
    const p_minus_1_bytes = [_]u8{
        0x1a, 0x01, 0x11, 0xea, 0x39, 0x7f, 0xe6, 0x9a,
        0x4b, 0x1b, 0xa7, 0xb6, 0x43, 0x4b, 0xac, 0xd7,
        0x64, 0x77, 0x4b, 0x84, 0xf3, 0x85, 0x12, 0xbf,
        0x67, 0x30, 0xd2, 0xa0, 0xf6, 0xb0, 0xf6, 0x24,
        0x1e, 0xab, 0xff, 0xfe, 0xb1, 0x53, 0xff, 0xff,
        0xb9, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xaa, 0xaa,
    };
    @memcpy(input[16..64], &p_minus_1_bytes);
    // c1 remains 0

    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
    try std.testing.expectEqual(GAS, res.gas_used);
}

test "map fp2 to g2 - maximum field element c1" {
    // Fp2 element with zero c0, maximum c1
    var input: [128]u8 = undefined;
    @memset(&input, 0);

    // c0 remains 0
    // Set c1 to p - 1 (second 64 bytes)
    const p_minus_1_bytes = [_]u8{
        0x1a, 0x01, 0x11, 0xea, 0x39, 0x7f, 0xe6, 0x9a,
        0x4b, 0x1b, 0xa7, 0xb6, 0x43, 0x4b, 0xac, 0xd7,
        0x64, 0x77, 0x4b, 0x84, 0xf3, 0x85, 0x12, 0xbf,
        0x67, 0x30, 0xd2, 0xa0, 0xf6, 0xb0, 0xf6, 0x24,
        0x1e, 0xab, 0xff, 0xfe, 0xb1, 0x53, 0xff, 0xff,
        0xb9, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xaa, 0xaa,
    };
    @memcpy(input[80..128], &p_minus_1_bytes);

    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
    try std.testing.expectEqual(GAS, res.gas_used);
}

test "map fp2 to g2 - both components maximum" {
    // Fp2 element with both c0 and c1 at maximum
    var input: [128]u8 = undefined;
    @memset(&input, 0);

    const p_minus_1_bytes = [_]u8{
        0x1a, 0x01, 0x11, 0xea, 0x39, 0x7f, 0xe6, 0x9a,
        0x4b, 0x1b, 0xa7, 0xb6, 0x43, 0x4b, 0xac, 0xd7,
        0x64, 0x77, 0x4b, 0x84, 0xf3, 0x85, 0x12, 0xbf,
        0x67, 0x30, 0xd2, 0xa0, 0xf6, 0xb0, 0xf6, 0x24,
        0x1e, 0xab, 0xff, 0xfe, 0xb1, 0x53, 0xff, 0xff,
        0xb9, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xaa, 0xaa,
    };
    @memcpy(input[16..64], &p_minus_1_bytes);
    @memcpy(input[80..128], &p_minus_1_bytes);

    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
    try std.testing.expectEqual(GAS, res.gas_used);
}

test "map fp2 to g2 - test vector 1" {
    // Test vector: Fp2 element with c0=1, c1=0
    var input: [128]u8 = undefined;
    @memset(&input, 0);
    input[63] = 1; // c0 = 1
    // c1 = 0

    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
    try std.testing.expectEqual(GAS, res.gas_used);
}

test "map fp2 to g2 - test vector 2" {
    // Test vector: Fp2 element with c0=0, c1=1
    var input: [128]u8 = undefined;
    @memset(&input, 0);
    // c0 = 0
    input[127] = 1; // c1 = 1

    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
    try std.testing.expectEqual(GAS, res.gas_used);
}

test "map fp2 to g2 - test vector 3" {
    // Test vector: arbitrary Fp2 element
    var input: [128]u8 = undefined;
    @memset(&input, 0);
    // Set some arbitrary values
    input[60] = 0x12;
    input[61] = 0x34;
    input[62] = 0x56;
    input[63] = 0x78; // c0

    input[124] = 0x9a;
    input[125] = 0xbc;
    input[126] = 0xde;
    input[127] = 0xf0; // c1

    const result = execute(std.testing.allocator, &input, GAS);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
    try std.testing.expectEqual(GAS, res.gas_used);
}

test "map fp2 to g2 - gas cost validation" {
    // Verify the gas cost constant matches EIP-2537 specification
    try std.testing.expectEqual(@as(u64, 23800), GAS);
}

test "map fp2 to g2 - output size validation" {
    // Output should be 256 bytes (uncompressed G2 point: 2x128 bytes for (x,y) in Fp2)
    const input = @as([128]u8, @splat(0));
    const result = execute(std.testing.allocator, &input, 100000);

    const res = try result;
    defer std.testing.allocator.free(res.output);
    try std.testing.expectEqual(@as(usize, 256), res.output.len);
}

test "EIP-2537 map_fp2_to_g2 rejects padding and noncanonical field elements without leaking" {
    var input = @as([128]u8, @splat(0));
    const modulus: u512 = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;
    for (0..2) |slot| {
        const offset = slot * 64;
        for (0..16) |padding| {
            input[offset + padding] = 1;
            try std.testing.expectError(error.InvalidPoint, execute(std.testing.allocator, &input, 1_000_000));
            input[offset + padding] = 0;
        }
        std.mem.writeInt(u512, input[offset..][0..64], modulus, .big);
        try std.testing.expectError(error.InvalidPoint, execute(std.testing.allocator, &input, 1_000_000));
        @memset(input[offset..][0..64], 0);
    }
}

test "EIP-2537 mapg2 go-ethereum padded map vector" {
    var input: [128]u8 = undefined;
    var expected: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "0000000000000000000000000000000014406e5bfb9209256a3820879a29ac2f62d6aca82324bf3ae2aa7d3c54792043bd8c791fccdb080c1a52dc68b8b69350000000000000000000000000000000000e885bb33996e12f07da69073e2c0cc880bc8eff26d2a724299eb12d54f4bcf26f4748bb020e80a7e3794a7b0e47a641");
    _ = try std.fmt.hexToBytes(&expected, "000000000000000000000000000000000d029393d3a13ff5b26fe52bd8953768946c5510f9441f1136f1e938957882db6adbd7504177ee49281ecccba596f2bf000000000000000000000000000000001993f668fb1ae603aefbb1323000033fcb3b65d8ed3bf09c84c61e27704b745f540299a1872cd697ae45a5afd780f1d600000000000000000000000000000000079cb41060ef7a128d286c9ef8638689a49ca19da8672ea5c47b6ba6dbde193ee835d3b87a76a689966037c07159c10d0000000000000000000000000000000017c688ae9a8b59a7069c27f2d58dd2196cb414f4fb89da8510518a1142ab19d158badd1c3bad03408fafb1669903cd6c");
    const result = try execute(std.testing.allocator, &input, GAS);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}
