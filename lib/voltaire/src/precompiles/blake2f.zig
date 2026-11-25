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
    errdefer allocator.free(output);

    Blake2.compress(input, output) catch |err| switch (err) {
        error.InvalidInput => return error.InvalidInput,
        error.InvalidOutput => return error.InvalidOutputSize,
    };

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

test "blake2f - invalid input length too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([100]u8, @splat(0));
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "blake2f - invalid input length too long" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([214]u8, @splat(0));
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

    const input = @as([213]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "blake2f - gas cost calculation zero rounds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = @as([213]u8, @splat(0));
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

    var input = @as([213]u8, @splat(0));
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

    var input = @as([213]u8, @splat(0));
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

    var input = @as([213]u8, @splat(0));
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

    var input = @as([213]u8, @splat(0));
    const rounds: u32 = 1;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const result = execute(allocator, &input, 0);
    try testing.expectError(error.OutOfGas, result);
}

test "blake2f - out of gas insufficient" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = @as([213]u8, @splat(0));
    const rounds: u32 = 100;
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const required_gas = PER_ROUND_GAS * rounds;
    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "blake2f - exact gas limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = @as([213]u8, @splat(0));
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

    var input = @as([213]u8, @splat(0));
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 64), result.output.len);
}

test "blake2f - maximum rounds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = @as([213]u8, @splat(0));
    const rounds: u32 = std.math.maxInt(u32);
    std.mem.writeInt(u32, input[0..4], rounds, .big);

    const required_gas = PER_ROUND_GAS * rounds;
    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "blake2f - final flag must be exactly 0 or 1 (EIP-152)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input = @as([213]u8, @splat(0));
    std.mem.writeInt(u32, input[0..4], 12, .big);
    for ([_]u8{ 0, 1 }) |flag| {
        input[212] = flag;
        const result = try execute(allocator, &input, 12);
        result.deinit(allocator);
    }
    for ([_]u8{ 2, 0x80, 0xff }) |flag| {
        input[212] = flag;
        try testing.expectError(error.InvalidInput, execute(allocator, &input, 12));
    }
}

test "blake2f - rounds beyond 12 use sigma[round mod 10]" {
    const testing = std.testing;
    const allocator = testing.allocator;
    // EIP-152 vector 5 state/message (BLAKE2b-512 of "abc"), varying only the round count.
    // 12 rounds is BLAKE2b("abc"). The 20 and 1024 round outputs come from an independent
    // RFC 7693 reference; the 1024-round prefix 0x689419d2...cdcf1 is also the value EEST
    // tests/istanbul/eip152_blake2 test_blake2b[valid-rounds-1024] expects in storage.
    const tail_hex = "48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5" ++
        "d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b" ++
        "6162630000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0300000000000000000000000000000001";
    const Case = struct { rounds: u32, output_hex: []const u8 };
    const cases = [_]Case{
        .{ .rounds = 12, .output_hex = "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923" },
        .{ .rounds = 20, .output_hex = "0c1b96fc9c06898bb49af24ef91a669143df8e847807765da43f8ad6c0ec5180e6ab033a21428e52c5d933345f81d8300a02158704935b7a020d990572ad9be0" },
        .{ .rounds = 1024, .output_hex = "689419d2bf32b5a9901a2c733b9946727026a60d8773117eabb35f04a52cdcf1b8fb4473454cf03d46c36a10b3f784aae4dc80a24424960e66a8ad5a8c2bfb30" },
    };
    for (cases) |case| {
        var input: [213]u8 = undefined;
        std.mem.writeInt(u32, input[0..4], case.rounds, .big);
        _ = try std.fmt.hexToBytes(input[4..], tail_hex);
        var expected: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case.output_hex);

        const result = try execute(allocator, &input, case.rounds);
        defer result.deinit(allocator);
        try testing.expectEqualSlices(u8, &expected, result.output);
        try testing.expectEqual(@as(u64, case.rounds), result.gas_used);
    }
}
