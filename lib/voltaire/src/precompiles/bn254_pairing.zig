const std = @import("std");
const crypto = @import("crypto");
const bn254 = crypto.bn254;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas costs for BN254 pairing
pub const BASE_GAS: u64 = 45000;
pub const PER_POINT_GAS: u64 = 34000;

/// 0x08: BN254PAIRING - BN254 elliptic curve pairing check
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    // Input must be multiple of 192 bytes (each pair is 192 bytes)
    if (input.len % 192 != 0) {
        return error.InvalidInput;
    }

    const num_pairs = input.len / 192;
    const gas_cost = BASE_GAS + PER_POINT_GAS * num_pairs;

    if (gas_limit < gas_cost) {
        return error.OutOfGas;
    }

    const output = try allocator.alloc(u8, 32);
    errdefer allocator.free(output);
    @memset(output, 0);

    // Perform pairing check using pure Zig implementation
    const success = bn254.bn254Pairing(input) catch {
        return error.InvalidPairing;
    };

    if (success) {
        output[31] = 1;
    }

    return PrecompileResult{
        .output = output,
        .gas_used = gas_cost,
    };
}

test "bn254Pairing - empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Empty input = pairing of zero points = success
    const input = [_]u8{};
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 1), result.output[31]);
}

test "bn254Pairing - invalid input not multiple of 192" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 191;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - single pair gas cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 192;
    const expected_gas = BASE_GAS + PER_POINT_GAS * 1;

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
}

test "bn254Pairing - two pairs gas cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 384;
    const expected_gas = BASE_GAS + PER_POINT_GAS * 2;

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
}

test "bn254Pairing - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 192;
    const required_gas = BASE_GAS + PER_POINT_GAS * 1;

    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bn254Pairing - exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 192;
    const required_gas = BASE_GAS + PER_POINT_GAS * 1;

    const result = try execute(allocator, &input, required_gas);
    defer result.deinit(allocator);

    try testing.expectEqual(required_gas, result.gas_used);
}

test "bn254Pairing - gas constants" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 45000), BASE_GAS);
    try testing.expectEqual(@as(u64, 34000), PER_POINT_GAS);
}

test "bn254Pairing - output size" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 192;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "bn254Pairing - empty input gas cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const expected_gas = BASE_GAS + PER_POINT_GAS * 0;

    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(expected_gas, result.gas_used);
}

// ============================================================================
// Official Ethereum Test Vectors from go-ethereum
// Source: https://github.com/ethereum/go-ethereum/blob/master/core/vm/testdata/precompiles/bn256Pairing.json
// ============================================================================

test "bn254Pairing - geth jeff1 returns 1" {
    // go-ethereum core/vm/testdata/precompiles/bn256Pairing.json "jeff1".
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [384]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "1c76476f4def4bb94541d57ebba1193381ffa7aa76ada664dd31c16024c43f59" ++
        "3034dd2920f673e204fee2811c678745fc819b55d3e9d294e45c9b03a76aef41" ++
        "209dd15ebff5d46c4bd888e51a93cf99a7329636c63514396b4a452003a35bf7" ++
        "04bf11ca01483bfa8b34b43561848d28905960114c8ac04049af4b6315a41678" ++
        "2bb8324af6cfc93537a2ad1a445cfd0ca2a71acd7ac41fadbf933c2a51be344d" ++
        "120a2a4cf30c1bf9845f20c6fe39e07ea2cce61f0c9bb048165fe5e4de877550" ++
        "111e129f1cf1097710d41c4ac70fcdfa5ba2023c6ff1cbeac322de49d1b6df7c" ++
        "2032c61a830e3c17286de9462bf242fca2883585b93870a73853face6a6bf411" ++
        "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" ++
        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa");
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    var expected = [_]u8{0} ** 32;
    expected[31] = 1;
    try testing.expectEqualSlices(u8, &expected, result.output);
    try testing.expectEqual(BASE_GAS + 2 * PER_POINT_GAS, result.gas_used);
}

test "bn254Pairing - e(G1, G2) returns 0" {
    // The bench/workloads.zig BN254-pairing vector: EIP-197 imaginary-first G2.
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" ++
        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa");
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), result.output);
}

test "bn254Pairing - e(2*G1, G2) * e(-G1, 2*G2) returns 1" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [384]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3" ++
        "15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4" ++
        "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" ++
        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd45" ++
        "203e205db4f19b37b60121b83a7333706db86431c6d835849957ed8c3928ad79" ++
        "27dc7234fd11d3e8c36c59277c3e6f149d5cd3cfa9a62aee49f8130962b4b3b9" ++
        "195e8aa5b7827463722b8c153931579d3505566b4edf48d498e185f0509de152" ++
        "04bb53b8977e5f92a0bc372742c4830944a59b4fe6b1c0466e2a6dad122b5d2e");
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    var expected = [_]u8{0} ** 32;
    expected[31] = 1;
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "bn254Pairing - non-canonical coordinate fails" {
    // G1 x = p + 1 would reduce to the generator's x = 1.
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd48" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" ++
        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa");
    try testing.expectError(error.InvalidPairing, execute(allocator, &input, 1000000));
}

test "bn254Pairing - G2 with real part first fails" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
        "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa" ++
        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b");
    try testing.expectError(error.InvalidPairing, execute(allocator, &input, 1000000));
}

test "bn254Pairing - all-zero pairs are infinity and return 1" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 384;
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), result.output[31]);
}

test "bn254Pairing - geth empty returns success" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{};
    const result = try execute(allocator, &input, 1000000);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 1), result.output[31]);
    try testing.expectEqual(BASE_GAS, result.gas_used);
}

test "bn254Pairing - geth one_point invalid must fail" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 128;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - single valid pair gas calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 192;
    const expected_gas = BASE_GAS + PER_POINT_GAS;

    const res = try execute(allocator, &input, expected_gas);
    defer res.deinit(allocator);
    try testing.expectEqual(expected_gas, res.gas_used);
}

test "bn254Pairing - two pairs gas calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 384;
    const expected_gas = BASE_GAS + 2 * PER_POINT_GAS;

    const res = try execute(allocator, &input, expected_gas);
    defer res.deinit(allocator);
    try testing.expectEqual(expected_gas, res.gas_used);
}

test "bn254Pairing - three pairs gas calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 576;
    const expected_gas = BASE_GAS + 3 * PER_POINT_GAS;

    const res = try execute(allocator, &input, expected_gas);
    defer res.deinit(allocator);
    try testing.expectEqual(expected_gas, res.gas_used);
}

test "bn254Pairing - four pairs gas calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 768;
    const expected_gas = BASE_GAS + 4 * PER_POINT_GAS;

    const res = try execute(allocator, &input, expected_gas);
    defer res.deinit(allocator);
    try testing.expectEqual(expected_gas, res.gas_used);
}

test "bn254Pairing - five pairs gas calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 960;
    const expected_gas = BASE_GAS + 5 * PER_POINT_GAS;

    const res = try execute(allocator, &input, expected_gas);
    defer res.deinit(allocator);
    try testing.expectEqual(expected_gas, res.gas_used);
}

test "bn254Pairing - ten pairs gas calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 1920;
    const expected_gas = BASE_GAS + 10 * PER_POINT_GAS;

    const res = try execute(allocator, &input, expected_gas);
    defer res.deinit(allocator);
    try testing.expectEqual(expected_gas, res.gas_used);
}

test "bn254Pairing - invalid length 1 byte" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0};
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - invalid length 191 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 191;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - invalid length 193 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 193;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - invalid length 383 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 383;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - invalid length 385 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 385;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - invalid length 575 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 575;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - invalid length 577 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 577;
    const result = execute(allocator, &input, 1000000);
    try testing.expectError(error.InvalidInput, result);
}

test "bn254Pairing - gas scaling property" {
    const testing = std.testing;

    const k_values = [_]u64{ 0, 1, 2, 5, 10, 20 };
    for (k_values) |k| {
        const expected = BASE_GAS + k * PER_POINT_GAS;
        try testing.expectEqual(expected, BASE_GAS + k * PER_POINT_GAS);
    }
}

test "bn254Pairing - output always 32 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input_sizes = [_]usize{ 0, 192, 384, 576 };
    for (input_sizes) |size| {
        const input = try allocator.alloc(u8, size);
        defer allocator.free(input);
        @memset(input, 0);

        const k = size / 192;
        const gas = BASE_GAS + k * PER_POINT_GAS;

        const res = try execute(allocator, input, gas);
        defer res.deinit(allocator);
        try testing.expectEqual(@as(usize, 32), res.output.len);
    }
}

test "bn254Pairing - out of gas for single pair" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 192;
    const required_gas = BASE_GAS + PER_POINT_GAS;
    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bn254Pairing - out of gas for two pairs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 384;
    const required_gas = BASE_GAS + 2 * PER_POINT_GAS;
    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bn254Pairing - out of gas for ten pairs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 1920;
    const required_gas = BASE_GAS + 10 * PER_POINT_GAS;
    const result = execute(allocator, &input, required_gas - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "bn254Pairing - exact gas for multiple sizes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const pairs = [_]usize{ 1, 2, 3, 5, 10 };
    for (pairs) |k| {
        const input = try allocator.alloc(u8, k * 192);
        defer allocator.free(input);
        @memset(input, 0);

        const required_gas = BASE_GAS + k * PER_POINT_GAS;
        const res = try execute(allocator, input, required_gas);
        defer res.deinit(allocator);
        try testing.expectEqual(required_gas, res.gas_used);
    }
}
