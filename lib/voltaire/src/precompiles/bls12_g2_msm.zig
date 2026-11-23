const std = @import("std");
const crypto = @import("crypto");
const utils = @import("utils.zig");
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for BLS12-381 G2 MSM
/// EIP-2537 multiplication cost that MSM discounts apply to.
pub const BASE_GAS: u64 = 22500;

/// 0x0E: BLS12_G2MSM - BLS12-381 G2 multi-scalar multiplication
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (input.len % 288 != 0 or input.len == 0) {
        return error.InvalidInput;
    }

    const k = input.len / 288;
    const gas_cost = utils.msmGas(k, BASE_GAS, utils.msmDiscountG2(k));

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 256);
    errdefer allocator.free(output);
    errdefer allocator.free(output);
    crypto.Crypto.bls12_381.g2Msm(input, output) catch {
        return error.InvalidPoint;
    };

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

test "bls12_g2_msm - empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const result = execute(allocator, &input, 1000000);

    try testing.expectError(error.InvalidInput, result);
}

test "bls12_g2_msm - invalid input length not multiple of 288" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([300]u8, @splat(0));
    const result = execute(allocator, &input, 1000000);

    try testing.expectError(error.InvalidInput, result);
}

test "bls12_g2_msm - single pair gas cost with discount" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([288]u8, @splat(0));
    const k = 1;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - two pairs discount tier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([(288 * 2)]u8, @splat(0));
    const k = 2;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 1000), discount);

    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - four pairs discount tier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([(288 * 4)]u8, @splat(0));
    const k = 4;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 884), discount);

    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - eight pairs discount tier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([(288 * 8)]u8, @splat(0));
    const k = 8;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 796), discount);

    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - sixteen pairs discount tier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([(288 * 16)]u8, @splat(0));
    const k = 16;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 717), discount);

    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - thirty-two pairs discount tier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([(288 * 32)]u8, @splat(0));
    const k = 32;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 646), discount);

    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - sixty-four pairs discount tier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([(288 * 64)]u8, @splat(0));
    const k = 64;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 582), discount);

    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - one hundred twenty-eight pairs discount tier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([(288 * 128)]u8, @splat(0));
    const k = 128;
    const discount = utils.msmDiscountG2(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 524), discount);
    // 128 * 22500 * 524 / 1000 = 1_509_120
    try testing.expectEqual(@as(u64, 1_509_120), expected_gas);
    try testing.expectError(error.OutOfGas, execute(allocator, &input, expected_gas - 1));

    const result = execute(allocator, &input, expected_gas);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(expected_gas, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_msm - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([288]u8, @splat(0));
    const k = 1;
    const discount = utils.msmDiscountG2(k);
    const gas_cost = (BASE_GAS * k * discount) / 1000;

    const result = execute(allocator, &input, gas_cost - 1);

    try testing.expectError(error.OutOfGas, result);
}

test "bls12_g2_msm - output length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([288]u8, @splat(0));
    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(@as(usize, 256), res.output.len);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}
