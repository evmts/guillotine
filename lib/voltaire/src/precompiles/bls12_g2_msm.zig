const std = @import("std");
const crypto = @import("crypto");
const msmDiscount = @import("utils.zig").msmDiscount;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for BLS12-381 G2 MSM
pub const BASE_GAS: u64 = 45000;
pub const MULTIPLIER: u64 = 55;

/// 0x10: BLS12_G2MSM - BLS12-381 G2 multi-scalar multiplication
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (input.len % 288 != 0 or input.len == 0) {
        return error.InvalidInput;
    }

    const k = input.len / 288;
    const discount = msmDiscount(k);
    const gas_cost = (BASE_GAS * k * discount) / 1000;

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 256);
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

    const input = [_]u8{0} ** 300;
    const result = execute(allocator, &input, 1000000);

    try testing.expectError(error.InvalidInput, result);
}

test "bls12_g2_msm - single pair gas cost with discount" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 288;
    const k = 1;
    const discount = msmDiscount(k);
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

    const input = [_]u8{0} ** (288 * 2);
    const k = 2;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 820), discount);

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

    const input = [_]u8{0} ** (288 * 4);
    const k = 4;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 580), discount);

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

    const input = [_]u8{0} ** (288 * 8);
    const k = 8;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 430), discount);

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

    const input = [_]u8{0} ** (288 * 16);
    const k = 16;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 320), discount);

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

    const input = [_]u8{0} ** (288 * 32);
    const k = 32;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 250), discount);

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

    const input = [_]u8{0} ** (288 * 64);
    const k = 64;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 200), discount);

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

    const input = [_]u8{0} ** (288 * 128);
    const k = 128;
    const discount = msmDiscount(k);
    const expected_gas = (BASE_GAS * k * discount) / 1000;

    try testing.expectEqual(@as(u64, 174), discount);

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

test "bls12_g2_msm - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 288;
    const k = 1;
    const discount = msmDiscount(k);
    const gas_cost = (BASE_GAS * k * discount) / 1000;

    const result = execute(allocator, &input, gas_cost - 1);

    try testing.expectError(error.OutOfGas, result);
}

test "bls12_g2_msm - output length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 288;
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
