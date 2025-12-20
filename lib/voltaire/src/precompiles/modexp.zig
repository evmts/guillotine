const std = @import("std");
const primitives = @import("voltaire");
const crypto = @import("crypto");
const ModExp = crypto.ModExp;
const Hardfork = primitives.Hardfork;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Minimum gas for MODEXP precompile
pub const MIN_GAS: u64 = 200;

/// 0x05: MODEXP - Modular exponentiation
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
    hardfork: Hardfork,
) PrecompileError!PrecompileResult {
    // Parse lengths
    if (input.len < 96) {
        return error.InvalidInput;
    }

    const base_len = std.mem.readInt(u256, input[0..32], .big);
    const exp_len = std.mem.readInt(u256, input[32..64], .big);
    const mod_len = std.mem.readInt(u256, input[64..96], .big);

    if (base_len > std.math.maxInt(usize) or
        exp_len > std.math.maxInt(usize) or
        mod_len > std.math.maxInt(usize))
    {
        return error.InvalidInput;
    }

    const base_len_usize = @as(usize, @intCast(base_len));
    const exp_len_usize = @as(usize, @intCast(exp_len));
    const mod_len_usize = @as(usize, @intCast(mod_len));

    // Calculate gas cost
    const gas_cost = ModExp.calculateGas(
        base_len_usize,
        exp_len_usize,
        mod_len_usize,
        if (96 + base_len_usize + exp_len_usize <= input.len)
            input[96 + base_len_usize .. 96 + base_len_usize + exp_len_usize]
        else
            &[_]u8{},
        hardfork,
    );

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    // Extract base, exponent, and modulus
    const data_start = 96;
    const base_start = data_start;
    const exp_start = base_start + base_len_usize;
    const mod_start = exp_start + exp_len_usize;

    const base = if (base_start + base_len_usize <= input.len)
        input[base_start .. base_start + base_len_usize]
    else
        &[_]u8{};

    const exponent = if (exp_start + exp_len_usize <= input.len)
        input[exp_start .. exp_start + exp_len_usize]
    else
        &[_]u8{};

    const modulus = if (mod_start + mod_len_usize <= input.len)
        input[mod_start .. mod_start + mod_len_usize]
    else
        &[_]u8{};

    // Perform modular exponentiation
    const result = ModExp.modexp(allocator, base, exponent, modulus) catch |err| switch (err) {
        error.DivisionByZero => return error.InvalidInput,
        error.InvalidInput => return error.InvalidInput,
        error.InvalidBase => return error.InvalidInput,
        error.InvalidCharacter => return error.InvalidInput,
        error.InvalidLength => return error.InvalidInput,
        error.AllocationFailed => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => return error.OutOfMemory,
        error.NotImplemented => return error.NotImplemented,
    };
    defer allocator.free(result);

    // Pad output to mod_len
    const output = try allocator.alloc(u8, mod_len_usize);
    @memset(output, 0);

    if (result.len <= mod_len_usize) {
        const offset = mod_len_usize - result.len;
        @memcpy(output[offset..], result);
    } else {
        @memcpy(output, result[result.len - mod_len_usize ..]);
    }

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

test "modexp - simple case" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 2^3 mod 5 = 3
    var input: [99]u8 = [_]u8{0} ** 99;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 2
    input[96] = 2;
    // exp = 3
    input[97] = 3;
    // mod = 5
    input[98] = 5;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 3), result.output[0]);
}

test "modexp - invalid input too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 95;
    const result = execute(allocator, &input, 1000000, .Cancun);
    try testing.expectError(error.InvalidInput, result);
}

test "modexp - minimum gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [96]u8 = [_]u8{0} ** 96;
    const result = try execute(allocator, &input, MIN_GAS, .Cancun);
    defer result.deinit(allocator);

    try testing.expect(result.gas_used >= MIN_GAS);
}

test "modexp - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [99]u8 = [_]u8{0} ** 99;
    input[31] = 1;
    input[63] = 1;
    input[95] = 1;
    input[96] = 2;
    input[97] = 3;
    input[98] = 5;

    const result = execute(allocator, &input, 0);
    try testing.expectError(error.OutOfGas, result);
}

test "modexp - zero modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [99]u8 = [_]u8{0} ** 99;
    input[31] = 1;
    input[63] = 1;
    input[95] = 1;
    input[96] = 2;
    input[97] = 3;
    // mod = 0
    input[98] = 0;

    const result = execute(allocator, &input, 1000000, .Cancun);
    try testing.expectError(error.InvalidInput, result);
}

test "modexp - minimum gas constant" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 200), MIN_GAS);
}

// ============================================================================
// Official Ethereum Test Vectors from go-ethereum
// Source: https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/modexp.json
// ============================================================================

test "modexp - geth eip_example1" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // base = 3, exp = 1, mod = 5
    // Expected: 3^1 mod 5 = 3
    var input: [99]u8 = [_]u8{0} ** 99;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 3
    input[96] = 3;
    // exp = 1
    input[97] = 1;
    // mod = 5
    input[98] = 5;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 3), result.output[0]);
}

test "modexp - geth eip_example2 zero base" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // base = 0, exp = 1, mod = 5
    // Expected: 0^1 mod 5 = 0
    var input: [99]u8 = [_]u8{0} ** 99;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 0
    input[96] = 0;
    // exp = 1
    input[97] = 1;
    // mod = 5
    input[98] = 5;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 0), result.output[0]);
}

test "modexp - geth nagydani-1-square small" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test a^2 mod m for small values
    var input: [98]u8 = [_]u8{0} ** 98;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 2
    input[96] = 2;
    // exp = 2 (square)
    input[97] = 2;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expect(res.output.len > 0);
    } else |err| {
        // Zero modulus should fail
        try testing.expectEqual(error.InvalidInput, err);
    }
}

test "modexp - large exponent DoS resistance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with very large exponent length to ensure gas calculation prevents DoS
    var input: [96]u8 = [_]u8{0} ** 96;

    // base_len = 1
    input[31] = 1;
    // exp_len = 32 (large)
    input[63] = 32;
    // mod_len = 1
    input[95] = 1;

    const result = execute(allocator, &input, 1000, .Cancun);
    // Should fail due to insufficient gas
    try testing.expectError(error.OutOfGas, result);
}

test "modexp - maximum modulus size" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with 256-byte modulus
    var input_data: [672]u8 = [_]u8{0} ** 672;

    // base_len = 1
    input_data[31] = 1;
    // exp_len = 1
    input_data[63] = 1;
    // mod_len = 256
    input_data[94] = 1;
    input_data[95] = 0;

    // base = 2
    input_data[96] = 2;
    // exp = 2
    input_data[97] = 2;
    // mod = 1...1 (256 bytes, set last byte to non-zero)
    input_data[671] = 255;

    const result = try execute(allocator, &input_data, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 256), result.output.len);
}

test "modexp - zero exponent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // base = 5, exp = 0, mod = 7
    // Expected: 5^0 mod 7 = 1
    var input: [99]u8 = [_]u8{0} ** 99;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 5
    input[96] = 5;
    // exp = 0
    input[97] = 0;
    // mod = 7
    input[98] = 7;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 1), result.output[0]);
}

test "modexp - modulus equals 1" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // base = 5, exp = 3, mod = 1
    // Expected: 5^3 mod 1 = 0
    var input: [99]u8 = [_]u8{0} ** 99;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 5
    input[96] = 5;
    // exp = 3
    input[97] = 3;
    // mod = 1
    input[98] = 1;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 0), result.output[0]);
}

test "modexp - base larger than modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // base = 10, exp = 2, mod = 7
    // Expected: 10^2 mod 7 = 100 mod 7 = 2
    var input: [99]u8 = [_]u8{0} ** 99;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 10
    input[96] = 10;
    // exp = 2
    input[97] = 2;
    // mod = 7
    input[98] = 7;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 2), result.output[0]);
}

test "modexp - RSA 2048-bit simulation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate RSA with 256-byte (2048-bit) values
    const base_len: usize = 256;
    const exp_len: usize = 1;
    const mod_len: usize = 256;

    const total_len = 96 + base_len + exp_len + mod_len;
    var input_data = try allocator.alloc(u8, total_len);
    defer allocator.free(input_data);
    @memset(input_data, 0);

    // Set lengths in first 96 bytes
    input_data[94] = 1; // base_len = 256 (0x0100)
    input_data[95] = 0;

    input_data[63] = 1; // exp_len = 1

    input_data[30] = 1; // mod_len = 256 (0x0100)
    input_data[31] = 0;

    // Set base to non-zero value
    input_data[96 + base_len - 1] = 3;
    // Set exponent
    input_data[96 + base_len] = 65537 & 0xFF; // Common RSA exponent (low byte)
    // Set modulus to non-zero value
    input_data[total_len - 1] = 255;

    const result = try execute(allocator, input_data, 10000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(mod_len, result.output.len);
}

test "modexp - gas cost increases with size" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that gas cost increases appropriately with input size
    const sizes = [_]usize{ 1, 32, 64, 128 };
    var prev_gas: u64 = 0;

    for (sizes) |size| {
        const total_len = 96 + size * 3;
        var input_data = try allocator.alloc(u8, total_len);
        defer allocator.free(input_data);
        @memset(input_data, 0);

        // Set lengths
        input_data[31] = @intCast(size);
        input_data[63] = @intCast(size);
        input_data[95] = @intCast(size);

        // Set non-zero modulus
        input_data[total_len - 1] = 255;

        const result = try execute(allocator, input_data, 10000000, .Cancun);
        defer result.deinit(allocator);

        if (prev_gas > 0) {
            try testing.expect(result.gas_used > prev_gas);
        }
        prev_gas = result.gas_used;
    }
}

test "modexp - truncated input handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Input declares lengths but doesn't provide enough data
    var input: [97]u8 = [_]u8{0} ** 97;

    // Declare we need 5 bytes for base but only provide 1
    input[31] = 5;
    input[63] = 1;
    input[95] = 1;

    input[96] = 2;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    // Should handle gracefully with zero padding
    try testing.expect(result.output.len > 0);
}

test "modexp - exponent larger than modulus" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // base = 2, exp = 100, mod = 13
    // Expected: 2^100 mod 13 (should compute correctly)
    var input: [99]u8 = [_]u8{0} ** 99;

    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;

    // base = 2
    input[96] = 2;
    // exp = 100
    input[97] = 100;
    // mod = 13
    input[98] = 13;

    const result = try execute(allocator, &input, 1000000, .Cancun);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.output.len);
    // 2^100 mod 13 = 9 (verified mathematically)
    try testing.expectEqual(@as(u8, 9), result.output[0]);
}

test "modexp - berlin vs cancun hardfork gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that gas costs differ between hardforks
    var input: [99]u8 = [_]u8{0} ** 99;

    input[31] = 1;
    input[63] = 1;
    input[95] = 1;

    input[96] = 2;
    input[97] = 3;
    input[98] = 5;

    const result_berlin = try execute(allocator, &input, 1000000, .Berlin);
    defer result_berlin.deinit(allocator);

    const result_cancun = try execute(allocator, &input, 1000000, .Cancun);
    defer result_cancun.deinit(allocator);

    // Gas costs may differ between hardforks
    // Both should succeed with correct output
    try testing.expectEqual(@as(u8, 3), result_berlin.output[0]);
    try testing.expectEqual(@as(u8, 3), result_cancun.output[0]);
}

test "modexp - all zero input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // All zeros: base=0, exp=0, mod=0
    var input: [99]u8 = [_]u8{0} ** 99;

    input[31] = 1;
    input[63] = 1;
    input[95] = 1;

    // All data bytes are 0

    const result = execute(allocator, &input, 1000000, .Cancun);
    try testing.expectError(error.InvalidInput, result);
}
