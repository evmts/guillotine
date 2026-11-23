//! Base precompiles.
//!
//! Through Jovian, Base runs the OP Stack precompile set unchanged
//! (base/base crates/common/precompiles/src/provider.rs selects the same RIP-7212
//! P256VERIFY, Granite/Jovian BN254 limits, and Isthmus/Jovian BLS12-381 limits).
//! This module resolves the set from a Base chain and block timestamp.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;
const OpSpecId = @import("../optimism/spec.zig").OpSpecId;
const op_precompiles = @import("../optimism/precompiles.zig");
const config = @import("config.zig");

pub const P256_VERIFY_ADDRESS = op_precompiles.P256_VERIFY_ADDRESS;
pub const P256_VERIFY_GAS = op_precompiles.P256_VERIFY_GAS;
pub const Entry = op_precompiles.Entry;
pub const entries = op_precompiles.entries;
pub const overrides = op_precompiles.overrides;
pub const p256Verify = op_precompiles.p256Verify;

/// True if P256VERIFY (0x100) is callable on `chain` at `timestamp`.
pub fn hasP256Verify(chain: config.BaseChain, timestamp: u64) config.ScheduleError!bool {
    const spec = try chain.schedule().specAt(timestamp);
    return op_precompiles.isOpPrecompile(P256_VERIFY_ADDRESS, spec);
}

/// BN254 pairing input limit on `chain` at `timestamp`; null when unlimited.
pub fn bn254PairingMaxInput(chain: config.BaseChain, timestamp: u64) config.ScheduleError!?usize {
    const spec = try chain.schedule().specAt(timestamp);
    if (spec.isAtLeast(.JOVIAN)) return op_precompiles.BN254_PAIRING_MAX_INPUT_JOVIAN;
    if (spec.isAtLeast(.GRANITE)) return op_precompiles.BN254_PAIRING_MAX_INPUT_GRANITE;
    return null;
}

const testing = std.testing;
const hardforks = @import("hardforks.zig");

test "P256VERIFY activates at Base Fjord on mainnet and Sepolia" {
    try testing.expect(!try hasP256Verify(.mainnet, hardforks.MAINNET.fjord - 1));
    try testing.expect(try hasP256Verify(.mainnet, hardforks.MAINNET.fjord));
    try testing.expect(try hasP256Verify(.mainnet, hardforks.MAINNET.jovian));
    try testing.expect(!try hasP256Verify(.sepolia, hardforks.SEPOLIA.fjord - 1));
    try testing.expect(try hasP256Verify(.sepolia, hardforks.SEPOLIA.fjord));
}

test "BN254 pairing limit follows Base Granite and Jovian" {
    try testing.expectEqual(@as(?usize, null), try bn254PairingMaxInput(.mainnet, hardforks.MAINNET.fjord));
    try testing.expectEqual(@as(?usize, 112_687), try bn254PairingMaxInput(.mainnet, hardforks.MAINNET.granite));
    try testing.expectEqual(@as(?usize, 112_687), try bn254PairingMaxInput(.mainnet, hardforks.MAINNET.jovian - 1));
    try testing.expectEqual(@as(?usize, 81_984), try bn254PairingMaxInput(.mainnet, hardforks.MAINNET.jovian));
    try testing.expectEqual(@as(?usize, 112_687), try bn254PairingMaxInput(.sepolia, hardforks.SEPOLIA.granite));
}

test "unmodeled Base upgrades surface as errors" {
    try testing.expectError(error.UnmodeledBaseUpgrade, hasP256Verify(.mainnet, hardforks.MAINNET.azul.?));
    try testing.expectError(error.BeforeGenesis, hasP256Verify(.sepolia, 0));
}

test "Base P256VERIFY verifies a real signature at 3450 gas" {
    // RIP-7212 reference vector (go-ethereum p256Verify.json "CallP256Verify").
    var input: [160]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
        "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
        "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
        "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
        "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e");
    const result = try p256Verify(testing.allocator, &input, 3450);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 3450), result.gas_used);
    try testing.expectEqual(@as(u8, 1), result.output[31]);
}
