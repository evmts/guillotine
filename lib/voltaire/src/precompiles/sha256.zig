const std = @import("std");
const crypto = @import("crypto");
const SHA256 = crypto.SHA256_Accel.SHA256_Accel(1);
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for SHA256 precompile
pub const BASE_GAS: u64 = 60;
pub const PER_WORD_GAS: u64 = 12;

/// 0x02: SHA256 - SHA-256 hash function
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    const num_words = (input.len + 31) / 32;
    const gas_cost = BASE_GAS + PER_WORD_GAS * num_words;

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 32);
    var hash_output: [32]u8 = undefined;
    SHA256.hash(input, &hash_output);
    @memcpy(output, &hash_output);

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

test "sha256 - empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try execute(allocator, &[_]u8{}, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);

    // SHA256 of empty string
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "sha256 - gas calculation one word" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 32;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = BASE_GAS + PER_WORD_GAS * 1;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "sha256 - gas calculation two words" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 64;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = BASE_GAS + PER_WORD_GAS * 2;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "sha256 - partial word rounds up" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 33;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = BASE_GAS + PER_WORD_GAS * 2;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "sha256 - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 32;
    const required_gas = BASE_GAS + PER_WORD_GAS * 1;

    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "sha256 - exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 32;
    const required_gas = BASE_GAS + PER_WORD_GAS * 1;

    const result = try execute(allocator, &input, required_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(required_gas, result.gas_used);
}

test "sha256 - gas constants" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 60), BASE_GAS);
    try testing.expectEqual(@as(u64, 12), PER_WORD_GAS);
}

test "sha256 - output always 32 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 100;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "sha256 - large input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 1000;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_words = (1000 + 31) / 32;
    const expected_gas = BASE_GAS + PER_WORD_GAS * expected_words;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "sha256 - known test vector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "abc";
    const result = try execute(allocator, input, 1000000);
    defer result.deinit(allocator);

    // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try testing.expectEqualSlices(u8, &expected, result.output);
}
