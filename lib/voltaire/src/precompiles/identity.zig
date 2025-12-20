const std = @import("std");
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for IDENTITY precompile
pub const BASE_GAS: u64 = 15;
pub const PER_WORD_GAS: u64 = 3;

/// 0x04: IDENTITY - Identity function (returns input)
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

    const output = try allocator.dupe(u8, input);

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

test "identity - returns input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{ 1, 2, 3, 4, 5 };
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqualSlices(u8, &input, result.output);
}

test "identity - gas calculation two words" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 64; // 2 words
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = BASE_GAS + PER_WORD_GAS * 2;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "identity - empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqualSlices(u8, &input, result.output);
    const expected_gas = BASE_GAS + PER_WORD_GAS * 0;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "identity - one word" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 32;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = BASE_GAS + PER_WORD_GAS * 1;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "identity - partial word rounds up" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 33; // 2 words (rounds up)
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = BASE_GAS + PER_WORD_GAS * 2;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "identity - large input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 1000; // 32 words
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_words = (1000 + 31) / 32;
    const expected_gas = BASE_GAS + PER_WORD_GAS * expected_words;
    try testing.expectEqual(expected_gas, result.gas_used);
}

test "identity - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 64;
    const expected_gas = BASE_GAS + PER_WORD_GAS * 2;

    const result = execute(allocator, &input, expected_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "identity - exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 64;
    const expected_gas = BASE_GAS + PER_WORD_GAS * 2;

    const result = try execute(allocator, &input, expected_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
}

test "identity - gas constants" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 15), BASE_GAS);
    try testing.expectEqual(@as(u64, 3), PER_WORD_GAS);
}

test "identity - preserves data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqualSlices(u8, &input, result.output);
}
