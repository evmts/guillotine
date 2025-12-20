const std = @import("std");
const crypto = @import("crypto");
const Blake2 = crypto.Blake2;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost per round for Blake2f
pub const PER_ROUND_GAS: u64 = 1;

/// 0x09: BLAKE2F - Blake2b compression function
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (input.len != 213) {
        return error.InvalidInput;
    }

    const rounds = std.mem.readInt(u32, input[0..4], .big);
    const gas_cost = PER_ROUND_GAS * rounds;

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 64);

    Blake2.compress(input, output) catch {
        return error.InvalidInput;
    };

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

test "blake2f - invalid input length too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 100;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "blake2f - invalid input length too long" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 214;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "blake2f - invalid input length zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "blake2f - exact input length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 213;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "blake2f - gas cost calculation zero rounds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = 0;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = PER_ROUND_GAS * rounds;
    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(u64, 0), result.gas_used);
}

test "blake2f - gas cost calculation one round" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = 1;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = PER_ROUND_GAS * rounds;
    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(u64, 1), result.gas_used);
}

test "blake2f - gas cost calculation twelve rounds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = 12;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = PER_ROUND_GAS * rounds;
    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(u64, 12), result.gas_used);
}

test "blake2f - gas cost calculation large rounds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = 100000;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    const expected_gas = PER_ROUND_GAS * rounds;
    try testing.expectEqual(expected_gas, result.gas_used);
    try testing.expectEqual(@as(u64, 100000), result.gas_used);
}

test "blake2f - out of gas zero rounds allowed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = 1;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const result = execute(allocator, &input, 0);
    try testing.expectError(error.OutOfGas, result);
}

test "blake2f - out of gas insufficient" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = 100;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const required_gas = PER_ROUND_GAS * rounds;
    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "blake2f - exact gas limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = 50;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const required_gas = PER_ROUND_GAS * rounds;
    const result = try execute(allocator, &input, required_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(required_gas, result.gas_used);
}

test "blake2f - output length always 64 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "blake2f - maximum rounds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = [_]u8{0} ** 213;
    const rounds: u32 = std.math.maxInt(u32);
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const required_gas = PER_ROUND_GAS * rounds;
    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}
