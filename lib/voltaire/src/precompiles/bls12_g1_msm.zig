const std = @import("std");
const crypto = @import("crypto");
const msmDiscount = @import("utils.zig").msmDiscount;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for BLS12-381 G1 MSM
pub const BASE_GAS: u64 = 12000;
pub const MULTIPLIER: u64 = 50;

/// 0x0D: BLS12_G1MSM - BLS12-381 G1 multi-scalar multiplication
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (input.len % 160 != 0 or input.len == 0) {
        return error.InvalidInput;
    }

    const k = input.len / 160;
    const discount = msmDiscount(k);
    const gas_cost = (BASE_GAS * k * discount) / 1000;

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 128);
    crypto.Crypto.bls12_381.g1Msm(input, output) catch {
        return error.InvalidPoint;
    };

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "bls12_g1_msm - gas cost with one pair" {
    const allocator = testing.allocator;

    // One point-scalar pair
    var input: [160]u8 = [_]u8{0} ** 160;
    const k: usize = 1;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - gas cost with two pairs" {
    const allocator = testing.allocator;

    // Two point-scalar pairs
    var input: [320]u8 = [_]u8{0} ** 320;
    const k: usize = 2;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - gas cost with four pairs" {
    const allocator = testing.allocator;

    // Four point-scalar pairs
    var input: [640]u8 = [_]u8{0} ** 640;
    const k: usize = 4;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - gas cost with eight pairs" {
    const allocator = testing.allocator;

    // Eight point-scalar pairs
    var input: [1280]u8 = [_]u8{0} ** 1280;
    const k: usize = 8;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - gas cost with sixteen pairs" {
    const allocator = testing.allocator;

    // Sixteen point-scalar pairs
    var input: [2560]u8 = [_]u8{0} ** 2560;
    const k: usize = 16;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - gas cost with thirty-two pairs" {
    const allocator = testing.allocator;

    // Thirty-two point-scalar pairs
    var input: [5120]u8 = [_]u8{0} ** 5120;
    const k: usize = 32;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - gas cost with sixty-four pairs" {
    const allocator = testing.allocator;

    // Sixty-four point-scalar pairs
    var input: [10240]u8 = [_]u8{0} ** 10240;
    const k: usize = 64;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - gas cost with one hundred twenty-eight pairs" {
    const allocator = testing.allocator;

    // One hundred twenty-eight point-scalar pairs
    var input: [20480]u8 = [_]u8{0} ** 20480;
    const k: usize = 128;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(usize, 128), result.output.len);
}

test "bls12_g1_msm - discount calculation validation" {
    // Verify MSM discount tiers per EIP-2537
    try testing.expectEqual(@as(u64, 1000), msmDiscount(1));
    try testing.expectEqual(@as(u64, 820), msmDiscount(2));
    try testing.expectEqual(@as(u64, 580), msmDiscount(4));
    try testing.expectEqual(@as(u64, 430), msmDiscount(8));
    try testing.expectEqual(@as(u64, 320), msmDiscount(16));
    try testing.expectEqual(@as(u64, 250), msmDiscount(32));
    try testing.expectEqual(@as(u64, 200), msmDiscount(64));
    try testing.expectEqual(@as(u64, 174), msmDiscount(128));

    // Verify boundaries
    try testing.expectEqual(@as(u64, 820), msmDiscount(3));
    try testing.expectEqual(@as(u64, 580), msmDiscount(7));
    try testing.expectEqual(@as(u64, 430), msmDiscount(15));
    try testing.expectEqual(@as(u64, 320), msmDiscount(31));
    try testing.expectEqual(@as(u64, 250), msmDiscount(63));
    try testing.expectEqual(@as(u64, 200), msmDiscount(127));
    try testing.expectEqual(@as(u64, 174), msmDiscount(256));
}

test "bls12_g1_msm - out of gas error" {
    const allocator = testing.allocator;

    var input: [160]u8 = [_]u8{0} ** 160;
    const k: usize = 1;
    const discount = msmDiscount(k);
    const required_gas = (BASE_GAS * k * discount) / 1000;

    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bls12_g1_msm - empty input error" {
    const allocator = testing.allocator;

    var input: [0]u8 = [_]u8{};
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bls12_g1_msm - invalid input length not multiple of 160" {
    const allocator = testing.allocator;

    // Test with various invalid lengths
    {
        var input: [159]u8 = [_]u8{0} ** 159;
        const result = execute(allocator, &input, 1000000);
        try testing.expectError(error.InvalidInput, result);
    }

    {
        var input: [161]u8 = [_]u8{0} ** 161;
        const result = execute(allocator, &input, 1000000);
        try testing.expectError(error.InvalidInput, result);
    }

    {
        var input: [320 + 80]u8 = [_]u8{0} ** 400;
        const result = execute(allocator, &input, 1000000);
        try testing.expectError(error.InvalidInput, result);
    }
}

test "bls12_g1_msm - single point times scalar" {
    const allocator = testing.allocator;

    // BLS12-381 G1 generator point
    const g1_x = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x17, 0xf1, 0xd3, 0xa7, 0x31, 0x97, 0xd7, 0x94, 0x26, 0x95, 0x63, 0x8c, 0x4f, 0xa9, 0xac, 0x0f,
        0xc3, 0x68, 0x8c, 0x4f, 0x97, 0x74, 0xb9, 0x05, 0xa1, 0x4e, 0x3a, 0x3f, 0x17, 0x1b, 0xac, 0x58,
        0x6c, 0x55, 0xe8, 0x3f, 0xf9, 0x7a, 0x1a, 0xef, 0xfb, 0x3a, 0xf0, 0x0a, 0xdb, 0x22, 0xc6, 0xbb,
    };
    const g1_y = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x08, 0xb3, 0xf4, 0x81, 0xe3, 0xaa, 0xa0, 0xf1, 0xa0, 0x9e, 0x30, 0xed, 0x74, 0x1d, 0x8a, 0xe4,
        0xfc, 0xf5, 0xe0, 0x95, 0xd5, 0xd0, 0x0a, 0xf6, 0x00, 0xdb, 0x18, 0xcb, 0x2c, 0x04, 0xb3, 0xed,
        0xd0, 0x3c, 0xc7, 0x44, 0xa2, 0x88, 0x8a, 0xe4, 0x0c, 0xaa, 0x23, 0x29, 0x46, 0xc5, 0xe7, 0xe1,
    };

    var input: [160]u8 = [_]u8{0} ** 160;
    @memcpy(input[0..64], &g1_x);
    @memcpy(input[64..128], &g1_y);
    input[159] = 5; // scalar = 5

    const k: usize = 1;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 128), result.output.len);
    // Result should be 5*G (not point at infinity, not equal to G)
    var is_zero = true;
    var is_g = true;
    for (result.output, 0..) |byte, i| {
        if (byte != 0) is_zero = false;
        if (i < 64 and byte != g1_x[i]) is_g = false;
        if (i >= 64 and i < 128 and byte != g1_y[i - 64]) is_g = false;
    }
    try testing.expect(!is_zero);
    try testing.expect(!is_g);
}

test "bls12_g1_msm - multiple points all at infinity" {
    const allocator = testing.allocator;

    // Four point-scalar pairs, all points at infinity
    var input: [640]u8 = [_]u8{0} ** 640;
    const k: usize = 4;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 128), result.output.len);
    // MSM of points at infinity = point at infinity
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "bls12_g1_msm - multiple points with zero scalars" {
    const allocator = testing.allocator;

    // BLS12-381 G1 generator point
    const g1_x = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x17, 0xf1, 0xd3, 0xa7, 0x31, 0x97, 0xd7, 0x94, 0x26, 0x95, 0x63, 0x8c, 0x4f, 0xa9, 0xac, 0x0f,
        0xc3, 0x68, 0x8c, 0x4f, 0x97, 0x74, 0xb9, 0x05, 0xa1, 0x4e, 0x3a, 0x3f, 0x17, 0x1b, 0xac, 0x58,
        0x6c, 0x55, 0xe8, 0x3f, 0xf9, 0x7a, 0x1a, 0xef, 0xfb, 0x3a, 0xf0, 0x0a, 0xdb, 0x22, 0xc6, 0xbb,
    };
    const g1_y = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x08, 0xb3, 0xf4, 0x81, 0xe3, 0xaa, 0xa0, 0xf1, 0xa0, 0x9e, 0x30, 0xed, 0x74, 0x1d, 0x8a, 0xe4,
        0xfc, 0xf5, 0xe0, 0x95, 0xd5, 0xd0, 0x0a, 0xf6, 0x00, 0xdb, 0x18, 0xcb, 0x2c, 0x04, 0xb3, 0xed,
        0xd0, 0x3c, 0xc7, 0x44, 0xa2, 0x88, 0x8a, 0xe4, 0x0c, 0xaa, 0x23, 0x29, 0x46, 0xc5, 0xe7, 0xe1,
    };

    // Two point-scalar pairs, both with generator but zero scalars
    var input: [320]u8 = [_]u8{0} ** 320;
    @memcpy(input[0..64], &g1_x);
    @memcpy(input[64..128], &g1_y);
    // First scalar remains 0
    @memcpy(input[160..224], &g1_x);
    @memcpy(input[224..288], &g1_y);
    // Second scalar remains 0

    const k: usize = 2;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 128), result.output.len);
    // G*0 + G*0 = O
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "bls12_g1_msm - invalid point not on curve" {
    const allocator = testing.allocator;

    var input: [160]u8 = [_]u8{0} ** 160;
    // Set to arbitrary values that don't satisfy the curve equation
    input[63] = 1; // x = 1
    input[127] = 2; // y = 2
    input[159] = 5; // scalar = 5

    const k: usize = 1;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = execute(allocator, &input, expected_gas);
    try testing.expectError(error.InvalidPoint, result);
}

test "bls12_g1_msm - output size validation" {
    const allocator = testing.allocator;

    // Test with various numbers of pairs
    {
        var input: [160]u8 = [_]u8{0} ** 160;
        const result = try execute(allocator, &input, 1000000);
        defer result.deinit(allocator);
        try testing.expectEqual(@as(usize, 128), result.output.len);
    }

    {
        var input: [640]u8 = [_]u8{0} ** 640;
        const result = try execute(allocator, &input, 1000000);
        defer result.deinit(allocator);
        try testing.expectEqual(@as(usize, 128), result.output.len);
    }

    {
        var input: [2560]u8 = [_]u8{0} ** 2560;
        const result = try execute(allocator, &input, 1000000);
        defer result.deinit(allocator);
        try testing.expectEqual(@as(usize, 128), result.output.len);
    }
}

test "bls12_g1_msm - gas discount effect" {
    // Verify that gas cost per pair decreases with more pairs
    const gas_1 = (BASE_GAS * 1 * msmDiscount(1)) / 1000;
    const gas_2 = (BASE_GAS * 2 * msmDiscount(2)) / 1000;
    const gas_4 = (BASE_GAS * 4 * msmDiscount(4)) / 1000;
    const gas_8 = (BASE_GAS * 8 * msmDiscount(8)) / 1000;

    // Gas per pair should decrease as k increases
    const gas_per_pair_1 = gas_1 / 1;
    const gas_per_pair_2 = gas_2 / 2;
    const gas_per_pair_4 = gas_4 / 4;
    const gas_per_pair_8 = gas_8 / 8;

    try testing.expect(gas_per_pair_1 > gas_per_pair_2);
    try testing.expect(gas_per_pair_2 > gas_per_pair_4);
    try testing.expect(gas_per_pair_4 > gas_per_pair_8);
}
