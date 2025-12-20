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
pub const bn254_add = @import("bn254_add.zig");
pub const bn254_mul = @import("bn254_mul.zig");
pub const bn254_pairing = @import("bn254_pairing.zig");
pub const blake2f = @import("blake2f.zig");
pub const point_evaluation = @import("point_evaluation.zig");
pub const bls12_g1_add = @import("bls12_g1_add.zig");
pub const bls12_g1_mul = @import("bls12_g1_mul.zig");
pub const bls12_g1_msm = @import("bls12_g1_msm.zig");
pub const bls12_g2_add = @import("bls12_g2_add.zig");
pub const bls12_g2_mul = @import("bls12_g2_mul.zig");
pub const bls12_g2_msm = @import("bls12_g2_msm.zig");
pub const bls12_pairing = @import("bls12_pairing.zig");
pub const bls12_map_fp_to_g1 = @import("bls12_map_fp_to_g1.zig");
pub const bls12_map_fp2_to_g2 = @import("bls12_map_fp2_to_g2.zig");

// Utilities
pub const utils = @import("utils.zig");

/// Precompile contract addresses (0x01 through 0x13)
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
pub const BLS12_G1MUL_ADDRESS: Address = Address.fromU256(0x0C);
pub const BLS12_G1MSM_ADDRESS: Address = Address.fromU256(0x0D);
pub const BLS12_G2ADD_ADDRESS: Address = Address.fromU256(0x0E);
pub const BLS12_G2MUL_ADDRESS: Address = Address.fromU256(0x0F);
pub const BLS12_G2MSM_ADDRESS: Address = Address.fromU256(0x10);
pub const BLS12_PAIRING_ADDRESS: Address = Address.fromU256(0x11);
pub const BLS12_MAP_FP_TO_G1_ADDRESS: Address = Address.fromU256(0x12);
pub const BLS12_MAP_FP2_TO_G2_ADDRESS: Address = Address.fromU256(0x13);

/// Check if an address is a precompile
pub fn isPrecompile(address: Address, hardfork: Hardfork) bool {
    const addr_int = address.toU256();

    return switch (hardfork) {
        .FRONTIER, .HOMESTEAD => addr_int >= 0x01 and addr_int <= 0x04,
        .BYZANTIUM => addr_int >= 0x01 and addr_int <= 0x08,
        .ISTANBUL => addr_int >= 0x01 and addr_int <= 0x09,
        .CANCUN => addr_int >= 0x01 and addr_int <= 0x0A,
        .PRAGUE => addr_int >= 0x01 and addr_int <= 0x13,
        else => false,
    };
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
        0x06 => bn254_add.execute(allocator, input, gas_limit),
        0x07 => bn254_mul.execute(allocator, input, gas_limit),
        0x08 => bn254_pairing.execute(allocator, input, gas_limit),
        0x09 => blake2f.execute(allocator, input, gas_limit),
        0x0A => point_evaluation.execute(allocator, input, gas_limit),
        0x0B => bls12_g1_add.execute(allocator, input, gas_limit),
        0x0C => bls12_g1_mul.execute(allocator, input, gas_limit),
        0x0D => bls12_g1_msm.execute(allocator, input, gas_limit),
        0x0E => bls12_g2_add.execute(allocator, input, gas_limit),
        0x0F => bls12_g2_mul.execute(allocator, input, gas_limit),
        0x10 => bls12_g2_msm.execute(allocator, input, gas_limit),
        0x11 => bls12_pairing.execute(allocator, input, gas_limit),
        0x12 => bls12_map_fp_to_g1.execute(allocator, input, gas_limit),
        0x13 => bls12_map_fp2_to_g2.execute(allocator, input, gas_limit),
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
    try testing.expect(isPrecompile(Address.fromU256(0x13), .PRAGUE));
    try testing.expect(!isPrecompile(Address.fromU256(0x14), .PRAGUE));
}

test "precompile - out of gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = [_]u8{0} ** 32;
    const result = sha256.execute(allocator, &input, 10);
    try testing.expectError(error.OutOfGas, result);
}
