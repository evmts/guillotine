/// BN254 Rust Integration Tests
///
/// Tests for the BN254 Rust wrapper library integration with Zig.
/// These tests verify that ECMUL and ECPAIRING precompiles work correctly
/// with the arkworks-based implementation.
const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Import the precompile modules
const ecmul = evm.precompiles.ecmul;
const ecpairing = evm.precompiles.ecpairing;
const precompiles = evm.precompiles.precompiles;
const ChainRules = evm.chain_rules;
const Frame = evm.Frame;

test "BN254 ECMUL basic functionality" {
    const chain_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);

    // Test multiplying point at infinity by any scalar
    var input = [_]u8{0} ** 96; // All zeros = point at infinity, scalar = 0
    var output = [_]u8{0} ** 64;

    const result = ecmul.execute(&input, &output, 10000, chain_rules);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());
    try testing.expectEqual(@as(usize, 64), result.get_output_size());

    // Result should be point at infinity (0, 0)
    for (output) |_| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "BN254 ECMUL generator point by one" {
    const chain_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);

    // Test multiplying generator point (1, 2) by scalar 1
    var input = [_]u8{0} ** 96;

    // Set point to (1, 2)
    input[31] = 1; // x = 1
    input[63] = 2; // y = 2
    // Set scalar to 1
    input[95] = 1; // scalar = 1

    var output = [_]u8{0} ** 64;
    const result = ecmul.execute(&input, &output, 10000, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());

    // Result should be (1, 2) since generator * 1 = generator
    try testing.expectEqual(@as(u8, 1), output[31]); // x coordinate
    try testing.expectEqual(@as(u8, 2), output[63]); // y coordinate
}

test "BN254 ECPAIRING empty input" {
    const chain_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);

    // Test empty input (k=0) - should return true
    const input: []const u8 = &[_]u8{};
    var output = [_]u8{0} ** 32;

    const result = ecpairing.execute(input, &output, 50000, chain_rules);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 45000), result.get_gas_used()); // Base cost only
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Result should be true (0x0000...0001)
    for (output[0..31]) |_| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    try testing.expectEqual(@as(u8, 1), output[31]);
}

test "BN254 ECPAIRING single pair - identity pairing" {
    const chain_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);

    // Test single pair with point at infinity (should result in identity pairing)
    var input = [_]u8{0} ** 192; // G1 = O, G2 = O
    var output = [_]u8{0} ** 32;

    const gas_needed = 45000 + 34000; // Base + 1 pair
    const result = ecpairing.execute(&input, &output, gas_needed, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, gas_needed), result.get_gas_used());

    // e(O, O) = 1, so result should be true
    for (output[0..31]) |_| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    try testing.expectEqual(@as(u8, 1), output[31]);
}

test "BN254 precompile dispatcher integration" {
    const chain_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);

    // Test ECMUL through the dispatcher
    const ecmul_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x07 };
    var input = [_]u8{0} ** 96;
    var output = [_]u8{0} ** 64;

    const result = precompiles.execute_precompile(ecmul_address, &input, &output, 10000, chain_rules);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());

    // Test ECPAIRING through the dispatcher
    const ecpairing_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x08 };
    const pairing_input: []const u8 = &[_]u8{};
    var pairing_output = [_]u8{0} ** 32;

    const pairing_result = precompiles.execute_precompile(ecpairing_address, pairing_input, &pairing_output, 50000, chain_rules);
    try testing.expect(pairing_result.is_success());
    try testing.expectEqual(@as(u64, 45000), pairing_result.get_gas_used());
}

test "BN254 gas estimation" {
    const chain_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);

    // Test ECMUL gas estimation
    const ecmul_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x07 };
    const ecmul_gas = precompiles.estimate_gas(ecmul_address, 96, chain_rules) catch unreachable;
    try testing.expectEqual(@as(u64, 6000), ecmul_gas);

    // Test ECPAIRING gas estimation
    const ecpairing_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x08 };
    const ecpairing_gas = precompiles.estimate_gas(ecpairing_address, 0, chain_rules) catch unreachable;
    try testing.expectEqual(@as(u64, 45000), ecpairing_gas);

    // Test ECPAIRING with one pair
    const one_pair_gas = precompiles.estimate_gas(ecpairing_address, 192, chain_rules) catch unreachable;
    try testing.expectEqual(@as(u64, 79000), one_pair_gas);
}

test "BN254 output size validation" {
    const ecmul_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x07 };
    const ecpairing_address: Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x08 };
    const chain_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);

    // Test output sizes
    const ecmul_size = precompiles.get_output_size(ecmul_address, 96, chain_rules) catch unreachable;
    try testing.expectEqual(@as(usize, 64), ecmul_size);

    const ecpairing_size = precompiles.get_output_size(ecpairing_address, 192, chain_rules) catch unreachable;
    try testing.expectEqual(@as(usize, 32), ecpairing_size);
}

test "BN254 hardfork gas differences" {
    // Test that gas costs change between hardforks

    // Byzantium costs (higher)
    const byzantium_rules = @import("evm").hardforks.chain_rules.for_hardfork(.BYZANTIUM);
    const byzantium_ecmul_gas = ecmul.calculate_gas(byzantium_rules);
    try testing.expectEqual(@as(u64, 40000), byzantium_ecmul_gas);

    const byzantium_ecpairing_gas = ecpairing.calculate_gas(1, byzantium_rules);
    try testing.expectEqual(@as(u64, 180000), byzantium_ecpairing_gas); // 100000 + 80000 * 1

    // Istanbul costs (lower)
    const istanbul_rules = @import("evm").hardforks.chain_rules.for_hardfork(.ISTANBUL);
    const istanbul_ecmul_gas = ecmul.calculate_gas(istanbul_rules);
    try testing.expectEqual(@as(u64, 6000), istanbul_ecmul_gas);

    const istanbul_ecpairing_gas = ecpairing.calculate_gas(1, istanbul_rules);
    try testing.expectEqual(@as(u64, 79000), istanbul_ecpairing_gas); // 45000 + 34000 * 1
}
