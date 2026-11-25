const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;
const Hardfork = primitives.Hardfork;

// Common types
pub const common = @import("common.zig");
pub const PrecompileResult = common.PrecompileResult;
pub const PrecompileError = common.PrecompileError;

// Individual precompiles
pub const ecrecover = @import("ecrecover.zig");
pub const sha256 = @import("sha256.zig");
pub const ripemd160 = @import("ripemd160.zig");
pub const identity = @import("identity.zig");
pub const modexp = @import("modexp.zig");

test {
    _ = modexp;
}
pub const bn254_add = @import("bn254_add.zig");
pub const bn254_mul = @import("bn254_mul.zig");
pub const bn254_pairing = @import("bn254_pairing.zig");
pub const blake2f = @import("blake2f.zig");
pub const point_evaluation = @import("point_evaluation.zig");
pub const bls12_g1_add = @import("bls12_g1_add.zig");
pub const bls12_g1_msm = @import("bls12_g1_msm.zig");
pub const bls12_g2_add = @import("bls12_g2_add.zig");
pub const bls12_g2_msm = @import("bls12_g2_msm.zig");
pub const bls12_pairing = @import("bls12_pairing.zig");
pub const bls12_map_fp_to_g1 = @import("bls12_map_fp_to_g1.zig");
pub const bls12_map_fp2_to_g2 = @import("bls12_map_fp2_to_g2.zig");
pub const p256verify = @import("p256verify.zig");

// Utilities
pub const utils = @import("utils.zig");

/// Precompile contract addresses. Final EIP-2537 (Prague) has no G1MUL/G2MUL: MSM with
/// one pair covers multiplication, and the BLS12-381 set occupies 0x0B through 0x11.
pub const ECRECOVER_ADDRESS: Address = Address.fromU256(0x01);
pub const SHA256_ADDRESS: Address = Address.fromU256(0x02);
pub const RIPEMD160_ADDRESS: Address = Address.fromU256(0x03);
pub const IDENTITY_ADDRESS: Address = Address.fromU256(0x04);
pub const MODEXP_ADDRESS: Address = Address.fromU256(0x05);
pub const ECADD_ADDRESS: Address = Address.fromU256(0x06);
pub const ECMUL_ADDRESS: Address = Address.fromU256(0x07);
pub const ECPAIRING_ADDRESS: Address = Address.fromU256(0x08);
pub const BLAKE2F_ADDRESS: Address = Address.fromU256(0x09);
pub const POINT_EVALUATION_ADDRESS: Address = Address.fromU256(0x0A);
pub const BLS12_G1ADD_ADDRESS: Address = Address.fromU256(0x0B);
pub const BLS12_G1MSM_ADDRESS: Address = Address.fromU256(0x0C);
pub const BLS12_G2ADD_ADDRESS: Address = Address.fromU256(0x0D);
pub const BLS12_G2MSM_ADDRESS: Address = Address.fromU256(0x0E);
pub const BLS12_PAIRING_CHECK_ADDRESS: Address = Address.fromU256(0x0F);
pub const BLS12_MAP_FP_TO_G1_ADDRESS: Address = Address.fromU256(0x10);
pub const BLS12_MAP_FP2_TO_G2_ADDRESS: Address = Address.fromU256(0x11);
/// EIP-7951 P256VERIFY (Osaka, 0x100).
pub const P256VERIFY_ADDRESS: Address = Address.fromU256(0x100);

/// Highest contiguous precompile address (starting at 0x01) active in `hardfork`.
pub fn lastContiguousPrecompile(hardfork: Hardfork) u8 {
    // Precompiles remain available in successor forks.
    if (hardfork.isAtLeast(.PRAGUE)) return 0x11;
    if (hardfork.isAtLeast(.CANCUN)) return 0x0A;
    if (hardfork.isAtLeast(.ISTANBUL)) return 0x09;
    if (hardfork.isAtLeast(.BYZANTIUM)) return 0x08;
    return 0x04;
}

/// Check if an address is a precompile
pub fn isPrecompile(address: Address, hardfork: Hardfork) bool {
    const addr_int = address.toU256();
    if (addr_int >= 0x01 and addr_int <= lastContiguousPrecompile(hardfork)) return true;
    return hardfork.isAtLeast(.OSAKA) and addr_int == 0x100;
}

/// Execute a precompile contract
pub fn execute(
    allocator: std.mem.Allocator,
    address: Address,
    input: []const u8,
    gas_limit: u64,
    hardfork: Hardfork,
) PrecompileError!PrecompileResult {
    if (!isPrecompile(address, hardfork)) {
        return error.NotImplemented;
    }

    const addr_int = address.toU256();
    return switch (addr_int) {
        0x01 => ecrecover.execute(allocator, input, gas_limit),
        0x02 => sha256.execute(allocator, input, gas_limit),
        0x03 => ripemd160.execute(allocator, input, gas_limit),
        0x04 => identity.execute(allocator, input, gas_limit),
        0x05 => modexp.execute(allocator, input, gas_limit, hardfork),
        0x06 => bn254_add.executeAtFork(allocator, input, gas_limit, hardfork),
        0x07 => bn254_mul.executeAtFork(allocator, input, gas_limit, hardfork),
        0x08 => bn254_pairing.executeAtFork(allocator, input, gas_limit, hardfork),
        0x09 => blake2f.execute(allocator, input, gas_limit),
        0x0A => point_evaluation.execute(allocator, input, gas_limit),
        0x0B => bls12_g1_add.execute(allocator, input, gas_limit),
        0x0C => bls12_g1_msm.execute(allocator, input, gas_limit),
        0x0D => bls12_g2_add.execute(allocator, input, gas_limit),
        0x0E => bls12_g2_msm.execute(allocator, input, gas_limit),
        0x0F => bls12_pairing.execute(allocator, input, gas_limit),
        0x10 => bls12_map_fp_to_g1.execute(allocator, input, gas_limit),
        0x11 => bls12_map_fp2_to_g2.execute(allocator, input, gas_limit),
        0x100 => p256verify.execute(allocator, input, gas_limit, p256verify.GAS_COST_EIP7951),
        else => error.NotImplemented,
    };
}

test "isPrecompile - Frontier" {
    const testing = std.testing;

    try testing.expect(isPrecompile(Address.fromU256(0x01), .FRONTIER));
    try testing.expect(isPrecompile(Address.fromU256(0x04), .FRONTIER));
    try testing.expect(!isPrecompile(Address.fromU256(0x05), .FRONTIER));
}

test "isPrecompile - Byzantium" {
    const testing = std.testing;

    try testing.expect(isPrecompile(Address.fromU256(0x01), .BYZANTIUM));
    try testing.expect(isPrecompile(Address.fromU256(0x08), .BYZANTIUM));
    try testing.expect(!isPrecompile(Address.fromU256(0x09), .BYZANTIUM));
}

test "isPrecompile - Istanbul" {
    const testing = std.testing;

    try testing.expect(isPrecompile(Address.fromU256(0x09), .ISTANBUL));
    try testing.expect(!isPrecompile(Address.fromU256(0x0A), .ISTANBUL));
}

test "isPrecompile - Cancun" {
    const testing = std.testing;

    try testing.expect(isPrecompile(Address.fromU256(0x0A), .CANCUN));
    try testing.expect(!isPrecompile(Address.fromU256(0x0B), .CANCUN));
}

test "isPrecompile - Prague" {
    const testing = std.testing;

    try testing.expect(isPrecompile(Address.fromU256(0x0B), .PRAGUE));
    try testing.expect(isPrecompile(Address.fromU256(0x11), .PRAGUE));
    // Final EIP-2537 ends at 0x11; 0x12 and 0x13 were draft-only addresses.
    try testing.expect(!isPrecompile(Address.fromU256(0x12), .PRAGUE));
    try testing.expect(!isPrecompile(Address.fromU256(0x13), .PRAGUE));
}

test "isPrecompile - Osaka dispatches P256VERIFY at 0x100" {
    const testing = std.testing;

    try testing.expect(isPrecompile(Address.fromU256(0x11), .OSAKA));
    try testing.expect(!isPrecompile(Address.fromU256(0x12), .OSAKA));
    try testing.expect(!isPrecompile(P256VERIFY_ADDRESS, .PRAGUE));
    try testing.expect(isPrecompile(P256VERIFY_ADDRESS, .OSAKA));
}

test "execute - final EIP-2537 address layout routes to the right precompile" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Each address gets an input of the length only its own precompile accepts, and
    // exactly its final EIP-2537 cost: one unit less is OutOfGas, the cost itself gets
    // past the gas check. Length + exact cost identify the precompile without depending
    // on the curve arithmetic.
    const Case = struct { address: Address, input_len: usize, cost: u64 };
    const cases = [_]Case{
        .{ .address = BLS12_G1ADD_ADDRESS, .input_len = 256, .cost = 375 },
        .{ .address = BLS12_G1MSM_ADDRESS, .input_len = 160, .cost = 12000 },
        .{ .address = BLS12_G2ADD_ADDRESS, .input_len = 512, .cost = 600 },
        .{ .address = BLS12_G2MSM_ADDRESS, .input_len = 288, .cost = 22500 },
        .{ .address = BLS12_PAIRING_CHECK_ADDRESS, .input_len = 384, .cost = 70300 },
        .{ .address = BLS12_MAP_FP_TO_G1_ADDRESS, .input_len = 64, .cost = 5500 },
        .{ .address = BLS12_MAP_FP2_TO_G2_ADDRESS, .input_len = 128, .cost = 23800 },
    };
    try testing.expectEqual(@as(u256, 0x0B), cases[0].address.toU256());
    try testing.expectEqual(@as(u256, 0x11), cases[6].address.toU256());
    var input: [512]u8 = @as([512]u8, @splat(0));
    for (cases) |case| {
        const data = input[0..case.input_len];
        try testing.expectError(error.OutOfGas, execute(allocator, case.address, data, case.cost - 1, .PRAGUE));
        if (execute(allocator, case.address, data, case.cost, .PRAGUE)) |res| {
            defer res.deinit(allocator);
            try testing.expectEqual(case.cost, res.gas_used);
        } else |err| {
            try testing.expect(err != error.OutOfGas);
            try testing.expect(err != error.NotImplemented);
        }
    }

    try testing.expectError(error.NotImplemented, execute(allocator, Address.fromU256(0x12), &[_]u8{}, 100000, .PRAGUE));
    try testing.expectError(error.NotImplemented, execute(allocator, Address.fromU256(0x13), &[_]u8{}, 100000, .PRAGUE));
    try testing.expectError(error.NotImplemented, execute(allocator, BLS12_G1ADD_ADDRESS, input[0..256], 100000, .CANCUN));
}

test "precompile - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = @as([32]u8, @splat(0));
    const result = sha256.execute(allocator, &input, 10);
    try testing.expectError(error.OutOfGas, result);
}

test {
    _ = bn254_add;
    _ = bn254_mul;
    _ = bn254_pairing;
    _ = bls12_g1_add;
    _ = bls12_g1_msm;
    _ = bls12_g2_add;
    _ = bls12_g2_msm;
    _ = bls12_pairing;
    _ = bls12_map_fp_to_g1;
    _ = bls12_map_fp2_to_g2;
    _ = p256verify;
    _ = point_evaluation;
    _ = blake2f;
    _ = modexp;
    _ = ecrecover;
    _ = sha256;
    _ = ripemd160;
    _ = identity;
}

