const std = @import("std");
const crypto = @import("crypto");
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for BLS12-381 G2 addition
pub const GAS: u64 = 600;

/// 0x0D: BLS12_G2ADD - BLS12-381 G2 addition
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    if (input.len != 512) {
        return error.InvalidInput;
    }

    const output = try allocator.alloc(u8, 256);
    errdefer allocator.free(output);
    crypto.Crypto.bls12_381.g2Add(input, output) catch {
        return error.InvalidPoint;
    };

    return PrecompileResult{
        .output = output,
        .gas_used = GAS,
    };
}

test "bls12_g2_add - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([512]u8, @splat(0));
    const result = execute(allocator, &input, GAS - 1);

    try testing.expectError(error.OutOfGas, result);
}

test "bls12_g2_add - invalid input length too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([256]u8, @splat(0));
    const result = execute(allocator, &input, 1000000);

    try testing.expectError(error.InvalidInput, result);
}

test "bls12_g2_add - invalid input length too long" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([600]u8, @splat(0));
    const result = execute(allocator, &input, 1000000);

    try testing.expectError(error.InvalidInput, result);
}

test "bls12_g2_add - gas cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([512]u8, @splat(0));
    const result = execute(allocator, &input, 1000000);

    if (result) |res| {
        defer res.deinit(allocator);
        try testing.expectEqual(GAS, res.gas_used);
    } else |err| {
        if (err != error.InvalidPoint) {
            return err;
        }
    }
}

test "bls12_g2_add - output length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([512]u8, @splat(0));
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

test "EIP-2537 g2_add rejects padding and noncanonical field elements without leaking" {
    var input = @as([512]u8, @splat(0));
    const modulus: u512 = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;
    for (0..8) |slot| {
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
